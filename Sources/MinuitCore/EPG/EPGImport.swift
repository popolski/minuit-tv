import Foundation

/// Relie un document XMLTV aux chaînes Xtream.
///
/// Liaison primaire par `epg_channel_id` (insensible à la casse). En repli, si
/// une chaîne n'a pas d'identifiant, on tente le nom affiché normalisé — c'est
/// une heuristique, désactivable, dont le résultat est signalé dans les diagnostics.
public enum EPGImporter {
    public struct Result: Sendable {
        public var programmes: [ChannelID: [Programme]]
        public var matchedByID: Int
        public var matchedByName: Int
        public var unmatchedChannels: Int
    }

    public static func channelKeys(for channels: [Channel]) -> Set<String> {
        Set(channels.compactMap { $0.epgChannelID?.lowercased() }.filter { !$0.isEmpty })
    }

    public static func map(_ document: XMLTVDocument, to channels: [Channel], matchByName: Bool = true) -> Result {
        var keyToChannels: [String: [ChannelID]] = [:]
        for channel in channels {
            if let key = channel.epgChannelID?.lowercased(), !key.isEmpty {
                keyToChannels[key, default: []].append(channel.id)
            }
        }
        var matchedByName = 0
        if matchByName {
            var nameToKey: [String: String] = [:]
            for xmlChannel in document.channels {
                for name in xmlChannel.displayNames {
                    nameToKey[SearchNormalizer.normalize(name)] = xmlChannel.key.lowercased()
                }
            }
            for channel in channels where (channel.epgChannelID ?? "").isEmpty {
                if let key = nameToKey[SearchNormalizer.normalize(SearchNormalizer.stripProviderPrefix(channel.name))] {
                    keyToChannels[key, default: []].append(channel.id)
                    matchedByName += 1
                }
            }
        }

        var result: [ChannelID: [Programme]] = [:]
        for item in document.programmes {
            guard let targets = keyToChannels[item.channelKey.lowercased()] else { continue }
            let end = item.end ?? item.start.addingTimeInterval(3600)
            for channel in targets {
                result[channel, default: []].append(Programme(
                    channel: channel, start: item.start, end: end, title: item.title, subtitle: item.subtitle,
                    summary: item.summary, category: item.category, episode: item.episode,
                    imageURL: item.iconURL, archiveFlag: nil, source: .xmltv))
            }
        }
        // Programmes sans `stop` : la fin réelle est le début du suivant (le nettoyage tronque).
        let channelsWithKey = channels.filter { !($0.epgChannelID ?? "").isEmpty }.count
        return Result(programmes: result,
                      matchedByID: channelsWithKey,
                      matchedByName: matchedByName,
                      unmatchedChannels: channels.count - result.count)
    }
}

/// Politique d'actualisation du guide.
public struct EPGRefreshPolicy: Sendable, Equatable {
    /// Âge maximal d'un guide complet (XMLTV) avant nouveau téléchargement.
    public var fullRefreshInterval: TimeInterval
    /// Âge maximal du programme court d'une chaîne.
    public var shortRefreshInterval: TimeInterval
    /// Marge minimale de couverture future avant de réactualiser une chaîne.
    public var minimumFutureCoverage: TimeInterval

    public init(fullRefreshInterval: TimeInterval = 6 * 3600,
                shortRefreshInterval: TimeInterval = 20 * 60,
                minimumFutureCoverage: TimeInterval = 2 * 3600) {
        self.fullRefreshInterval = fullRefreshInterval
        self.shortRefreshInterval = shortRefreshInterval
        self.minimumFutureCoverage = minimumFutureCoverage
    }

    public func needsFullRefresh(lastFull: Date?, now: Date) -> Bool {
        guard let lastFull else { return true }
        // Horloge reculée (changement manuel) : on réactualise par prudence.
        if lastFull > now { return true }
        return now.timeIntervalSince(lastFull) >= fullRefreshInterval
    }

    /// Une chaîne doit-elle être réactualisée individuellement ?
    public func needsChannelRefresh(index: EPGIndex, channel: ChannelID, now: Date) -> Bool {
        let (current, _) = index.nowNext(for: channel, at: now)
        let coverage = index.coverageEnd(for: channel)
        let coverageTooShort = coverage.map { $0.timeIntervalSince(now) < minimumFutureCoverage } ?? true
        guard current == nil || coverageTooShort else { return false }
        guard let updated = index.updatedAt[channel] else { return true }
        return now.timeIntervalSince(updated) >= shortRefreshInterval || updated > now
    }
}
