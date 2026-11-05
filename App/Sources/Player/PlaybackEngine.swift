import UIKit
import MinuitCore

/// Ce que l'on demande à un moteur.
struct EngineLoadRequest {
    enum Mode: Equatable {
        case live
        /// Archive : durée déclarée et position de départ dans le flux.
        case archive(durationSeconds: Double, startOffset: Double)
        /// Film ou épisode : fichier complet, repositionnable, départ éventuel (reprise).
        case vod(startPosition: Double)

        var isVOD: Bool { if case .vod = self { return true } else { return false } }
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

typealias EngineTrack = MediaTrack

/// Sous-titre prêt à dessiner (moteurs qui ne les affichent pas eux-mêmes).
struct DisplayCue: Identifiable {
    enum Body {
        case text(String, italic: Bool)
        /// Image (PGS, DVB…) et sa position dans le canevas source.
        case image(CGImage, rect: CGRect, canvas: CGSize)
    }

    let id: Int
    let body: Body
    /// Ancré en haut de l'image (alignements ASS 7/8/9).
    let top: Bool
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

    /// Détail technique de la dernière erreur (domaine, code, statut HTTP…), pour le diagnostic.
    var lastErrorDetail: String? { get }

    /// Son coupé (aperçu de l'écran Direct).
    var isMuted: Bool { get set }

    /// Recadrage plein écran (aspect fill) plutôt qu'ajustement (aspect fit).
    var fillsScreen: Bool { get set }

    var audioTracks: [EngineTrack] { get }
    func selectAudioTrack(id: Int)
    var subtitleTracks: [EngineTrack] { get }
    /// nil : sous-titres désactivés.
    func selectSubtitleTrack(id: Int?)
    /// Sous-titres à afficher maintenant (vide si le moteur les dessine lui-même).
    func currentCues() -> [DisplayCue]
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

    /// Politique de certificats d'AetherEngine (ses propres connexions, y compris le relais
    /// qu'il place devant AVPlayer quand le système refuse une origine).
    static func applyCertificatePolicy(acceptInvalid: Bool) {
        #if canImport(AetherEngine)
        AetherPlayerEngine.applyCertificatePolicy(acceptInvalid: acceptInvalid)
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
