import Foundation
import AVKit
import Network
import Observation
import UIKit
import MinuitCore

/// Pilote unique de la lecture. Garanties :
/// - un seul moteur existe à la fois ; l'ancien est arrêté avant la création d'un autre ;
/// - chaque chargement porte une génération ; tout événement d'une génération périmée est ignoré ;
/// - les appuis rapides de zapping sont regroupés en un seul chargement ;
/// - la santé de lecture est jugée sur des signaux vidéo, pas sur l'horloge seule ;
/// - la reprise après incident est bornée, puis l'échec est affiché clairement.
@MainActor
@Observable
final class PlaybackController {
    enum Phase: Equatable {
        case idle
        case tuning
        case playing
        case recovering(String)
        case resolvingArchive
        case waitingForNetwork
        case failed(String)
    }

    enum Panel: Equatable { case none, controls, channels, programmes, tracks, transport }

    struct ArchiveSession: Equatable {
        /// Fenêtre d'origine (programme complet), référence des positions.
        var original: ArchiveWindow
        /// Fenêtre effectivement demandée (décalée après un repositionnement par requête).
        var current: ArchiveWindow
        var format: StreamFormat
        /// Formats d'archive vérifiés lisibles par sondage.
        var formats: [StreamFormat]
        var style: XtreamURLBuilder.TimeshiftStyle
        /// Décalage de `current.requestStart` par rapport à `original.requestStart`.
        var baseOffset: TimeInterval
        var channel: ChannelID
    }

    // MARK: État observé par l'interface

    private(set) var phase: Phase = .idle
    private(set) var target: PlaybackTarget?
    /// Chaîne affichée dans le bandeau (mise à jour immédiate pendant le zapping).
    private(set) var displayedChannel: ChannelID?
    private(set) var isBuffering = false
    private(set) var isPaused = false
    private(set) var archive: ArchiveSession?
    private(set) var activeAttempt: PlaybackAttempt?
    private(set) var statistics = PlaybackStatistics()
    var bannerVisible = false
    var panel: Panel = .none
    private(set) var toast: String?
    /// Position (s) dans le programme archivé, rafraîchie par la boucle de santé.
    private(set) var archivePosition: TimeInterval = 0

    // MARK: Interne

    /// Conteneur unique de la vue de rendu.
    @ObservationIgnored let hostView = UIView()
    @ObservationIgnored private var engine: PlaybackEngine?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var navigator = ChannelNavigator(list: [], context: .all)
    @ObservationIgnored private var zap = ZapAccumulator()
    @ObservationIgnored private var zapTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var stableTask: Task<Void, Never>?
    @ObservationIgnored private var monitor = PlaybackHealthMonitor()
    @ObservationIgnored private var recovery = RecoveryPlanner(ladder: [])
    @ObservationIgnored private var memory = PlaybackMemory()
    @ObservationIgnored private var hadFirstFrame = false
    @ObservationIgnored private var lastFailure: PlaybackFailure?
    @ObservationIgnored private var suspendedTarget: PlaybackTarget?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkAvailable = true
    /// Interface réseau active (« Wi-Fi », « Ethernet »…), pour le diagnostic.
    @ObservationIgnored private(set) var networkInterface = "Inconnue"
    /// Retard sur le direct dû aux pauses (observé : le bandeau l'affiche).
    private var delayClock = LiveDelayClock()
    @ObservationIgnored private let log = DiagnosticsLog.shared
    @ObservationIgnored weak var app: AppModel?
    /// Mode démo (`-uitest`) : vidéo locale à la place des flux du fournisseur.
    @ObservationIgnored var mediaOverride: URL?

    init() {
        hostView.backgroundColor = .black
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let interface = path.usesInterfaceType(.wiredEthernet) ? "Ethernet"
                : path.usesInterfaceType(.wifi) ? "Wi-Fi" : satisfied ? "Autre" : "Aucune"
            Task { @MainActor in
                self?.networkInterface = interface
                self?.networkChanged(available: satisfied)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "minuit.network"))
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    var isLive: Bool { target?.isLive ?? true }

    // MARK: Contexte de zapping

    func setZapList(_ channels: [ChannelID], context: ChannelListContext) {
        navigator.setList(channels, context: context)
    }

    var zapContext: ChannelListContext { navigator.context }

    // MARK: Direct

    func playLive(_ channel: ChannelID) {
        zapTask?.cancel()
        zap.cancel()
        navigator.tune(channel)
        displayedChannel = channel
        showBanner()
        // Aperçu déjà en cours sur cette chaîne : passage en plein écran sans recharger.
        if isPreview, target == .live(channel), phase != .idle {
            isPreview = false
            engine?.isMuted = false
            if hadFirstFrame { app?.recordWatched(channel) }
            log.log(.info, "lecture", "Aperçu promu en plein écran (\(channel))")
            return
        }
        isPreview = false
        tune(.live(channel))
    }

    // MARK: Aperçu (écran Direct)

    /// Vrai pendant l'aperçu muet de l'écran Direct. Le même et unique lecteur sert à
    /// l'aperçu puis au plein écran : jamais deux connexions simultanées au fournisseur.
    private(set) var isPreview = false

    func startPreview(_ channel: ChannelID) {
        guard !isPreview || target != .live(channel) else { return }
        isPreview = true
        navigator.tune(channel)
        displayedChannel = channel
        tune(.live(channel))
    }

    func stopPreview() {
        guard isPreview else { return }
        close()
    }

    /// Zapping relatif (+1 suivante, -1 précédente). L'affichage est immédiat ;
    /// le chargement part quand la saisie se stabilise.
    func zap(by offset: Int) {
        guard isLive || target == nil else {
            showToast("Revenez au direct pour changer de chaîne")
            return
        }
        guard let next = navigator.step(offset) else { return }
        displayedChannel = next
        showBanner()
        zap.register(target: next, at: now)
        zapTask?.cancel()
        zapTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.zap.settleDelay * 1_000_000_000) + 10_000_000)
            guard !Task.isCancelled, let committed = self.zap.commitIfSettled(at: self.now) else { return }
            self.tune(.live(committed))
        }
    }

    func recallPreviousChannel() {
        guard let previous = navigator.recall() else { return }
        displayedChannel = previous
        showBanner()
        tune(.live(previous))
    }

    func retry() {
        guard let target else { return }
        tune(target)
    }

    // MARK: Chargement

    private func tune(_ newTarget: PlaybackTarget) {
        guard let app, let session = app.session else { return }
        target = newTarget
        displayedChannel = newTarget.channel
        lastFailure = nil
        isPaused = false

        let ladder: [PlaybackAttempt]
        switch newTarget {
        case .live(let channel):
            archive = nil
            let planner = PlaybackPlanner(availableEngines: EngineFactory.availableKinds, preference: app.settings.enginePreference)
            ladder = planner.ladder(allowedFormats: session.account.allowedFormats, remembered: memory.attempt(for: channel))
        case .archive:
            guard let archive else { return }
            ladder = archiveLadder(for: archive.formats)
        }
        guard !ladder.isEmpty else {
            fail(.unsupportedFormat)
            return
        }
        recovery = RecoveryPlanner(ladder: ladder)
        statistics.tunes += 1
        start(ladder[0])
    }

    /// Échelle de lecture d'une archive : MPEG-TS par AetherEngine d'abord (format natif des
    /// archives Xtream, celui qui fonctionne en direct), puis HLS par AVPlayer, puis HLS par AetherEngine.
    private func archiveLadder(for formats: [StreamFormat]) -> [PlaybackAttempt] {
        let available = EngineFactory.availableKinds
        var ladder: [PlaybackAttempt] = []
        if formats.contains(.mpegts) { ladder.append(PlaybackAttempt(engine: .aether, format: .mpegts)) }
        if formats.contains(.hls) {
            ladder.append(PlaybackAttempt(engine: .avPlayer, format: .hls))
            ladder.append(PlaybackAttempt(engine: .aether, format: .hls))
        }
        return ladder.filter { available.contains($0.engine) }
    }

    private func start(_ attempt: PlaybackAttempt) {
        guard let app, let client = app.client, let target else { return }
        generation += 1
        let gen = generation
        loadTask?.cancel()
        activeAttempt = attempt
        if archive != nil { archive?.format = attempt.format }
        hadFirstFrame = false
        isBuffering = false
        delayClock.reset()   // tout chargement repart du point de direct
        phase = .tuning
        monitor.reset(at: now)
        stableTask?.cancel()

        guard let engine = installEngine(attempt.engine) else {
            handle(.failed(.unsupportedFormat), generation: gen)
            return
        }
        engine.onEvent = { [weak self] event in self?.handle(event, generation: gen) }

        var request: EngineLoadRequest
        switch target {
        case .live(let channel):
            request = EngineLoadRequest(url: client.urls.liveURL(channel: channel, format: attempt.format), format: attempt.format,
                                        mode: .live, userAgent: app.settings.userAgentPreset.value,
                                        matchContent: app.settings.matchContentFrameRate && !isPreview)
        case .archive(let channel, let window, let offset):
            guard let session = app.session, let archive else { return }
            let url = client.urls.timeshiftURL(channel: channel, start: window.requestStart, durationMinutes: window.durationMinutes,
                                               serverTimeZone: session.server.timeZone, style: archive.style, format: attempt.format)
            request = EngineLoadRequest(url: url, format: attempt.format,
                                        mode: .archive(durationSeconds: Double(window.durationMinutes * 60), startOffset: offset),
                                        userAgent: app.settings.userAgentPreset.value,
                                        matchContent: app.settings.matchContentFrameRate)
        }
        if let mediaOverride {
            // Mode démo / tests d'interface : vidéo locale lue comme un programme fini.
            request = EngineLoadRequest(url: mediaOverride, format: .hls, mode: .archive(durationSeconds: 60, startOffset: 0),
                                        userAgent: request.userAgent, matchContent: false)
        }
        log.log(.info, "lecture", "Chargement \(gen) : \(attempt) — \(request.url.absoluteString)")

        loadTask = Task { [weak self] in
            do {
                try await engine.load(request)
            } catch is CancellationError {
                return
            } catch {
                guard let self, gen == self.generation else { return }
                let ns = error as NSError
                let failure: PlaybackFailure
                if (error as? EngineError) == .unsupported {
                    failure = .unsupportedFormat
                } else if (ns.domain == NSURLErrorDomain && (-1206 ... -1200).contains(ns.code))
                            || "\(error)".localizedCaseInsensitiveContains("secure connection") {
                    failure = .certificateRejected
                } else {
                    failure = .unknown("\(error)")
                }
                self.handle(.failed(failure), generation: gen)
            }
        }
        startHealthLoop()
    }

    /// Installe le moteur demandé ; arrête et retire l'éventuel moteur d'un autre type.
    private func installEngine(_ kind: EngineKind) -> PlaybackEngine? {
        if let engine, engine.kind == kind { return engine }
        if let old = engine {
            old.onEvent = nil
            old.stop()
            old.renderView.removeFromSuperview()
            engine = nil
        }
        guard let fresh = EngineFactory.make(kind) else { return nil }
        let view = fresh.renderView
        view.frame = hostView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.addSubview(view)
        fresh.fillsScreen = fillsScreen
        fresh.isMuted = isPreview
        engine = fresh
        return fresh
    }

    // MARK: Événements moteur

    private func handle(_ event: EngineEvent, generation gen: UInt64) {
        guard gen == generation else { return }
        switch event {
        case .firstFrame:
            hadFirstFrame = true
            phase = .playing
            if let ttff = monitor.timeToFirstFrame { statistics.recordFirstFrame(ttff) }
            if case .live(let channel) = target, let attempt = activeAttempt {
                memory.remember(attempt, for: channel)
                // La navigation en aperçu ne remplit pas l'historique des chaînes regardées.
                if !isPreview { app?.recordWatched(channel) }
            }
            engine?.isMuted = isPreview
            log.log(.info, "lecture", "Première image (\(gen)) via \(activeAttempt?.description ?? "?")")
            stableTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                self.recovery.markStable()
            }
        case .playing:
            if hadFirstFrame, phase != .playing { phase = .playing }
        case .buffering(let value):
            isBuffering = value
        case .failed(let failure):
            handleFailure(failure)
        case .sourceReset:
            handleFailure(.sourceEnded)
        case .ended:
            if case .archive = target {
                showToast("Fin du programme")
                isPaused = true
            } else {
                handleFailure(.sourceEnded)
            }
        }
    }

    private func handleFailure(_ failure: PlaybackFailure) {
        guard target != nil else { return }
        lastFailure = failure
        log.log(.warning, "lecture", "Incident (\(generation)) : \(failure) via \(activeAttempt?.description ?? "?") — \(engine?.lastErrorDetail ?? "sans détail")")
        if !networkAvailable {
            phase = .waitingForNetwork
            stopHealthLoop()
            return
        }
        switch recovery.next(after: failure, hadFirstFrame: hadFirstFrame, at: now) {
        case .reload(let delay):
            statistics.recoveries += 1
            phase = .recovering("Reconnexion…")
            let attempt = activeAttempt
            generation += 1
            let gen = generation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, gen == self.generation, let attempt else { return }
                self.restartForRecovery(attempt)
            }
        case .fallBack(let attempt):
            statistics.fallbacks += 1
            log.log(.info, "lecture", "Repli vers \(attempt)")
            phase = .recovering("Changement de moteur…")
            restartForRecovery(attempt)
        case .giveUp(let failure):
            fail(failure)
        }
    }

    private func restartForRecovery(_ attempt: PlaybackAttempt) {
        // Archive : reprendre là où l'on en était, par nouvelle requête.
        if case .archive = target, let archive {
            let offset = archive.baseOffset + (engine?.currentPosition ?? 0)
            let shifted = archive.original.shifted(toStreamOffset: offset)
            self.archive?.current = shifted.window
            self.archive?.baseOffset = offset - shifted.residual
            target = .archive(archive.channel, shifted.window, offset: shifted.residual)
        }
        start(attempt)
    }

    private func fail(_ failure: PlaybackFailure) {
        statistics.failures += 1
        stopHealthLoop()
        failureDetail = [activeAttempt?.description, engine?.lastErrorDetail].compactMap { $0 }.joined(separator: " · ")
        engine?.stop()   // libère la connexion du compte
        phase = .failed(failure.userMessage)
        log.log(.error, "lecture", "Abandon : \(failure) — \(failureDetail ?? "")")
        if case .live(let channel) = target, mediaOverride == nil, let format = activeAttempt?.format {
            refineFailure(failure, channel: channel, format: format)
        }
    }

    /// Après abandon (moteur déjà arrêté), un sondage de 4 Ko du flux précise la cause :
    /// page d'erreur du fournisseur à la place de la vidéo, refus HTTP masqué par le moteur.
    private func refineFailure(_ failure: PlaybackFailure, channel: ChannelID, format: StreamFormat) {
        guard let client = app?.client else { return }
        let gen = generation
        let url = client.urls.liveURL(channel: channel, format: format)
        Task { [weak self] in
            let verdict = await ArchiveProbe.probe(url, using: client.http, timeout: 8)
            guard let self, gen == self.generation, case .failed = self.phase else { return }
            let refined = failure.refined(by: verdict)
            self.log.log(.info, "lecture", "Sondage après abandon : \(verdict)")
            guard refined != failure else { return }
            self.phase = .failed(refined.userMessage)
            self.log.log(.warning, "lecture", "Cause précisée : \(refined)")
        }
    }

    /// Détail technique du dernier échec (moteur, format, erreur), affiché sous le message.
    private(set) var failureDetail: String?

    // MARK: Santé

    private func startHealthLoop() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.evaluateHealth()
            }
        }
    }

    private func stopHealthLoop() {
        healthTask?.cancel()
        healthTask = nil
    }

    private func evaluateHealth() {
        guard let engine, target != nil else { return }
        switch phase {
        case .tuning, .playing: break
        default: return
        }
        let sample = engine.healthSample(at: now, wantsToPlay: !isPaused)
        if let archive {
            archivePosition = max(0, archive.baseOffset + engine.currentPosition - archive.original.programmeOffset)
        }
        let verdict = monitor.evaluate(sample)
        if verdict.needsRecovery {
            handleFailure(.health(verdict))
        }
    }

    // MARK: Réseau, veille

    private func networkChanged(available: Bool) {
        let wasAvailable = networkAvailable
        networkAvailable = available
        if available, !wasAvailable, phase == .waitingForNetwork, let target {
            log.log(.info, "lecture", "Réseau rétabli, reprise")
            tune(target.isLive ? .live(target.channel) : target)
        }
    }

    /// Passage en arrière-plan / veille : on libère tout (connexion comprise).
    func suspend() {
        guard let target else { return }
        suspendedTarget = target
        if case .archive = target, let archive {
            let offset = archive.baseOffset + (engine?.currentPosition ?? 0)
            let shifted = archive.original.shifted(toStreamOffset: offset)
            self.archive?.current = shifted.window
            self.archive?.baseOffset = offset - shifted.residual
            suspendedTarget = .archive(archive.channel, shifted.window, offset: shifted.residual)
        }
        teardown()
        self.target = nil
        phase = .idle
    }

    /// Retour au premier plan : le direct reprend au point de direct, l'archive à sa position.
    func resume() {
        guard let suspended = suspendedTarget else { return }
        suspendedTarget = nil
        tune(suspended)
    }

    /// Fermeture du lecteur.
    func close() {
        isPreview = false
        suspendedTarget = nil
        teardown()
        target = nil
        archive = nil
        phase = .idle
        panel = .none
        // Rendre à l'écran son mode par défaut (fréquence / HDR).
        hostView.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    private func teardown() {
        generation += 1
        zapTask?.cancel()
        loadTask?.cancel()
        stableTask?.cancel()
        stopHealthLoop()
        if let engine {
            engine.onEvent = nil
            engine.stop()
            engine.renderView.removeFromSuperview()
        }
        engine = nil
        activeAttempt = nil
    }

    // MARK: Transport

    func togglePlayPause() {
        guard let engine, target != nil else { return }
        if isPaused {
            engine.play()
            isPaused = false
            if isLive { delayClock.resume(at: Date()) }
        } else {
            engine.pause()
            isPaused = true
            if isLive { delayClock.pause(at: Date()) }
        }
    }

    /// Retard sur le direct (0 hors direct ou sans pause).
    func liveDelay(at date: Date) -> TimeInterval {
        isLive ? delayClock.delay(at: date) : 0
    }

    /// Rattrape le direct après une pause.
    func catchUpLive() {
        guard isLive, let engine else { return }
        delayClock.reset()
        if isPaused {
            isPaused = false
            engine.play()
        }
        Task { await engine.seekToLiveEdge() }
        showBanner()
        showToast("Retour au direct")
    }

    // MARK: Diagnostic de connexion

    struct ConnectionCheck {
        var report: ConnectionReport
        var networkDetail: String
        var internetDetail: String
        var providerDetail: String
    }

    /// Réseau local, Internet (page de test d'Apple) puis serveur du fournisseur
    /// (`player_api`, qui ne consomme pas de connexion de flux).
    func checkConnection() async -> ConnectionCheck? {
        guard let app, let client = app.client else { return nil }
        let network: ConnectionReport.Status = networkAvailable ? .ok : .failed

        let internetStart = ContinuousClock.now
        var internetLatency: TimeInterval?
        if let url = URL(string: "https://www.apple.com/library/test/success.html"),
           let response = try? await client.http.send(HTTPRequest(url: url, timeout: 6)),
           (200..<400).contains(response.statusCode) {
            internetLatency = Self.seconds(since: internetStart)
        }

        let probe = XtreamClient(credentials: client.credentials, http: client.http, policy: client.policy, retry: .none)
        let providerStart = ContinuousClock.now
        var providerLatency: TimeInterval?
        var providerError: XtreamError?
        var account: AccountInfo?
        do {
            account = try await probe.authenticate().account
            providerLatency = Self.seconds(since: providerStart)
        } catch {
            switch error {
            case .transport, .http(500...599): break   // serveur injoignable ou en panne
            default:
                // Le serveur répond, mais refuse : la cause est côté compte.
                providerLatency = Self.seconds(since: providerStart)
                providerError = error
            }
        }

        let report = ConnectionReport(network: network,
                                      internet: ConnectionReport.status(latency: internetLatency),
                                      provider: ConnectionReport.status(latency: providerLatency),
                                      providerError: providerError)
        var providerDetail = Self.latencyText(providerLatency)
        if let account, let max = account.maxConnections, max > 0 {
            providerDetail += " · \(account.activeConnections ?? 0)/\(max) connexions"
        }
        log.log(.info, "diagnostic", "Réseau \(networkInterface) \(network) · Internet \(report.internet) · Fournisseur \(report.provider) — \(report.conclusion)")
        return ConnectionCheck(report: report, networkDetail: networkAvailable ? networkInterface : "Déconnecté",
                               internetDetail: Self.latencyText(internetLatency), providerDetail: providerDetail)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func latencyText(_ latency: TimeInterval?) -> String {
        latency.map { "répond en \(Int(($0 * 1000).rounded())) ms" } ?? "ne répond pas"
    }

    // MARK: Replay / Start Over

    /// Lance un programme archivé (ou « reprendre au début »), après vérification réelle.
    func playArchive(programme: Programme) async {
        guard let app, let session = app.session, let channel = app.library.channel(programme.channel) else { return }
        let serverNow = Date().addingTimeInterval(session.server.clockSkew)
        let availability = CatchupEvaluator.evaluate(programme: programme, channel: channel, now: serverNow, settings: app.settings.catchup)
        guard let window = availability.window else {
            showToast(availability.userLabel)
            return
        }
        let previousPhase = phase
        phase = .resolvingArchive
        let formats: [StreamFormat] = [.hls, .mpegts].filter { format in
            session.account.allowedFormats.contains(format) && !archiveLadder(for: [format]).isEmpty
        }
        let resolution = await app.archive.resolve(channel: channel.id, window: window, formats: formats)
        switch resolution {
        case .unavailable(let reason):
            phase = previousPhase == .resolvingArchive ? .idle : previousPhase
            showToast(reason)
            log.log(.warning, "replay", reason)
        case .playable(let playableFormats, let style):
            let ladder = archiveLadder(for: playableFormats)
            log.log(.info, "replay", "Formats lisibles : \(playableFormats.map(\.rawValue)) — essais : \(ladder.map(\.description))")
            archive = ArchiveSession(original: window, current: window, format: ladder.first?.format ?? playableFormats[0],
                                     formats: playableFormats, style: style, baseOffset: 0, channel: channel.id)
            archivePosition = 0
            panel = .none
            displayedChannel = channel.id
            tune(.archive(channel.id, window, offset: window.programmeOffset))
        }
    }

    /// Avance / recul dans l'archive (secondes, relatif).
    func seekArchive(by delta: TimeInterval) {
        guard let archive, let engine else { return }
        let programmeLength = archive.original.programmeEnd.timeIntervalSince(archive.original.programmeStart)
        let target = min(max(0, archivePosition + delta), programmeLength + 240)
        seekArchive(toProgrammePosition: target, using: engine, session: archive)
    }

    func restartArchiveFromBeginning() {
        guard let archive, let engine else { return }
        seekArchive(toProgrammePosition: 0, using: engine, session: archive)
    }

    private func seekArchive(toProgrammePosition position: TimeInterval, using engine: PlaybackEngine, session: ArchiveSession) {
        let streamOffset = position + session.original.programmeOffset
        archivePosition = position
        if engine.canSeekInPlace {
            Task { await engine.seek(to: streamOffset - session.baseOffset) }
            return
        }
        // Origine séquentielle : nouvelle requête à la minute près, puis ajustement fin si possible.
        let shifted = session.original.shifted(toStreamOffset: streamOffset)
        archive?.current = shifted.window
        archive?.baseOffset = streamOffset - shifted.residual
        tune(.archive(session.channel, shifted.window, offset: shifted.residual))
    }

    func returnToLive() {
        guard let channel = target?.channel ?? displayedChannel else { return }
        archive = nil
        playLive(channel)
    }

    // MARK: Pistes, bandeau, messages

    /// Image recadrée pour remplir l'écran (sinon ajustée, bandes noires possibles).
    private(set) var fillsScreen = false

    func toggleFillMode() {
        fillsScreen.toggle()
        engine?.fillsScreen = fillsScreen
        showToast(fillsScreen ? "Image : plein écran" : "Image : ajustée")
    }

    func reloadCurrent() {
        guard let target else { return }
        tune(target)
    }

    var audioTracks: [EngineTrack] { engine?.audioTracks ?? [] }
    func selectAudioTrack(_ id: Int) { engine?.selectAudioTrack(id: id) }
    var technicalSummary: String { engine?.technicalSummary ?? "Aucun moteur actif" }

    func showBanner(duration: TimeInterval = 5) {
        bannerVisible = true
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            // En pause, le bandeau reste : il montre le retard qui grandit.
            guard let self, !Task.isCancelled, self.panel == .none, !self.isPaused else { return }
            self.bannerVisible = false
        }
    }

    func hideOverlays() {
        bannerTask?.cancel()
        bannerVisible = false
        panel = .none
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toast = nil
        }
    }
}
