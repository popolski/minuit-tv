import Foundation

/// Politique de sécurité du transport.
public enum TransportSecurityPolicy: String, Sendable, Codable, CaseIterable {
    /// HTTP accepté (la majorité des fournisseurs Xtream ne proposent que HTTP).
    case allowHTTP
    /// HTTPS utilisé automatiquement si le serveur annonce un port HTTPS, sinon HTTP.
    case preferHTTPS
    /// Toute connexion non chiffrée est refusée.
    case requireHTTPS
}

/// Client de l'API `player_api.php`.
///
/// Sans état mutable : peut être partagé entre tâches concurrentes.
public struct XtreamClient: Sendable {
    public let credentials: XtreamCredentials
    public let http: HTTPClient
    public let policy: TransportSecurityPolicy
    public var retry: RetryPolicy
    public var now: @Sendable () -> Date

    public init(credentials: XtreamCredentials, http: HTTPClient, policy: TransportSecurityPolicy = .allowHTTP,
                retry: RetryPolicy = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.http = http
        self.policy = policy
        self.retry = retry
        self.now = now
    }

    public var urls: XtreamURLBuilder { XtreamURLBuilder(credentials: credentials) }

    // MARK: Authentification

    /// Vérifie les identifiants et renvoie l'état du compte.
    public func authenticate() async throws(XtreamError) -> XtreamSession {
        guard credentials.isComplete else { throw .missingCredentials }
        if policy == .requireHTTPS, !credentials.server.isSecure { throw .insecureConnectionRefused }

        let data = try await get(urls.apiURL(action: nil))
        let dto: AuthResponseDTO
        do {
            dto = try JSONDecoder().decode(AuthResponseDTO.self, from: data)
        } catch {
            throw .unexpectedResponse(context: "authentification")
        }
        return try Self.session(from: dto, now: now())
    }

    static func session(from dto: AuthResponseDTO, now: Date) throws(XtreamError) -> XtreamSession {
        guard let user = dto.userInfo else {
            // Certains panneaux renvoient `{"user_info":{"auth":0}}` ou un objet vide.
            throw .authenticationRejected
        }
        guard user.auth else { throw .authenticationRejected }

        let status = AccountStatus(raw: user.status)
        let expiry = user.expDate.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        switch status {
        case .banned: throw .accountBanned
        case .disabled: throw .accountDisabled
        case .expired: throw .accountExpired(expiry)
        case .active, .unknown: break
        }
        if let expiry, expiry <= now { throw .accountExpired(expiry) }

        var formats = Set<StreamFormat>()
        var others: [String] = []
        for raw in user.allowedOutputFormats {
            if let format = StreamFormat(rawValue: raw) { formats.insert(format) } else { others.append(raw) }
        }
        // Liste absente : comportement historique des panneaux, TS et HLS sont servis.
        if user.allowedOutputFormats.isEmpty { formats = [.mpegts, .hls] }

        let account = AccountInfo(status: status, expiresAt: expiry, isTrial: user.isTrial,
                                  activeConnections: user.activeConnections, maxConnections: user.maxConnections,
                                  allowedFormats: formats, otherFormats: others)

        let serverDTO = dto.serverInfo
        let timeZone = ServerTimeZoneResolver.resolve(identifier: serverDTO?.timezone,
                                                      timestampNow: serverDTO?.timestampNow,
                                                      timeNow: serverDTO?.timeNow)
        let skew: TimeInterval = serverDTO?.timestampNow.map { TimeInterval($0) - now.timeIntervalSince1970 } ?? 0
        let server = ServerInfo(timeZone: timeZone, clockSkew: abs(skew) > 86_400 ? 0 : skew,
                                httpsPort: serverDTO?.httpsPort, httpPort: serverDTO?.port,
                                advertisedProtocol: serverDTO?.serverProtocol)
        return XtreamSession(account: account, server: server)
    }

    // MARK: Catalogue

    public func liveCategories() async throws(XtreamError) -> [ChannelCategory] {
        try await categories(action: "get_live_categories")
    }

    /// Catégories d'une action (`get_live_categories`, `get_vod_categories`, `get_series_categories`).
    func categories(action: String) async throws(XtreamError) -> [ChannelCategory] {
        let data = try await get(urls.apiURL(action: action))
        guard let list = try? JSONDecoder().decode(LossyArray<LiveCategoryDTO>.self, from: data) else {
            throw .unexpectedResponse(context: "catégories")
        }
        return list.elements.enumerated().map { index, dto in
            ChannelCategory(id: CategoryID(dto.id), name: dto.name.trimmingCharacters(in: .whitespacesAndNewlines), serverOrder: index)
        }
    }

    /// Toutes les chaînes en une requête (plus rapide que par catégorie sur la plupart des serveurs).
    public func liveStreams(category: CategoryID? = nil) async throws(XtreamError) -> [Channel] {
        var parameters: [String: String] = [:]
        if let category { parameters["category_id"] = category.rawValue }
        let data = try await get(urls.apiURL(action: "get_live_streams", parameters: parameters), timeout: 60)
        return try Self.decodeChannels(data)
    }

    /// Repli quand la liste complète est refusée ou trop lourde pour le panneau : les chaînes
    /// catégorie par catégorie, quatre requêtes à la fois. Une catégorie en échec est ignorée ;
    /// si tout le premier lot échoue, le serveur refuse aussi ce mode et l'on abandonne.
    public func liveStreams(byCategory categories: [ChannelCategory]) async throws(XtreamError) -> [Channel] {
        try await Self.mergeByCategory(categories, context: "chaînes", key: { (channel: Channel) in channel.id.rawValue }) { id in
            await self.capture { () throws(XtreamError) in try await self.liveStreams(category: id) }
        }.get()
    }

    func capture<T>(_ body: () async throws(XtreamError) -> T) async -> Result<T, XtreamError> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Chargement par catégorie, quatre requêtes à la fois (direct, films, séries). Une catégorie
    /// en échec est ignorée ; si tout le premier lot échoue, le serveur refuse aussi ce mode.
    /// Les éléments présents dans plusieurs catégories sont fusionnés.
    /// (`Result` plutôt que typed throws : plantage du compilateur 6.1 en contexte générique.)
    static func mergeByCategory<Item: Sendable & Categorized>(
        _ categories: [ChannelCategory], context: String, key: (Item) -> Int,
        fetch: @escaping @Sendable (CategoryID) async -> Result<[Item], XtreamError>
    ) async -> Result<[Item], XtreamError> {
        var merged: [Item] = []
        var position: [Int: Int] = [:]
        var firstError: XtreamError?
        var succeeded = 0
        for start in stride(from: 0, to: categories.count, by: 4) {
            let batch = Array(categories[start..<min(start + 4, categories.count)])
            let results = await withTaskGroup(of: (Int, Result<[Item], XtreamError>).self) { group in
                for (index, category) in batch.enumerated() {
                    group.addTask { (index, await fetch(category.id)) }
                }
                var collected: [(Int, Result<[Item], XtreamError>)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            for (category, result) in zip(batch, results) {
                switch result {
                case .success(let items):
                    succeeded += 1
                    for var item in items {
                        // La requête par catégorie prouve l'appartenance, même si la fiche l'omet.
                        if !item.categoryIDs.contains(category.id) { item.categoryIDs.append(category.id) }
                        if let existing = position[key(item)] {
                            for id in item.categoryIDs where !merged[existing].categoryIDs.contains(id) {
                                merged[existing].categoryIDs.append(id)
                            }
                        } else {
                            position[key(item)] = merged.count
                            merged.append(item)
                        }
                    }
                case .failure(let error):
                    firstError = firstError ?? error
                }
            }
            if succeeded == 0 { return .failure(firstError ?? .unexpectedResponse(context: context)) }
            if Task.isCancelled { return .failure(.transport(.cancelled)) }
        }
        if succeeded == 0 { return .failure(firstError ?? .unexpectedResponse(context: context)) }
        return .success(merged)
    }

    static func decodeChannels(_ data: Data) throws(XtreamError) -> [Channel] {
        guard let list = try? JSONDecoder().decode(LossyArray<LiveStreamDTO>.self, from: data) else {
            throw .unexpectedResponse(context: "chaînes")
        }
        var seen = Set<Int>()
        var channels: [Channel] = []
        channels.reserveCapacity(list.elements.count)
        for dto in list.elements {
            // Exclut explicitement les entrées VOD/séries qu'un panneau mal configuré glisse dans le direct.
            if let type = dto.streamType?.lowercased(), type != "live", type != "created_live", type != "radio_streams" {
                continue
            }
            guard seen.insert(dto.streamID).inserted else { continue }
            var categories = dto.categoryIDs.map(CategoryID.init)
            if let primary = dto.categoryID, !categories.contains(CategoryID(primary)) {
                categories.insert(CategoryID(primary), at: 0)
            }
            let logo = dto.icon.flatMap { raw -> URL? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("http"), let url = URL(string: trimmed) else { return nil }
                return url
            }
            let archive: ArchiveCapability? = dto.tvArchive ? ArchiveCapability(days: dto.tvArchiveDuration ?? 0) : nil
            channels.append(Channel(id: ChannelID(dto.streamID), name: dto.name, number: dto.num, logoURL: logo,
                                    categoryIDs: categories, epgChannelID: dto.epgChannelID,
                                    archive: (archive?.days ?? 0) > 0 ? archive : nil, isAdult: dto.isAdult))
        }
        return channels
    }

    // MARK: Guide

    /// Programme court (actuel + suivants) : `get_short_epg`.
    public func shortEPG(channel: ChannelID, limit: Int = 6, serverTimeZone: TimeZone) async throws(XtreamError) -> [Programme] {
        let data = try await get(urls.apiURL(action: "get_short_epg", parameters: ["stream_id": String(channel.rawValue), "limit": String(limit)]))
        return try Self.decodeProgrammes(data, channel: channel, serverTimeZone: serverTimeZone, source: .xtreamShort)
    }

    /// Guide complet d'une chaîne avec indicateur d'archive : `get_simple_data_table`.
    public func fullEPG(channel: ChannelID, serverTimeZone: TimeZone) async throws(XtreamError) -> [Programme] {
        let data = try await get(urls.apiURL(action: "get_simple_data_table", parameters: ["stream_id": String(channel.rawValue)]), timeout: 30)
        return try Self.decodeProgrammes(data, channel: channel, serverTimeZone: serverTimeZone, source: .xtreamFull)
    }

    static func decodeProgrammes(_ data: Data, channel: ChannelID, serverTimeZone: TimeZone,
                                 source: Programme.Source) throws(XtreamError) -> [Programme] {
        guard let dto = try? JSONDecoder().decode(EPGListingsDTO.self, from: data) else {
            throw .unexpectedResponse(context: "guide")
        }
        return dto.listings.compactMap {
            XtreamEPGMapper.programme(from: $0, channel: channel, serverTimeZone: serverTimeZone, source: source)
        }
    }

    /// Télécharge le XMLTV complet (peut peser plusieurs dizaines de Mo).
    public func downloadXMLTV() async throws(XtreamError) -> Data {
        try await get(urls.xmltvURL(), timeout: 120)
    }

    // MARK: Transport

    func get(_ url: URL, timeout: TimeInterval = 20) async throws(XtreamError) -> Data {
        var attempt = 0
        while true {
            do throws(XtreamError) {
                let response = try await send(url, timeout: timeout)
                return try Self.validate(response)
            } catch {
                attempt += 1
                guard error.isRetryable, attempt < retry.maxAttempts, !Task.isCancelled else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(retry.delay(forAttempt: attempt) * 1_000_000_000))
            }
        }
    }

    private func send(_ url: URL, timeout: TimeInterval) async throws(XtreamError) -> HTTPResponse {
        do { return try await http.send(HTTPRequest(url: url, timeout: timeout)) }
        catch { throw .transport(error) }
    }

    static func validate(_ response: HTTPResponse) throws(XtreamError) -> Data {
        switch response.statusCode {
        case 200..<300:
            return response.body
        case 401, 403:
            // Les panneaux répondent souvent 403 pour un compte expiré ou en excès de connexions,
            // sans détail exploitable : on reste prudent.
            throw .http(status: response.statusCode)
        case 456, 458:
            throw .tooManyConnections(max: nil)
        default:
            throw .http(status: response.statusCode)
        }
    }
}

/// Politique de nouvelle tentative avec temporisation exponentielle bornée.
public struct RetryPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int, baseDelay: TimeInterval, maxDelay: TimeInterval) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let standard = RetryPolicy(maxAttempts: 3, baseDelay: 0.6, maxDelay: 5)
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0)

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
    }
}
