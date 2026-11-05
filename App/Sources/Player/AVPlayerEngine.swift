import AVFoundation
import AVKit
import UIKit
import MinuitCore

/// Vue dont la couche est un AVPlayerLayer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non pris en charge") }
}

/// Moteur AVPlayer : HLS uniquement (AVPlayer ne lit pas un MPEG-TS brut progressif).
/// Atouts : intégration système maximale (HDR, Dolby Vision, Atmos, correspondance
/// de fréquence), aucune dépendance.
@MainActor
final class AVPlayerEngine: NSObject, PlaybackEngine {
    let kind: EngineKind = .avPlayer
    private let view = PlayerLayerView()
    var renderView: UIView { view }
    var onEvent: ((EngineEvent) -> Void)?

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var mode: EngineLoadRequest.Mode = .live
    private var firstFrameReported = false
    private var matchContent = true

    var canSeekInPlace: Bool {
        if case .archive = mode { return true }
        if mode.isVOD { return true }
        return !(item?.seekableTimeRanges.isEmpty ?? true)
    }

    var currentPosition: Double {
        guard let item else { return 0 }
        let seconds = item.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: Double? {
        guard let seconds = item?.duration.seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    func load(_ request: EngineLoadRequest) async throws {
        stop()
        lastErrorDetail = nil
        // Direct et archives : HLS seulement. Films et épisodes : fichiers MP4/MOV progressifs aussi.
        guard request.format == .hls || request.mode.isVOD else { throw EngineError.unsupported }
        mode = request.mode
        matchContent = request.matchContent
        firstFrameReported = false

        let asset = AVURLAsset(url: request.url, options: [AVURLAssetHTTPUserAgentKey: request.userAgent])
        let item = AVPlayerItem(asset: asset)
        // Direct : laisser AVPlayer gérer le tampon ; démarrage au plus près du direct.
        item.preferredForwardBufferDuration = 0
        if case .live = request.mode {
            item.automaticallyPreservesTimeOffsetFromLive = true
        }
        let player = AVPlayer(playerItem: nil)
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = isMuted
        player.appliesMediaSelectionCriteriaAutomatically = true
        self.player = player
        self.item = item
        observe(player: player, item: item)

        view.playerLayer.player = player
        player.replaceCurrentItem(with: item)

        if case .archive(_, let start) = request.mode, start > 0 {
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        if case .vod(let start) = request.mode, start > 0 {
            await player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
        player.play()
    }

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.itemStatusChanged(item) }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing: self.onEvent?(.buffering(false)); self.onEvent?(.playing)
                case .waitingToPlayAtSpecifiedRate: self.onEvent?(.buffering(true))
                case .paused: break
                @unknown default: break
                }
            }
        })
        // Première image réellement prête à l'affichage (et non simple « prêt à lire »).
        observations.append(view.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            Task { @MainActor in
                guard let self, layer.isReadyForDisplay, !self.firstFrameReported else { return }
                self.firstFrameReported = true
                self.onEvent?(.firstFrame)
            }
        })
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            MainActor.assumeIsolated { self?.report(error: error) }
        })
        notificationTokens.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent?(.ended) }
        })
    }

    private func itemStatusChanged(_ item: AVPlayerItem) {
        guard item === self.item else { return }
        if item.status == .failed { report(error: item.error as NSError?) }
        if item.status == .readyToPlay {
            applyDisplayCriteria(for: item)
            loadSelectionGroups(for: item)
        }
    }

    /// Correspondance fréquence d'images / plage dynamique (réglage « Faire correspondre le contenu »).
    /// Limite connue : sur le chemin AVPlayer, les critères ne sont connus qu'une fois l'item prêt ;
    /// une variante HDR peut donc être refusée par tvOS si l'écran n'est pas déjà en HDR. AetherEngine,
    /// moteur principal, applique les critères avant l'attribution de l'item.
    private func applyDisplayCriteria(for item: AVPlayerItem) {
        guard matchContent, let manager = view.window?.avDisplayManager, manager.isDisplayCriteriaMatchingEnabled else { return }
        let asset = item.asset
        Task { [weak self] in
            let criteria = try? await asset.load(.preferredDisplayCriteria)
            guard let self, item === self.item else { return }
            manager.preferredDisplayCriteria = criteria
        }
    }

    /// Groupes des pistes audio et de sous-titres, chargés une fois l'item prêt.
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?

    private func loadSelectionGroups(for item: AVPlayerItem) {
        let asset = item.asset
        Task { [weak self] in
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, item === self.item else { return }
            self.audibleGroup = audible
            self.legibleGroup = legible
        }
    }

    private(set) var lastErrorDetail: String?

    private func report(error: NSError?) {
        let event = item?.errorLog()?.events.last
        var parts = ["AVPlayer"]
        if let error { parts.append("\(error.domain) \(error.code)") }
        if let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append("sous-jacent \(underlying.domain) \(underlying.code)") }
        if let event { parts.append("journal \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "")") }
        lastErrorDetail = parts.joined(separator: " · ")
        onEvent?(.failed(Self.classify(error, errorLog: item?.errorLog())))
    }

    static func classify(_ error: NSError?, errorLog: AVPlayerItemErrorLog?) -> PlaybackFailure {
        if let status = errorLog?.events.last?.errorStatusCode, (400...599).contains(status) {
            return status == 458 || status == 456 ? .connectionLimit : .http(status)
        }
        guard let error else { return .unknown("item failed") }
        if error.domain == NSURLErrorDomain {
            return (-1206 ... -1200).contains(error.code) ? .certificateRejected : .network
        }
        if error.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: error.code) {
            case .fileFormatNotRecognized, .decoderNotFound, .formatUnsupported, .contentIsUnavailable, .failedToParse:
                return .unsupportedFormat
            case .decodeFailed, .decoderTemporarilyUnavailable:
                return .decoder
            case .mediaServicesWereReset:
                return .decoder
            default:
                break
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain {
            return .network
        }
        return .unknown("\(error.domain) \(error.code)")
    }

    var isMuted = false {
        didSet { player?.isMuted = isMuted }
    }

    var fillsScreen: Bool {
        get { view.playerLayer.videoGravity == .resizeAspectFill }
        set { view.playerLayer.videoGravity = newValue ? .resizeAspectFill : .resizeAspect }
    }

    func play() { player?.play() }
    func pause() { player?.pause() }

    func seek(to seconds: Double) async {
        guard let player else { return }
        await player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                          toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                          toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
    }

    func seekToLiveEdge() async {
        guard let player, let range = item?.seekableTimeRanges.last?.timeRangeValue else { return }
        await player.seek(to: range.end, toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
        player.play()
    }

    func stop() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        view.playerLayer.player = nil
        item?.asset.cancelLoading()
        player = nil
        item = nil
        audibleGroup = nil
        legibleGroup = nil
    }

    func healthSample(at time: TimeInterval, wantsToPlay: Bool) -> HealthSample {
        guard let item, let player else { return HealthSample(at: time, wantsToPlay: wantsToPlay) }
        let videoTrack = item.tracks.first { $0.assetTrack?.mediaType == .video }
        let audioTrack = item.tracks.first { $0.assetTrack?.mediaType == .audio && $0.isEnabled }
        let tracksKnown = item.status == .readyToPlay && !item.tracks.isEmpty
        let position = item.currentTime().seconds
        return HealthSample(
            at: time,
            wantsToPlay: wantsToPlay,
            clockPosition: position.isFinite ? position : nil,
            isBuffering: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            firstFrameShown: view.playerLayer.isReadyForDisplay,
            // Cadence réellement affichée : tombe à 0 si l'image se fige alors que l'horloge avance.
            videoFrameRate: videoTrack.map { Double($0.currentVideoFrameRate) },
            lastVideoFrameTime: nil,
            hasVideoTrack: tracksKnown ? (videoTrack != nil || item.presentationSize != .zero) : nil,
            hasAudio: tracksKnown ? (audioTrack != nil) : nil
        )
    }

    var audioTracks: [EngineTrack] {
        guard let item, let group = audibleGroup else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            EngineTrack(id: index, title: option.displayName, isSelected: option == selected,
                        language: option.extendedLanguageTag ?? option.locale?.identifier)
        }
    }

    func selectAudioTrack(id: Int) {
        guard let item, let group = audibleGroup, group.options.indices.contains(id) else { return }
        item.select(group.options[id], in: group)
    }

    var subtitleTracks: [EngineTrack] {
        guard let item, let group = legibleGroup else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            EngineTrack(id: index, title: option.displayName, isSelected: option == selected,
                        language: option.extendedLanguageTag ?? option.locale?.identifier,
                        isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        }
    }

    func selectSubtitleTrack(id: Int?) {
        guard let item, let group = legibleGroup else { return }
        if let id, group.options.indices.contains(id) { item.select(group.options[id], in: group) } else { item.select(nil, in: group) }
    }

    /// AVPlayer dessine lui-même ses sous-titres.
    func currentCues() -> [DisplayCue] { [] }

    var technicalSummary: String {
        guard let item else { return "AVPlayer : inactif" }
        let size = item.presentationSize
        let event = item.accessLog()?.events.last
        let bitrate = event.map { String(format: "%.1f Mb/s", $0.indicatedBitrate / 1_000_000) } ?? "?"
        let dropped = event?.numberOfDroppedVideoFrames ?? 0
        return "AVPlayer · HLS · \(Int(size.width))×\(Int(size.height)) · \(bitrate) · images perdues : \(dropped)"
    }
}

enum EngineError: Error {
    case unsupported
    case unavailable
}
