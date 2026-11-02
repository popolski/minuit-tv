import Foundation

// Objets de transfert reflétant les réponses brutes de `player_api.php`.
// Ils restent internes au module : le reste de l'application ne manipule que
// les modèles du domaine (`Channel`, `ChannelCategory`, `AccountInfo`, …).

struct AuthResponseDTO: Decodable {
    let userInfo: UserInfoDTO?
    let serverInfo: ServerInfoDTO?

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }
}

struct UserInfoDTO: Decodable {
    let username: String?
    let auth: Bool
    let status: String?
    let expDate: Int?
    let isTrial: Bool
    let activeConnections: Int?
    let maxConnections: Int?
    let createdAt: Int?
    let allowedOutputFormats: [String]
    let message: String?

    enum CodingKeys: String, CodingKey {
        case username, auth, status, message
        case expDate = "exp_date"
        case isTrial = "is_trial"
        case activeConnections = "active_cons"
        case maxConnections = "max_connections"
        case createdAt = "created_at"
        case allowedOutputFormats = "allowed_output_formats"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = c.lenientString(.username)
        auth = c.lenientBool(.auth)
        status = c.lenientString(.status)
        expDate = c.lenientInt(.expDate)
        isTrial = c.lenientBool(.isTrial)
        activeConnections = c.lenientInt(.activeConnections)
        maxConnections = c.lenientInt(.maxConnections)
        createdAt = c.lenientInt(.createdAt)
        message = c.lenientString(.message)
        if let formats = try? c.decodeIfPresent([LenientString].self, forKey: .allowedOutputFormats) {
            allowedOutputFormats = formats.compactMap(\.nonEmpty).map { $0.lowercased() }
        } else {
            allowedOutputFormats = []
        }
    }
}

struct ServerInfoDTO: Decodable {
    let url: String?
    let port: Int?
    let httpsPort: Int?
    let serverProtocol: String?
    let timezone: String?
    let timestampNow: Int?
    let timeNow: String?

    enum CodingKeys: String, CodingKey {
        case url, port, timezone
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case timestampNow = "timestamp_now"
        case timeNow = "time_now"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.lenientString(.url)
        port = c.lenientInt(.port)
        httpsPort = c.lenientInt(.httpsPort)
        serverProtocol = c.lenientString(.serverProtocol)
        timezone = c.lenientString(.timezone)
        timestampNow = c.lenientInt(.timestampNow)
        timeNow = c.lenientString(.timeNow)
    }
}

struct LiveCategoryDTO: Decodable {
    let id: String
    let name: String
    let parentID: Int?

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
        case parentID = "parent_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "category_id manquant")
        }
        self.id = id
        name = c.lenientString(.name) ?? "Sans nom"
        parentID = c.lenientInt(.parentID)
    }
}

struct LiveStreamDTO: Decodable {
    let streamID: Int
    let num: Int?
    let name: String
    let streamType: String?
    let icon: String?
    let epgChannelID: String?
    let categoryID: String?
    let categoryIDs: [String]
    let tvArchive: Bool
    let tvArchiveDuration: Int?
    let directSource: String?
    let isAdult: Bool

    enum CodingKeys: String, CodingKey {
        case num, name
        case streamID = "stream_id"
        case streamType = "stream_type"
        case icon = "stream_icon"
        case epgChannelID = "epg_channel_id"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
        case tvArchive = "tv_archive"
        case tvArchiveDuration = "tv_archive_duration"
        case directSource = "direct_source"
        case isAdult = "is_adult"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientInt(.streamID) else {
            throw DecodingError.dataCorruptedError(forKey: .streamID, in: c, debugDescription: "stream_id manquant")
        }
        streamID = id
        num = c.lenientInt(.num)
        name = c.lenientString(.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Chaîne \(id)"
        streamType = c.lenientString(.streamType)
        icon = c.lenientString(.icon)
        epgChannelID = c.lenientString(.epgChannelID)
        categoryID = c.lenientString(.categoryID)
        if let ids = try? c.decodeIfPresent([LenientString].self, forKey: .categoryIDs) {
            categoryIDs = ids.compactMap(\.nonEmpty)
        } else {
            categoryIDs = []
        }
        tvArchive = c.lenientBool(.tvArchive)
        tvArchiveDuration = c.lenientInt(.tvArchiveDuration)
        directSource = c.lenientString(.directSource)
        isAdult = c.lenientBool(.isAdult)
    }
}

/// Réponse de `get_short_epg` et `get_simple_data_table`.
struct EPGListingsDTO: Decodable {
    let listings: [EPGListingDTO]

    enum CodingKeys: String, CodingKey { case listings = "epg_listings" }

    init(from decoder: Decoder) throws {
        // Variantes observées : `{"epg_listings": [...]}`, `{"epg_listings": {}}`,
        // `{"epg_listings": {"0": {...}, "1": {...}}}`, ou directement `[]`.
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            // Forme objet d'abord : `LossyArray` accepte tout (y compris un objet) en le traitant comme vide.
            if let dict = try? c.decode([String: EPGListingDTO].self, forKey: .listings) {
                listings = dict.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map(\.value)
            } else if let array = try? c.decode(LossyArray<EPGListingDTO>.self, forKey: .listings) {
                listings = array.elements
            } else {
                listings = []
            }
        } else if let array = try? LossyArray<EPGListingDTO>(from: decoder) {
            listings = array.elements
        } else {
            listings = []
        }
    }
}

struct EPGListingDTO: Decodable {
    let id: String?
    let epgID: String?
    let title: String?
    let description: String?
    let start: String?
    let end: String?
    let startTimestamp: Int?
    let stopTimestamp: Int?
    let channelID: String?
    let hasArchive: Bool
    let nowPlaying: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, description, start, end
        case epgID = "epg_id"
        case startTimestamp = "start_timestamp"
        case stopTimestamp = "stop_timestamp"
        case channelID = "channel_id"
        case hasArchive = "has_archive"
        case nowPlaying = "now_playing"
        case stop
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientString(.id)
        epgID = c.lenientString(.epgID)
        title = c.lenientString(.title)
        description = c.lenientString(.description)
        start = c.lenientString(.start)
        end = c.lenientString(.end) ?? c.lenientString(.stop)
        startTimestamp = c.lenientInt(.startTimestamp)
        stopTimestamp = c.lenientInt(.stopTimestamp)
        channelID = c.lenientString(.channelID)
        hasArchive = c.lenientBool(.hasArchive)
        nowPlaying = c.lenientBool(.nowPlaying)
    }
}
