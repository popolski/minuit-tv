import Foundation

/// Index en mémoire du guide : programmes triés par chaîne, requêtes en O(log n).
///
/// Type valeur : une copie peut être lue sans verrou par l'interface pendant
/// qu'une nouvelle version est construite en arrière-plan.
public struct EPGIndex: Sendable, Codable, Equatable {
    public private(set) var programmesByChannel: [ChannelID: [Programme]]
    /// Dernière actualisation par chaîne (pour l'actualisation intelligente).
    public private(set) var updatedAt: [ChannelID: Date]

    public init() {
        programmesByChannel = [:]
        updatedAt = [:]
    }

    public var channelCount: Int { programmesByChannel.count }
    public var programmeCount: Int { programmesByChannel.values.reduce(0) { $0 + $1.count } }

    public func programmes(for channel: ChannelID) -> [Programme] {
        programmesByChannel[channel] ?? []
    }

    // MARK: Requêtes

    /// Programme en cours et suivant.
    public func nowNext(for channel: ChannelID, at date: Date) -> (now: Programme?, next: Programme?) {
        guard let list = programmesByChannel[channel], !list.isEmpty else { return (nil, nil) }
        let i = Self.lastIndex(in: list, startingAtOrBefore: date)
        if let i, list[i].isAiring(at: date) {
            return (list[i], i + 1 < list.count ? list[i + 1] : nil)
        }
        // Trou dans le guide : rien en cours, le suivant est le premier qui démarre après `date`.
        let nextIndex = (i ?? -1) + 1
        return (nil, nextIndex < list.count ? list[nextIndex] : nil)
    }

    /// Programmes qui intersectent l'intervalle.
    public func programmes(for channel: ChannelID, in interval: DateInterval) -> ArraySlice<Programme> {
        guard let list = programmesByChannel[channel], !list.isEmpty else { return [] }
        var lower = Self.lastIndex(in: list, startingAtOrBefore: interval.start) ?? 0
        if list[lower].end <= interval.start { lower += 1 }
        var upper = lower
        while upper < list.count, list[upper].start < interval.end { upper += 1 }
        return lower < upper ? list[lower..<upper] : []
    }

    /// Cases de la grille, programmes et trous compris, pour une mise en page sans calcul côté vue.
    public func slots(for channel: ChannelID, in interval: DateInterval, minimumGap: TimeInterval = 60) -> [EPGSlot] {
        var result: [EPGSlot] = []
        var cursor = interval.start
        for programme in programmes(for: channel, in: interval) {
            if programme.start.timeIntervalSince(cursor) >= minimumGap {
                result.append(.gap(DateInterval(start: cursor, end: programme.start)))
            }
            result.append(.programme(programme))
            cursor = max(cursor, programme.end)
        }
        if interval.end.timeIntervalSince(cursor) >= minimumGap {
            result.append(.gap(DateInterval(start: cursor, end: interval.end)))
        }
        return result
    }

    /// Couverture : instant jusqu'auquel le guide de la chaîne est connu.
    public func coverageEnd(for channel: ChannelID) -> Date? {
        programmesByChannel[channel]?.last?.end
    }

    static func lastIndex(in list: [Programme], startingAtOrBefore date: Date) -> Int? {
        var low = 0
        var high = list.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if list[mid].start <= date {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    // MARK: Mise à jour

    /// Fusionne des programmes pour une chaîne. Les programmes existants recouverts
    /// par la plage des nouvelles données sont remplacés si la nouvelle source est
    /// au moins aussi riche ; sinon les nouvelles données ne comblent que les trous.
    public mutating func merge(_ incoming: [Programme], for channel: ChannelID, at date: Date) {
        let cleaned = EPGSanitizer.sanitize(incoming.filter { $0.channel == channel })
        updatedAt[channel] = date
        guard let first = cleaned.first, let last = cleaned.last else { return }
        let coverage = DateInterval(start: first.start, end: max(first.start, last.end))
        let incomingRank = cleaned.map(\.source).max() ?? .xtreamShort
        let existing = programmesByChannel[channel] ?? []

        var kept: [Programme] = []
        var accepted: [Programme] = cleaned
        for programme in existing {
            let overlaps = programme.start < coverage.end && programme.end > coverage.start
            if !overlaps {
                kept.append(programme)
            } else if programme.source > incomingRank {
                // L'existant est plus riche : on le garde, et on retire les entrants qui le chevauchent.
                kept.append(programme)
                accepted.removeAll { $0.start < programme.end && $0.end > programme.start }
            } else if programme.source == incomingRank || programme.source < incomingRank {
                // Conserve l'indicateur d'archive connu si la nouvelle source l'ignore.
                if programme.archiveFlag != nil,
                   let index = accepted.firstIndex(where: { $0.start == programme.start && $0.archiveFlag == nil }) {
                    accepted[index].archiveFlag = programme.archiveFlag
                }
            }
        }
        programmesByChannel[channel] = EPGSanitizer.sanitize(kept + accepted)
    }

    /// Remplace l'intégralité du guide d'une chaîne (import XMLTV complet).
    public mutating func replace(_ programmes: [Programme], for channel: ChannelID, at date: Date) {
        programmesByChannel[channel] = EPGSanitizer.sanitize(programmes)
        updatedAt[channel] = date
    }

    /// Supprime ce qui est plus ancien que `cutoff` (borne mémoire et cache).
    public mutating func prune(before cutoff: Date) {
        for (channel, list) in programmesByChannel {
            let trimmed = list.filter { $0.end > cutoff }
            programmesByChannel[channel] = trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Limite par chaîne : conserve les archives annoncées, pas au-delà.
    public mutating func prune(channel: ChannelID, before cutoff: Date) {
        guard let list = programmesByChannel[channel] else { return }
        programmesByChannel[channel] = list.filter { $0.end > cutoff }
    }
}

public enum EPGSlot: Hashable, Sendable {
    case programme(Programme)
    case gap(DateInterval)

    public var interval: DateInterval {
        switch self {
        case .programme(let p): return p.interval
        case .gap(let i): return i
        }
    }
}

/// Nettoyage des guides incohérents : durées nulles, doublons, chevauchements,
/// durées aberrantes.
public enum EPGSanitizer {
    public static let maximumDuration: TimeInterval = 12 * 3600

    public static func sanitize(_ input: [Programme]) -> [Programme] {
        var list = input
            .filter { $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.source > $1.source : $0.start < $1.start }
        guard !list.isEmpty else { return [] }

        var result: [Programme] = []
        result.reserveCapacity(list.count)
        for index in list.indices {
            var programme = list[index]
            if programme.duration > maximumDuration {
                programme.end = programme.start.addingTimeInterval(maximumDuration)
            }
            if let previous = result.last {
                if previous.start == programme.start {
                    // Doublon : on garde la source la plus riche (déjà triée en premier).
                    continue
                }
                if previous.end > programme.start {
                    // Chevauchement : le précédent s'arrête au début du suivant.
                    result[result.count - 1].end = programme.start
                }
            }
            result.append(programme)
        }
        list = result.filter { $0.end > $0.start }
        return list
    }
}
