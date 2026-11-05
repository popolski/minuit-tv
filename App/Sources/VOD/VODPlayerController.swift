import AVKit
import Foundation
import Observation
import UIKit
import MinuitCore

/// Lecture d'un film ou d'un épisode. Indépendant du lecteur du direct (zapping, santé,
/// rattrapage) : un fichier complet se lit, se repositionne et se reprend.
///
/// - AetherEngine d'abord (MKV, HEVC, HDR, DTS, sous-titres intégrés), AVPlayer en repli
///   pour les MP4/MOV si AetherEngine échoue avant la première image ;
/// - position enregistrée toutes les 15 s, à la pause, à la sortie et en veille ;
/// - audio français choisi d'office, sous-titres français seulement en VO ;
/// - épisode suivant enchaîné après un compte à rebours, annulable.
@MainActor
@Observable
final class VODPlayerController {
    enum Phase: Equatable {
        case loading
        case playing
        case failed(String)
        case ended
    }

    enum Panel: Equatable { case none, tracks }

    private(set) var item: VODPlayItem
    private(set) var phase: Phase = .loading
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = false
    /// Position visée pendant l'avance ou le retour rapide (affichée, appliquée au relâchement).
    private(set) var scrubTarget: Double?
    /// Vitesse de défilement rapide (secondes de vidéo par seconde, signée).
    private(set) var shuttleRate: Double?
    private(set) var cues: [DisplayCue] = []
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []
    /// Secondes avant l'épisode suivant (nil : pas de compte à rebours).
    private(set) var nextCountdown: Int?
    private(set) var toast: String?
    var chromeVisible = true
    var panel: Panel = .none

    @ObservationIgnored let hostView = UIView()
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var engine: PlaybackEngine?
    @ObservationIgnored private var triedEngines: Set<EngineKind> = []
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var shuttleTask: Task<Void, Never>?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var hadFirstFrame = false
    @ObservationIgnored private var tracksConfigured = false
    @ObservationIgnored private var lastRecord = Date.distantPast
    @ObservationIgnored private var lastInteraction = Date()
    @ObservationIgnored private var suspendedAt: Double?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let log = DiagnosticsLog.shared

    init(item: VODPlayItem, app: AppModel) {
        self.item = item
        self.app = app
        hostView.backgroundColor = .black
    }

    var displayedPosition: Double { scrubTarget ?? position }

    /// Heure de fin si la lecture continue sans pause.
    var endTime: Date? {
        guard duration > 0 else { return nil }
        return Date().addingTimeInterval(max(0, duration - displayedPosition))
    }

    var nextItem: VODPlayItem? { item.next }

    /// La surcouche reçoit le focus : panneau, erreur, compte à rebours.
    var needsInteractiveOverlay: Bool {
        if panel != .none || nextCountdown != nil { return true }
        if case .failed = phase { return true }
        return false
    }

    // MARK: Démarrage

    func start() {
        guard !closed else { return }
        app?.activeVOD = self
        UIApplication.shared.isIdleTimerDisabled = true
        triedEngines = []
        load(at: item.startPosition, engine: EngineFactory.availableKinds.contains(.aether) ? .aether : .avPlayer)
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
    }

    private func load(at start: Double, engine kind: EngineKind) {
        guard let app, let urls = app.vod.urls ?? app.client?.urls else {
            phase = .failed("Compte non connecté.")
            return
        }
        generation += 1
        let gen = generation
        loadTask?.cancel()
        triedEngines.insert(kind)
        phase = .loading
        hadFirstFrame = false
        tracksConfigured = false
        isBuffering = false
        isPaused = false
        position = start
        cues = []

        guard let engine = install(kind) else {
            failOrFallBack(.unsupportedFormat, generation: gen)
            return
        }
        engine.onEvent = { [weak self] event in self?.handle(event, generation: gen) }

        let fileURL = DemoMode.isEnabled ? (DemoMode.mediaURL ?? item.url(urls)) : item.url(urls)
        let request = EngineLoadRequest(url: fileURL, format: item.containerExtension == "m3u8" ? .hls : .mpegts,
                                        mode: .vod(startPosition: start), userAgent: app.settings.userAgentPreset.value,
                                        matchContent: app.settings.matchContentFrameRate)
        log.log(.info, "vod", "Lecture \(gen) [\(kind.displayName)] départ \(Int(start)) s — \(fileURL.absoluteString)")
        loadTask = Task { [weak self] in
            do {
                try await engine.load(request)
            } catch is CancellationError {
                return
            } catch {
                guard let self, gen == self.generation else { return }
                self.log.log(.warning, "vod", "Chargement refusé : \(error)")
                self.failOrFallBack((error as? EngineError) == .unsupported ? .unsupportedFormat : .unknown("\(error)"), generation: gen)
            }
        }
    }

    private func install(_ kind: EngineKind) -> PlaybackEngine? {
        if let engine, engine.kind == kind { return engine }
        teardownEngine()
        guard let fresh = EngineFactory.make(kind) else { return nil }
        let view = fresh.renderView
        view.frame = hostView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.addSubview(view)
        engine = fresh
        return fresh
    }

    private func teardownEngine() {
        guard let engine else { return }
        engine.onEvent = nil
        engine.stop()
        engine.renderView.removeFromSuperview()
        self.engine = nil
    }

    // MARK: Événements

    private func handle(_ event: EngineEvent, generation gen: UInt64) {
        guard gen == generation, !closed else { return }
        switch event {
        case .firstFrame:
            hadFirstFrame = true
            phase = .playing
            showChrome()
        case .playing:
            if phase == .loading, hadFirstFrame { phase = .playing }
            isBuffering = false
        case .buffering(let buffering):
            isBuffering = buffering
        case .failed(let failure):
            log.log(.warning, "vod", "Échec : \(failure) — \(engine?.lastErrorDetail ?? "")")
            failOrFallBack(failure, generation: gen)
        case .sourceReset:
            // Propre au direct ; sur un fichier, on reprend simplement à la position courante.
            reload()
        case .ended:
            finish()
        }
    }

    /// Avant la première image : AVPlayer pour les MP4/MOV. Ensuite : message et « Réessayer ».
    private func failOrFallBack(_ failure: PlaybackFailure, generation gen: UInt64) {
        guard gen == generation else { return }
        let avPlayerCanTry = ["mp4", "m4v", "mov", "m3u8"].contains(item.containerExtension)
        if !hadFirstFrame, !triedEngines.contains(.avPlayer), avPlayerCanTry, EngineFactory.availableKinds.contains(.avPlayer) {
            log.log(.info, "vod", "Repli sur AVPlayer")
            load(at: position, engine: .avPlayer)
            return
        }
        recordProgress()
        phase = .failed(failure == .unsupportedFormat && !avPlayerCanTry
                        ? "Ce fichier (\(item.containerExtension.uppercased())) n'a pas pu être lu."
                        : failure.userMessage)
    }

    func retry() {
        triedEngines = []
        load(at: position, engine: EngineFactory.availableKinds.contains(.aether) ? .aether : .avPlayer)
    }

    private func reload() {
        load(at: position, engine: engine?.kind ?? .aether)
    }

    // MARK: Boucle (4 Hz)

    private func tick() {
        guard let engine, !closed else { return }
        if hadFirstFrame, scrubTarget == nil {
            let current = engine.currentPosition
            if current.isFinite, current >= 0 { position = current }
        }
        if let total = engine.duration, total.isFinite, total > 0 { duration = total }
        cues = engine.currentCues()
        if hadFirstFrame {
            audioTracks = engine.audioTracks
            subtitleTracks = engine.subtitleTracks
            if !tracksConfigured, !audioTracks.isEmpty { configureTracks(engine) }
        }
        let now = Date()
        if phase == .playing, !isPaused, now.timeIntervalSince(lastRecord) >= 15 { recordProgress() }
        if chromeVisible, panel == .none, !isPaused, scrubTarget == nil, phase == .playing,
           now.timeIntervalSince(lastInteraction) > 5 {
            chromeVisible = false
        }
    }

    /// Audio français si le fichier en a ; sous-titres français seulement en VO.
    private func configureTracks(_ engine: PlaybackEngine) {
        tracksConfigured = true
        let audio = audioTracks.first(where: \.isSelected)
        if let wanted = TrackChoice.audio(audioTracks), wanted.id != audio?.id, wanted.normalizedLanguage == "fr" {
            engine.selectAudioTrack(id: wanted.id)
        }
        let chosenAudio = TrackChoice.audio(audioTracks)
        if let subtitle = TrackChoice.subtitle(subtitleTracks, audio: chosenAudio), !subtitle.isSelected {
            engine.selectSubtitleTrack(id: subtitle.id)
        }
        log.log(.info, "vod", "Pistes : \(audioTracks.count) audio, \(subtitleTracks.count) sous-titres")
    }

    // MARK: Commandes

    func touch() {
        lastInteraction = Date()
    }

    func showChrome() {
        chromeVisible = true
        touch()
    }

    func togglePlayPause() {
        guard let engine, hadFirstFrame else { return }
        if isPaused {
            engine.play()
            isPaused = false
        } else {
            engine.pause()
            isPaused = true
            recordProgress()
        }
        showChrome()
    }

    func skip(by delta: Double) {
        guard hadFirstFrame else { return }
        seek(to: displayedPosition + delta)
        showToast(delta > 0 ? "+\(Int(delta)) s" : "−\(Int(-delta)) s")
    }

    func seek(to target: Double) {
        guard let engine, hadFirstFrame else { return }
        let clamped = duration > 0 ? min(max(0, target), max(0, duration - 2)) : max(0, target)
        position = clamped
        showChrome()
        Task { await engine.seek(to: clamped) }
    }

    /// Avance ou retour rapide tant que la touche est maintenue, de plus en plus vite.
    func startShuttle(forward: Bool) {
        guard hadFirstFrame, duration > 0, shuttleTask == nil else { return }
        let sign: Double = forward ? 1 : -1
        let started = Date()
        scrubTarget = position
        shuttleRate = 10 * sign
        showChrome()
        shuttleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled, let target = self.scrubTarget else { return }
                let level = min(4, Int(Date().timeIntervalSince(started) / 1.5))
                let rate = 10 * pow(2, Double(level)) * sign
                self.shuttleRate = rate
                self.scrubTarget = min(max(0, target + rate * 0.1), max(0, self.duration - 2))
                self.touch()
            }
        }
    }

    var isShuttling: Bool { shuttleTask != nil }

    func stopShuttle() {
        shuttleTask?.cancel()
        shuttleTask = nil
        shuttleRate = nil
        if let target = scrubTarget {
            scrubTarget = nil
            seek(to: target)
        }
    }

    func selectAudio(_ id: Int) {
        engine?.selectAudioTrack(id: id)
        touch()
    }

    func selectSubtitle(_ id: Int?) {
        engine?.selectSubtitleTrack(id: id)
        touch()
    }

    // MARK: Fin, épisode suivant

    private func finish() {
        guard phase != .ended else { return }
        phase = .ended
        if duration > 0 { position = duration }
        recordProgress()
        guard let next = nextItem else {
            onFinished?()
            return
        }
        app?.vod.queue(next.progressEntry(position: 0, duration: 0))
        nextCountdown = 10
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while let self, let remaining = self.nextCountdown, remaining > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.nextCountdown = remaining - 1
            }
            guard let self, !Task.isCancelled, self.nextCountdown == 0 else { return }
            self.playNext()
        }
    }

    func playNext() {
        countdownTask?.cancel()
        nextCountdown = nil
        guard let next = nextItem else { return }
        recordProgress()
        item = next
        audioTracks = []
        subtitleTracks = []
        duration = 0
        position = 0
        triedEngines = []
        load(at: 0, engine: EngineFactory.availableKinds.contains(.aether) ? .aether : .avPlayer)
    }

    func cancelNext() {
        countdownTask?.cancel()
        nextCountdown = nil
        onFinished?()
    }

    /// Fin sans suite (ou suite refusée) : le lecteur se ferme.
    @ObservationIgnored var onFinished: (() -> Void)?

    // MARK: Progression, veille, fermeture

    private func recordProgress() {
        lastRecord = Date()
        guard hadFirstFrame || phase == .ended, duration > 0, position > 0 || phase == .ended else { return }
        app?.vod.record(item.progressEntry(position: phase == .ended ? duration : position, duration: duration))
    }

    func suspend() {
        guard !closed, engine != nil else { return }
        recordProgress()
        suspendedAt = position
        generation += 1
        loadTask?.cancel()
        teardownEngine()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resume() {
        guard !closed, let start = suspendedAt else { return }
        suspendedAt = nil
        UIApplication.shared.isIdleTimerDisabled = true
        load(at: start, engine: EngineFactory.availableKinds.contains(.aether) ? .aether : .avPlayer)
    }

    func close() {
        guard !closed else { return }
        recordProgress()
        closed = true
        generation += 1
        loadTask?.cancel()
        ticker?.cancel()
        shuttleTask?.cancel()
        countdownTask?.cancel()
        teardownEngine()
        UIApplication.shared.isIdleTimerDisabled = false
        // Rendre à l'écran son mode par défaut (fréquence / HDR).
        hostView.window?.avDisplayManager.preferredDisplayCriteria = nil
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toast = nil
        }
    }
}
