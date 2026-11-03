import Foundation
import Observation
import MinuitCore

/// État global de l'application : session Xtream, catalogue, préférences, services.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut(message: String?)
        case loading(String)
        case ready
        /// Catalogue en cache affiché, mais serveur injoignable.
        case degraded(String)
    }

    private(set) var phase: Phase = .launching
    private(set) var session: XtreamSession?
    private(set) var library = ChannelLibrary.empty
    private(set) var preferences = LibraryPreferences()
    private(set) var settings = AppSettings()
    private(set) var catalogUpdatedAt: Date?
    private(set) var serverDisplayName = ""
    private(set) var isSecureConnection = false

    let epg = EPGService()
    let playback = PlaybackController()
    @ObservationIgnored let archive = ArchiveService()
    @ObservationIgnored private(set) var client: XtreamClient?

    @ObservationIgnored private let keychain = KeychainCredentialStore()
    @ObservationIgnored private let preferencesStore = StoredValue<LibraryPreferences>(key: "library-preferences", storage: AppModel.storage)
    @ObservationIgnored private let settingsStore = StoredValue<AppSettings>(key: "settings", storage: AppModel.storage)
    @ObservationIgnored private let sessionStore = StoredValue<XtreamSession>(key: "session", storage: AppModel.storage)
    @ObservationIgnored private let cache = FileCache.applicationCaches()
    @ObservationIgnored private let log = DiagnosticsLog.shared
    @ObservationIgnored private var credentials: XtreamCredentials?

    /// Préférences en mémoire en mode démo : les tests partent toujours du même état.
    private static let storage: KeyValueStorage = DemoMode.isEnabled ? InMemoryStorage() : UserDefaultsStorage()

    private struct CatalogSnapshot: Codable {
        var categories: [ChannelCategory]
        var channels: [Channel]
    }

    init() {
        preferences = preferencesStore.load() ?? LibraryPreferences()
        settings = settingsStore.load() ?? AppSettings()
        playback.app = self
        archive.onStyleConfirmed = { [weak self] style in
            self?.updateSettings { $0.catchup.confirmedStyle = style }
        }
    }

    // MARK: Démarrage

    /// Reconnexion automatique : identifiants du trousseau, catalogue du cache affiché
    /// immédiatement, puis vérification et actualisation en arrière-plan.
    func start() async {
        if DemoMode.isEnabled {
            credentials = DemoMode.credentials
            configureClient(DemoMode.credentials)
            playback.mediaOverride = DemoMode.mediaURL
            phase = .loading("Mode démonstration…")
            await refresh(silently: false)
            // Reproduit un appareil déjà utilisé : dernière chaîne regardée en bas de liste.
            if ProcessInfo.processInfo.arguments.contains("-demoLastChannel") {
                recordWatched(ChannelID(101))
                recordWatched(ChannelID(501))
            }
            return
        }
        guard let stored = keychain.load() else {
            phase = .signedOut(message: nil)
            return
        }
        credentials = stored
        configureClient(stored)
        if let cachedSession = sessionStore.load(), let snapshot = cache.read(CatalogSnapshot.self, name: catalogCacheName(stored)) {
            session = cachedSession
            applyCatalog(snapshot.value.categories, snapshot.value.channels, savedAt: snapshot.savedAt)
            phase = .ready
            Task { await refresh(silently: true) }
        } else {
            phase = .loading("Connexion au serveur…")
            await refresh(silently: false)
        }
    }

    func signIn(server: String, username: String, password: String) async {
        let address: ServerAddress
        do { address = try ServerAddress.parse(server) } catch {
            phase = .signedOut(message: XtreamError.invalidServerAddress.userMessage)
            return
        }
        let candidate = XtreamCredentials(server: address, username: username, password: password)
        phase = .loading("Vérification du compte…")
        configureClient(candidate)
        do {
            let session = try await authenticateWithUpgrade(candidate)
            try keychain.save(credentials ?? candidate)
            self.session = session
            try? sessionStore.save(session)
            phase = .loading("Chargement des chaînes…")
            try await loadCatalog()
            phase = .ready
        } catch let error as XtreamError {
            client = nil
            credentials = nil
            phase = .signedOut(message: error.userMessage)
        } catch {
            client = nil
            credentials = nil
            phase = .signedOut(message: "Impossible d'enregistrer les identifiants dans le trousseau.")
        }
    }

    func signOut() {
        playback.close()
        keychain.delete()
        sessionStore.clear()
        if let credentials { cache.remove(name: catalogCacheName(credentials)) }
        epg.reset()
        credentials = nil
        client = nil
        session = nil
        library = .empty
        phase = .signedOut(message: nil)
    }

    /// Actualise compte + catalogue. En mode silencieux, une erreur réseau laisse
    /// le catalogue en cache utilisable (mode dégradé) ; une erreur de compte déconnecte.
    func refresh(silently: Bool) async {
        guard let credentials else { return }
        do {
            let session = try await authenticateWithUpgrade(credentials)
            self.session = session
            try? sessionStore.save(session)
            try await loadCatalog()
            phase = .ready
        } catch let error as XtreamError {
            log.log(.warning, "compte", "Actualisation : \(error.userMessage)")
            if error.requiresUserAction {
                signOut()
                phase = .signedOut(message: error.userMessage)
            } else if !library.channels.isEmpty {
                phase = .degraded(error.userMessage)
            } else if !silently {
                phase = .degraded(error.userMessage)
            }
        } catch {
            phase = .degraded("Erreur inattendue.")
        }
    }

    // MARK: Interne

    private func configureClient(_ credentials: XtreamCredentials) {
        self.credentials = credentials
        let http: HTTPClient = DemoMode.isEnabled
            ? DemoXtreamHTTPClient()
            : URLSessionHTTPClient(userAgent: settings.userAgentPreset.value,
                                   trustsInvalidCertificates: settings.acceptInvalidStreamCertificates)
        EngineFactory.applyCertificatePolicy(acceptInvalid: settings.acceptInvalidStreamCertificates)
        client = XtreamClient(credentials: credentials, http: http, policy: settings.transportSecurity)
        serverDisplayName = credentials.server.displayHost
        isSecureConnection = credentials.server.isSecure
        log.updateRedactor(Redactor(credentials: credentials))
    }

    /// Politique « préférer HTTPS » : si le serveur annonce un port HTTPS, on tente la
    /// connexion chiffrée et on la conserve si elle fonctionne.
    private func authenticateWithUpgrade(_ credentials: XtreamCredentials) async throws -> XtreamSession {
        guard let client else { throw XtreamError.missingCredentials }
        let session = try await client.authenticate()
        guard settings.transportSecurity == .preferHTTPS, !credentials.server.isSecure,
              let httpsPort = session.server.httpsPort, httpsPort > 0 else { return session }
        var upgraded = credentials
        upgraded.server = credentials.server.upgradedToHTTPS(port: httpsPort)
        let secureClient = XtreamClient(credentials: upgraded, http: client.http, policy: settings.transportSecurity, retry: .none)
        do {
            let secureSession = try await secureClient.authenticate()
            configureClient(upgraded)
            try? keychain.save(upgraded)
            log.log(.info, "compte", "Connexion HTTPS confirmée sur le port \(httpsPort)")
            return secureSession
        } catch {
            log.log(.info, "compte", "HTTPS annoncé mais inutilisable, maintien de HTTP")
            return session
        }
    }

    private func loadCatalog() async throws {
        guard let client, let credentials, let session else { return }
        async let categoriesTask = client.liveCategories()
        async let channelsTask = client.liveStreams()
        let (categories, channels) = try await (categoriesTask, channelsTask)
        applyCatalog(categories, channels, savedAt: Date())
        try? cache.write(CatalogSnapshot(categories: categories, channels: channels), name: catalogCacheName(credentials))
        epg.configure(client: client, session: session, channels: channels, settings: settings)
        archive.configure(client: client, session: session, settings: settings.catchup)
        epg.refreshFullIfNeeded()
    }

    private func applyCatalog(_ categories: [ChannelCategory], _ channels: [Channel], savedAt: Date) {
        library = ChannelLibrary(categories: categories, channels: channels)
        catalogUpdatedAt = savedAt
        var prefs = preferences
        prefs.prune(validChannels: Set(channels.map(\.id)), validCategories: Set(categories.map(\.id)))
        if prefs != preferences { savePreferences(prefs) }
        if let client, let session {
            epg.configure(client: client, session: session, channels: channels, settings: settings)
            archive.configure(client: client, session: session, settings: settings.catchup)
        }
    }

    private func catalogCacheName(_ credentials: XtreamCredentials) -> String {
        // Nom de fichier sans secret : hôte + empreinte non réversible de l'identifiant.
        // FNV-1a : stable d'un lancement à l'autre (contrairement à `Hasher`, aléatoire par processus).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in credentials.username.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return "catalog-\(credentials.server.host)-\(hash % 1_000_000)"
    }

    // MARK: Préférences

    func channels(in context: ChannelListContext) -> [Channel] {
        library.channels(in: context, preferences: preferences)
    }

    func isFavorite(_ id: ChannelID) -> Bool { preferences.isFavorite(id) }

    func toggleFavorite(_ id: ChannelID) {
        var prefs = preferences
        prefs.toggleFavorite(id)
        savePreferences(prefs)
    }

    func moveFavorite(_ id: ChannelID, by delta: Int) {
        var prefs = preferences
        prefs.moveFavorite(id, by: delta)
        savePreferences(prefs)
    }

    func recordWatched(_ id: ChannelID) {
        var prefs = preferences
        prefs.recordWatched(id)
        savePreferences(prefs)
    }

    func setCategoryHidden(_ id: CategoryID, hidden: Bool) {
        var prefs = preferences
        prefs.setHidden(hidden, category: id)
        savePreferences(prefs)
    }

    func moveCategory(_ id: CategoryID, by delta: Int) {
        var prefs = preferences
        prefs.moveCategory(id, by: delta, allCategories: library.categories)
        savePreferences(prefs)
    }

    func setLastCategory(_ id: CategoryID?) {
        var prefs = preferences
        prefs.lastCategory = id
        savePreferences(prefs)
    }

    func setHideAdult(_ hide: Bool) {
        var prefs = preferences
        prefs.hideAdultContent = hide
        savePreferences(prefs)
    }

    private func savePreferences(_ prefs: LibraryPreferences) {
        preferences = prefs
        do { try preferencesStore.save(prefs) }
        catch { log.log(.error, "préférences", "Sauvegarde impossible : \(error)") }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        let transportChanged = copy.transportSecurity != settings.transportSecurity || copy.userAgentPreset != settings.userAgentPreset
            || copy.acceptInvalidStreamCertificates != settings.acceptInvalidStreamCertificates
        settings = copy
        try? settingsStore.save(copy)
        if transportChanged, let credentials { configureClient(credentials) }
    }

    func clearCaches() {
        epg.reset()
        cache.removeAll()
    }

    /// Chaîne à reprendre au lancement (réglage « Reprendre la dernière chaîne »).
    var resumeChannel: Channel? {
        guard settings.resumeLastChannelOnLaunch, let id = preferences.lastChannel else { return nil }
        return library.channel(id)
    }
}
