import UIKit
import MinuitCore

/// Ce que l'on demande à un moteur.
struct EngineLoadRequest {
    enum Mode: Equatable {
        case live
        /// Archive : durée déclarée et position de départ dans le flux.
        case archive(durationSeconds: Double, startOffset: Double)
    }

    var url: URL
    var format: StreamFormat
    var mode: Mode
    var userAgent: String
    var matchContent: Bool
}

/// Événements remontés par un moteur. Le contrôleur vérifie systématiquement
/// la génération avant de les traiter.
enum EngineEvent: Equatable {
    case firstFrame
    case playing
    case buffering(Bool)
    case failed(PlaybackFailure)
    /// Le moteur ne peut plus faire vivre la session : un rechargement est nécessaire.
    case sourceReset
    case ended
}

struct EngineTrack: Identifiable, Equatable {
    var id: Int
    var title: String
    var isSelected: Bool
}

/// Interface commune aux moteurs vidéo. Toujours utilisée sur le fil principal.
@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: EngineKind { get }
    /// Vue de rendu, insérée par le contrôleur de lecteur.
    var renderView: UIView { get }
    var onEvent: ((EngineEvent) -> Void)? { get set }
    /// Repositionnement natif dans le flux courant.
    var canSeekInPlace: Bool { get }
    var currentPosition: Double { get }
    var duration: Double? { get }

    func load(_ request: EngineLoadRequest) async throws
    func play()
    func pause()
    func seek(to seconds: Double) async
    func seekToLiveEdge() async
    /// Arrêt complet : coupe la connexion réseau et libère le décodeur.
    func stop()
    func healthSample(at time: TimeInterval, wantsToPlay: Bool) -> HealthSample

    var audioTracks: [EngineTrack] { get }
    func selectAudioTrack(id: Int)
    /// Résumé technique pour l'écran de diagnostic (codec, résolution, HDR…).
    var technicalSummary: String { get }
}

/// Fabrique des moteurs disponibles dans cette compilation.
@MainActor
enum EngineFactory {
    static var availableKinds: Set<EngineKind> {
        #if canImport(AetherEngine)
        return [.aether, .avPlayer]
        #else
        return [.avPlayer]
        #endif
    }

    static func make(_ kind: EngineKind) -> PlaybackEngine? {
        switch kind {
        case .avPlayer:
            return AVPlayerEngine()
        case .aether:
            #if canImport(AetherEngine)
            return try? AetherPlayerEngine()
            #else
            return nil
            #endif
        }
    }
}
