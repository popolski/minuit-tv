#if canImport(AetherEngine)
import AetherEngine
import AVFoundation
import Combine
import UIKit
import MinuitCore

/// Moteur AetherEngine : démultiplexage FFmpeg (MPEG-TS brut, HLS), décodage
/// VideoToolbox, rendu par AVPlayer quand c'est possible (HDR, Dolby Vision, Atmos,
/// correspondance de contenu), désentrelacement GPU pour les flux 1080i.
///
/// Contrats d'intégration respectés (cf. Examples/LiveHost d'AetherEngine) :
/// 1. `liveSourceReset` est écouté et remonté au contrôleur, qui recharge de façon bornée ;
/// 2. une `CancellationError` sortant de `load` n'est pas un échec (zapping) ;
/// 3. la première image est `hasFirstFrameReadyForDisplay`, jamais `state == .playing`.
@MainActor
final class AetherPlayerEngine: PlaybackEngine {
    let kind: EngineKind = .aether
    private let engine: AetherEngine
    private let surface = AetherPlayerView(frame: .zero)
    var renderView: UIView { surface }
    var onEvent: ((EngineEvent) -> Void)?
    private(set) var lastErrorDetail: String?

    private var cancellables: Set<AnyCancellable> = []
    private var mode: EngineLoadRequest.Mode = .live
    private var firstFrameReported = false

    init() throws {
        engine = try AetherEngine()
        engine.bind(view: surface)
        surface.backgroundColor = .black
        subscribe()
    }

    private func subscribe() {
        engine.$hasFirstFrameReadyForDisplay
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self, ready, !self.firstFrameReported else { return }
                self.firstFrameReported = true
                self.onEvent?(.firstFrame)
            }
            .store(in: &cancellables)

        engine.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                guard let self else { return }
                switch phase {
                case .playing: self.onEvent?(.buffering(false)); self.onEvent?(.playing)
                case .rebuffering, .stalled: self.onEvent?(.buffering(true))
                case .ended: self.onEvent?(.ended)
                default: break
                }
            }
            .store(in: &cancellables)

        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, case .error(let message) = state else { return }
                let info = self.engine.errorInfo
                var parts = ["AetherEngine", "route \(self.engine.videoRoute.rawValue)"]
                if let info {
                    parts.append(info.kind.rawValue)
                    if let domain = info.underlyingDomain { parts.append("\(domain) \(info.underlyingCode.map(String.init) ?? "")") }
                }
                parts.append(String(message.prefix(160)))
                self.lastErrorDetail = parts.joined(separator: " · ")
                self.onEvent?(.failed(Self.classify(info)))
            }
            .store(in: &cancellables)

        engine.liveSourceReset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onEvent?(.sourceReset) }
            .store(in: &cancellables)
    }

    static func classify(_ info: PlaybackErrorInfo?) -> PlaybackFailure {
        guard let info else { return .unknown("aether") }
        switch info.kind {
        case .sourceCertificateRejected: return .certificateRejected
        case .sourceRateLimited: return .connectionLimit
        case .sourceRefused:
            if let code = info.underlyingCode, (400...599).contains(code) { return .http(code) }
            return .http(403)
        case .sourceOpenFailed, .liveSourceUnavailable, .hlsIngestFailed, .reloadFailed, .liveReloadNeverReady:
            return .network
        case .hlsFormatUnsupported, .demuxedAudioLiveUnsupported, .noPlayableTrackWithinBudget, .masterPlaylistRejected:
            return .unsupportedFormat
        case .softwarePipelineFailed, .dolbyVisionRequiresHardware, .nativeItemFailed:
            return .decoder
        default:
            return .unknown(info.kind.rawValue)
        }
    }

    var canSeekInPlace: Bool {
        // Archives Xtream : origine séquentielle, le repositionnement se fait par nouvelle requête.
        if case .archive = mode { return false }
        return engine.clock.seekableLiveRange != nil
    }

    var currentPosition: Double { engine.clock.currentTime }
    var duration: Double? { engine.duration > 0 ? engine.duration : nil }

    func load(_ request: EngineLoadRequest) async throws {
        lastErrorDetail = nil
        mode = request.mode
        firstFrameReported = false
        let headers = ["User-Agent": request.userAgent]
        let options: LoadOptions
        var start: Double?
        switch request.mode {
        case .live:
            options = LoadOptions(
                httpHeaders: headers,
                matchContentEnabled: request.matchContent,
                isLive: true,
                // Petit tampon local : pause du direct et retour arrière de quelques minutes
                // sans seconde connexion au serveur (comptes souvent limités à 1 connexion).
                dvrWindowSeconds: 600,
                liveJoinProfile: .fastZap,
                nativeRemoteHLS: request.format == .hls
            )
        case .archive(let durationSeconds, let startOffset):
            options = LoadOptions(
                httpHeaders: headers,
                matchContentEnabled: request.matchContent,
                // Les archives Xtream simulent souvent les réponses Range : lecture séquentielle seule.
                sequentialOrigin: request.format == .mpegts,
                declaredDurationSeconds: durationSeconds
            )
            start = request.format == .hls && startOffset > 0 ? startOffset : nil
        }
        do {
            try await engine.load(url: request.url, startPosition: start, options: options)
        } catch is CancellationError {
            // Remplacé par un chargement plus récent : pas un échec.
            throw CancellationError()
        }
    }

    var isMuted: Bool {
        get { engine.volume == 0 }
        set { engine.volume = newValue ? 0 : 1 }
    }

    var fillsScreen: Bool {
        get { engine.videoGravity == .resizeAspectFill }
        set { engine.videoGravity = newValue ? .resizeAspectFill : .resizeAspect }
    }

    func play() { engine.play() }
    func pause() { engine.pause() }

    func seek(to seconds: Double) async { await engine.seek(to: seconds) }
    func seekToLiveEdge() async { await engine.seekToLiveEdge() }

    func stop() {
        engine.stop()
        firstFrameReported = false
    }

    func healthSample(at time: TimeInterval, wantsToPlay: Bool) -> HealthSample {
        let phase = engine.playbackPhase
        let buffering: Bool
        switch phase {
        case .rebuffering, .stalled, .loading: buffering = true
        default: buffering = false
        }
        // Signal vidéo indépendant de l'horloge : cadence de la piste vidéo de l'AVPlayerItem
        // lorsque le rendu passe par AVPlayer. Sur le chemin logiciel, pas de signal fiable :
        // la détection d'image figée repose alors sur la première image et l'horloge (limite connue).
        let videoTrack = engine.currentAVPlayerItem?.tracks.first { $0.assetTrack?.mediaType == .video }
        let hasAudio: Bool?
        switch engine.audioDelivery {
        case .none: hasAudio = nil
        case .noAudioInSource, .droppedNoPipeline: hasAudio = false
        default: hasAudio = true
        }
        return HealthSample(
            at: time,
            wantsToPlay: wantsToPlay,
            clockPosition: engine.clock.currentTime,
            isBuffering: buffering,
            firstFrameShown: engine.hasFirstFrameReadyForDisplay,
            videoFrameRate: videoTrack.map { Double($0.currentVideoFrameRate) },
            lastVideoFrameTime: nil,
            hasVideoTrack: nil,
            hasAudio: hasAudio
        )
    }

    var audioTracks: [EngineTrack] {
        engine.audioTracks.map { track in
            let language = track.language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 } ?? ""
            let channels = track.channels >= 6 ? " · \(track.channels == 8 ? "7.1" : "5.1")" : ""
            let title = [language, track.codec.uppercased()].filter { !$0.isEmpty }.joined(separator: " · ") + channels
            return EngineTrack(id: track.id, title: title.isEmpty ? track.name : title, isSelected: false)
        }
    }

    func selectAudioTrack(id: Int) { engine.selectAudioTrack(index: id) }

    var technicalSummary: String {
        let format: String
        switch engine.videoFormat {
        case .sdr: format = "SDR"
        case .hdr10: format = "HDR10"
        case .hdr10Plus: format = "HDR10+"
        case .dolbyVision: format = "Dolby Vision"
        case .hlg: format = "HLG"
        }
        return "AetherEngine · \(engine.videoRoute) · \(format) · audio : \(engine.audioDelivery.rawValue)"
    }
}
#endif
