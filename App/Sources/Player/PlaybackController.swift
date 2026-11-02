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

    enum Panel: Equatable { case none, channels, programmes, tracks, transport }

    struct ArchiveSession: Equatable {
        /// Fenêtre d'origine (programme complet), référence des positions.
        var original: ArchiveWindow
        /// Fenêtre effectivement demandée (décalée après un repositionnement par requête).
        var current: ArchiveWindow
        var format: StreamFormat
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
    @ObservationIgnored private let log = DiagnosticsLog.shared
    @ObservationIgnored weak var app: AppModel?

    init() {
        hostView.backgroundColor = .black
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(available: satisfied) }
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
        tune(.live(channel))
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
            ladder = archiveLadder(for: archive.format)
        }
        guard !ladder.isEmpty else {
            fail(.unsupportedFormat)
            return
        }
        recovery = RecoveryPlanner(ladder: ladder)
        statistics.tunes += 1
        start(ladder[0])
    }

    private func archiveLadder(for format: StreamFormat) -> [PlaybackAttempt] {
        let available = EngineFactory.availableKinds
        switch format {
        case .hls:
            // AVPlayer d'abord : repositionnement précis dans une archive HLS.
            return [PlaybackAttempt(engine: .avPlayer, format: .hls), PlaybackAttempt(engine: .aether, format: .hls)]
                .filter { available.contains($0.engine) }
        case .mpegts:
            return available.contains(.aether) ? [PlaybackAttempt(engine: .aether, format: .mpegts)] : []
        }
    }

    private func start(_ attempt: PlaybackAttempt) {
        guard let app, let client = app.client, let target else { return }
        generation += 1
        let gen = generation
        loadTask?.cancel()
        activeAttempt = attempt
        hadFirstFrame = false
        isBuffering = false
        phase = .tuning
        monitor.reset(at: now)
        stableTask?.cancel()

        guard let engine = installEngine(attempt.engine) else {
            handle(.failed(.unsupportedFormat), generation: gen)
            return
        }
        engine.onEvent = { [weak self] event in self?.handle(event, generation: gen) }

        let request: EngineLoadRequest
        switch target {
        case .live(let channel):
            request = EngineLoadRequest(url: client.urls.liveURL(channel: channel, format: attempt.format), format: attempt.format,
                                        mode: .live, userAgent: app.settings.userAgentPreset.value,
                                        matchContent: app.settings.matchContentFrameRate)
        case .archive(let channel, let window, let offset):
            guard let session = app.session, let archive else { return }
            let url = client.urls.timeshiftURL(channel: channel, start: window.requestStart, durationMinutes: window.durationMinutes,
                                               serverTimeZone: session.server.timeZone, style: archive.style, format: attempt.format)
            request = EngineLoadRequest(url: url, format: attempt.format,
                                        mode: .archive(durationSeconds: Double(window.durationMinutes * 60), startOffset: offset),
                                        userAgent: app.settings.userAgentPreset.value,
                                        matchContent: app.settings.matchContentFrameRate)
        }
        log.log(.info, "lecture", "Chargement \(gen) : \(attempt) — \(request.url.absoluteString)")

        loadTask = Task { [weak self] in
            do {
                try await engine.load(request)
            } catch is CancellationError {
                return
            } catch {
                guard let self, gen == self.generation else { return }
                let failure: PlaybackFailure = (error as? EngineError) == .unsupported ? .unsupportedFormat : .unknown("\(error)")
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
                app?.recordWatched(channel)
            }
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
        log.log(.warning, "lecture", "Incident (\(generation)) : \(failure)")
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
        engine?.stop()   // libère la connexion du compte
        phase = .failed(failure.userMessage)
        log.log(.error, "lecture", "Abandon : \(failure)")
    }

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
        } else {
            engine.pause()
            isPaused = true
        }
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
            session.account.allowedFormats.contains(format) && !archiveLadder(for: format).isEmpty
        }
        let resolution = await app.archive.resolve(channel: channel.id, window: window, formats: formats)
        switch resolution {
        case .unavailable(let reason):
            phase = previousPhase == .resolvingArchive ? .idle : previousPhase
            showToast(reason)
            log.log(.warning, "replay", reason)
        case .playable(_, let format, let style):
            archive = ArchiveSession(original: window, current: window, format: format, style: style, baseOffset: 0, channel: channel.id)
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

    var audioTracks: [EngineTrack] { engine?.audioTracks ?? [] }
    func selectAudioTrack(_ id: Int) { engine?.selectAudioTrack(id: id) }
    var technicalSummary: String { engine?.technicalSummary ?? "Aucun moteur actif" }

    func showBanner(duration: TimeInterval = 5) {
        bannerVisible = true
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, !Task.isCancelled, self.panel == .none else { return }
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
