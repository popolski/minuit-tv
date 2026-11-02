import Foundation

/// Identifiant stable d'une chaîne : le `stream_id` Xtream.
public struct ChannelID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(_ rawValue: Int) { self.rawValue = rawValue }
    public var description: String { String(rawValue) }
    public static func < (lhs: ChannelID, rhs: ChannelID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct CategoryID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct ChannelCategory: Identifiable, Hashable, Sendable, Codable {
    public let id: CategoryID
    public var name: String
    /// Ordre fourni par le serveur.
    public var serverOrder: Int

    public init(id: CategoryID, name: String, serverOrder: Int) {
        self.id = id
        self.name = name
        self.serverOrder = serverOrder
    }
}

/// Capacité de rattrapage **annoncée** par l'API (`tv_archive`).
/// Elle ne garantit pas que l'archive soit réellement lisible : voir `CatchupProbe`.
public struct ArchiveCapability: Hashable, Sendable, Codable {
    public var days: Int

    public init(days: Int) { self.days = max(0, days) }

    public var window: TimeInterval { TimeInterval(days) * 86_400 }
}

public struct Channel: Identifiable, Hashable, Sendable, Codable {
    public let id: ChannelID
    public var name: String
    /// Numéro logique fourni par le serveur (`num`).
    public var number: Int?
    public var logoURL: URL?
    public var categoryIDs: [CategoryID]
    /// Identifiant XMLTV (`epg_channel_id`), utilisé pour relier le guide.
    public var epgChannelID: String?
    public var archive: ArchiveCapability?
    public var isAdult: Bool

    public init(id: ChannelID, name: String, number: Int? = nil, logoURL: URL? = nil,
                categoryIDs: [CategoryID] = [], epgChannelID: String? = nil,
                archive: ArchiveCapability? = nil, isAdult: Bool = false) {
        self.id = id
        self.name = name
        self.number = number
        self.logoURL = logoURL
        self.categoryIDs = categoryIDs
        self.epgChannelID = epgChannelID
        self.archive = archive
        self.isAdult = isAdult
    }

    public var hasAnnouncedArchive: Bool { (archive?.days ?? 0) > 0 }
}

public enum AccountStatus: String, Sendable, Codable, Hashable {
    case active = "Active"
    case expired = "Expired"
    case banned = "Banned"
    case disabled = "Disabled"
    case unknown

    init(raw: String?) {
        guard let raw else { self = .unknown; return }
        switch raw.lowercased() {
        case "active": self = .active
        case "expired": self = .expired
        case "banned": self = .banned
        case "disabled": self = .disabled
        default: self = .unknown
        }
    }
}

public enum StreamFormat: String, Sendable, Codable, Hashable, CaseIterable {
    case hls = "m3u8"
    case mpegts = "ts"

    public var fileExtension: String { rawValue }
}

public struct AccountInfo: Sendable, Codable, Hashable {
    public var status: AccountStatus
    public var expiresAt: Date?
    public var isTrial: Bool
    public var activeConnections: Int?
    public var maxConnections: Int?
    public var allowedFormats: Set<StreamFormat>
    /// Formats annoncés mais inconnus de l'application (ex. `rtmp`), conservés pour diagnostic.
    public var otherFormats: [String]

    public init(status: AccountStatus, expiresAt: Date?, isTrial: Bool, activeConnections: Int?,
                maxConnections: Int?, allowedFormats: Set<StreamFormat>, otherFormats: [String] = []) {
        self.status = status
        self.expiresAt = expiresAt
        self.isTrial = isTrial
        self.activeConnections = activeConnections
        self.maxConnections = maxConnections
        self.allowedFormats = allowedFormats
        self.otherFormats = otherFormats
    }

    public func isExpired(at now: Date) -> Bool {
        if status == .expired { return true }
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

public struct ServerInfo: Sendable, Codable, Hashable {
    /// Fuseau du serveur : sert à formater les horodatages des URL de timeshift.
    public var timeZone: TimeZone
    /// Écart observé entre l'horloge du serveur et celle de l'appareil (serveur - local).
    public var clockSkew: TimeInterval
    public var httpsPort: Int?
    public var httpPort: Int?
    public var advertisedProtocol: String?

    public init(timeZone: TimeZone, clockSkew: TimeInterval = 0, httpsPort: Int? = nil,
                httpPort: Int? = nil, advertisedProtocol: String? = nil) {
        self.timeZone = timeZone
        self.clockSkew = clockSkew
        self.httpsPort = httpsPort
        self.httpPort = httpPort
        self.advertisedProtocol = advertisedProtocol
    }
}

public struct XtreamSession: Sendable, Codable, Hashable {
    public var account: AccountInfo
    public var server: ServerInfo

    public init(account: AccountInfo, server: ServerInfo) {
        self.account = account
        self.server = server
    }
}
