import Foundation

/// Un programme du guide, en temps absolu (indépendant de tout fuseau).
public struct Programme: Hashable, Sendable, Codable, Identifiable {
    public var channel: ChannelID
    public var start: Date
    public var end: Date
    public var title: String
    public var subtitle: String?
    public var summary: String?
    public var category: String?
    public var episode: String?
    public var imageURL: URL?
    /// Indicateur d'archive fourni par Xtream (`has_archive`). `nil` : inconnu (XMLTV).
    public var archiveFlag: Bool?
    public var source: Source

    public enum Source: String, Sendable, Codable, Hashable, Comparable {
        case xmltv
        case xtreamShort
        case xtreamFull

        /// Priorité de fusion : une donnée plus riche remplace une donnée moins riche.
        var rank: Int {
            switch self {
            case .xtreamShort: return 0
            case .xmltv: return 1
            case .xtreamFull: return 2
            }
        }
        public static func < (lhs: Source, rhs: Source) -> Bool { lhs.rank < rhs.rank }
    }

    public init(channel: ChannelID, start: Date, end: Date, title: String, subtitle: String? = nil,
                summary: String? = nil, category: String? = nil, episode: String? = nil,
                imageURL: URL? = nil, archiveFlag: Bool? = nil, source: Source) {
        self.channel = channel
        self.start = start
        self.end = end
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.category = category
        self.episode = episode
        self.imageURL = imageURL
        self.archiveFlag = archiveFlag
        self.source = source
    }

    public var id: String { "\(channel.rawValue)-\(Int(start.timeIntervalSince1970))" }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }

    public func isAiring(at date: Date) -> Bool { start <= date && date < end }
    public func hasEnded(at date: Date) -> Bool { end <= date }

    /// Avancement de 0 à 1.
    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / duration))
    }
}

/// Conversion des entrées EPG Xtream (titres et descriptions encodés en base64).
enum XtreamEPGMapper {
    static func programme(from dto: EPGListingDTO, channel: ChannelID, serverTimeZone: TimeZone, source: Programme.Source) -> Programme? {
        let start: Date?
        let end: Date?
        if let ts = dto.startTimestamp, ts > 0 {
            start = Date(timeIntervalSince1970: TimeInterval(ts))
        } else {
            start = dto.start.flatMap { ServerTimeZoneResolver.parseWallClock($0, in: serverTimeZone) }
        }
        if let ts = dto.stopTimestamp, ts > 0 {
            end = Date(timeIntervalSince1970: TimeInterval(ts))
        } else {
            end = dto.end.flatMap { ServerTimeZoneResolver.parseWallClock($0, in: serverTimeZone) }
        }
        guard let start, let end, end > start else { return nil }
        let title = dto.title.map(decodeBase64IfNeeded)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = dto.description.map(decodeBase64IfNeeded)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Programme(channel: channel, start: start, end: end,
                         title: (title?.isEmpty == false ? title! : "Sans titre"),
                         summary: summary?.isEmpty == false ? summary : nil,
                         archiveFlag: source == .xtreamFull ? dto.hasArchive : (dto.hasArchive ? true : nil),
                         source: source)
    }

    /// Xtream encode titres et descriptions en base64, mais certains clones envoient du texte brut.
    /// On ne décode que si le résultat est de l'UTF-8 valide et imprimable.
    static func decodeBase64IfNeeded(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count % 4 == 0 else { return text }
        let base64Characters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard trimmed.unicodeScalars.allSatisfy({ base64Characters.contains($0) }) else { return text }
        guard let data = Data(base64Encoded: trimmed), let decoded = String(data: data, encoding: .utf8) else { return text }
        let controls = decoded.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t" }
        guard controls.isEmpty, !decoded.isEmpty else { return text }
        return decoded
    }
}
