import Foundation

/// Échantillon d'état du lecteur, relevé périodiquement (≈ 2 Hz) par l'application.
///
/// Les signaux sont volontairement redondants : une horloge de lecture qui avance
/// ne prouve **pas** qu'une image est affichée. On exige un signal propre à la vidéo
/// (première image prête, cadence vidéo mesurée, horodatage de la dernière image).
public struct HealthSample: Sendable, Equatable {
    /// Temps monotone de l'échantillon (secondes).
    public var at: TimeInterval
    /// L'utilisateur veut que ça joue (pas en pause).
    public var wantsToPlay: Bool
    /// Position de l'horloge de lecture (secondes), si connue.
    public var clockPosition: Double?
    /// Le moteur signale une mise en mémoire tampon.
    public var isBuffering: Bool
    /// Le moteur a affiché une première image pour ce chargement.
    public var firstFrameShown: Bool
    /// Cadence vidéo mesurée par le moteur (images/s), si disponible.
    public var videoFrameRate: Double?
    /// Horodatage (PTS) de la dernière image affichée, si disponible.
    public var lastVideoFrameTime: Double?
    /// Le flux contient une piste vidéo (nil : inconnu).
    public var hasVideoTrack: Bool?
    /// Le flux contient une piste audio active (nil : inconnu).
    public var hasAudio: Bool?

    public init(at: TimeInterval, wantsToPlay: Bool = true, clockPosition: Double? = nil, isBuffering: Bool = false,
                firstFrameShown: Bool = false, videoFrameRate: Double? = nil, lastVideoFrameTime: Double? = nil,
                hasVideoTrack: Bool? = nil, hasAudio: Bool? = nil) {
        self.at = at
        self.wantsToPlay = wantsToPlay
        self.clockPosition = clockPosition
        self.isBuffering = isBuffering
        self.firstFrameShown = firstFrameShown
        self.videoFrameRate = videoFrameRate
        self.lastVideoFrameTime = lastVideoFrameTime
        self.hasVideoTrack = hasVideoTrack
        self.hasAudio = hasAudio
    }
}

public enum HealthVerdict: Sendable, Equatable {
    case starting
    case healthy
    case paused
    case buffering(since: TimeInterval)
    /// Rien n'avance depuis trop longtemps.
    case stalled
    /// L'horloge (et souvent le son) avance, mais plus aucune image nouvelle.
    case frozenVideo
    /// Le son joue mais le flux n'expose aucune image (piste vidéo absente ou non décodable).
    case audioWithoutVideo
    /// Aucune première image dans le délai imparti.
    case startupTimeout

    public var needsRecovery: Bool {
        switch self {
        case .stalled, .frozenVideo, .audioWithoutVideo, .startupTimeout: return true
        case .starting, .healthy, .paused, .buffering: return false
        }
    }
}

/// Seuils de détection, ajustables depuis les réglages de diagnostic.
public struct HealthThresholds: Sendable, Equatable {
    public var startupTimeout: TimeInterval = 15
    public var stallTimeout: TimeInterval = 8
    public var bufferingTimeout: TimeInterval = 15
    public var frozenVideoTimeout: TimeInterval = 4
    public var audioOnlyGrace: TimeInterval = 6

    public init() {}
}

/// Machine d'évaluation de la santé de lecture. Pure et déterministe : testée
/// sans lecteur réel en lui fournissant des séquences d'échantillons.
public struct PlaybackHealthMonitor: Sendable {
    public var thresholds: HealthThresholds
    private var loadStartedAt: TimeInterval?
    private var lastClock: Double?
    private var lastClockProgressAt: TimeInterval?
    private var lastFrameTime: Double?
    private var lastFrameProgressAt: TimeInterval?
    private var bufferingSince: TimeInterval?
    private var firstFrameAt: TimeInterval?
    private var audioOnlySince: TimeInterval?

    public init(thresholds: HealthThresholds = HealthThresholds()) {
        self.thresholds = thresholds
    }

    /// À appeler à chaque nouveau chargement (zapping, reprise).
    public mutating func reset(at time: TimeInterval) {
        self = PlaybackHealthMonitor(thresholds: thresholds)
        loadStartedAt = time
    }

    public mutating func evaluate(_ sample: HealthSample) -> HealthVerdict {
        let now = sample.at
        if loadStartedAt == nil { loadStartedAt = now }

        // Progression de l'horloge.
        if let clock = sample.clockPosition {
            if let last = lastClock, clock > last + 0.05 { lastClockProgressAt = now }
            else if lastClock == nil { lastClockProgressAt = now }
            lastClock = clock
        }
        // Progression vidéo : PTS de la dernière image, sinon cadence mesurée.
        var videoProgressing = false
        if let frameTime = sample.lastVideoFrameTime {
            if let last = lastFrameTime, frameTime != last { videoProgressing = true }
            lastFrameTime = frameTime
        } else if let rate = sample.videoFrameRate {
            videoProgressing = rate > 0.5
        }
        if videoProgressing { lastFrameProgressAt = now }

        if sample.firstFrameShown, firstFrameAt == nil {
            firstFrameAt = now
            lastFrameProgressAt = lastFrameProgressAt ?? now
        }

        guard sample.wantsToPlay else {
            bufferingSince = nil
            // En pause, on ne juge pas ; on évite un faux « figé » à la reprise.
            lastClockProgressAt = now
            lastFrameProgressAt = now
            return .paused
        }

        if sample.isBuffering {
            if bufferingSince == nil { bufferingSince = now }
        } else {
            bufferingSince = nil
        }

        // Démarrage : aucune image encore.
        guard let firstFrameAt else {
            // Son sans image : le flux annonce de l'audio mais aucune piste vidéo.
            if sample.hasVideoTrack == false, sample.hasAudio == true, let clock = lastClockProgressAt, now - clock < 1.5 {
                if audioOnlySince == nil { audioOnlySince = now }
                if now - (audioOnlySince ?? now) >= thresholds.audioOnlyGrace { return .audioWithoutVideo }
            }
            if let start = loadStartedAt, now - start >= thresholds.startupTimeout { return .startupTimeout }
            return .starting
        }

        if let since = bufferingSince {
            return now - since >= thresholds.bufferingTimeout ? .stalled : .buffering(since: since)
        }

        let clockAdvancing = lastClockProgressAt.map { now - $0 < 1.5 } ?? false
        if !clockAdvancing, let last = lastClockProgressAt ?? Optional(firstFrameAt), now - last >= thresholds.stallTimeout {
            return .stalled
        }
        // Horloge qui avance mais image figée : le cas que l'horloge seule ne détecte pas.
        let hasVideoSignal = sample.lastVideoFrameTime != nil || sample.videoFrameRate != nil
        if clockAdvancing, hasVideoSignal, let lastFrame = lastFrameProgressAt, now - lastFrame >= thresholds.frozenVideoTimeout {
            return .frozenVideo
        }
        return .healthy
    }

    /// Délai de démarrage mesuré (pour les diagnostics).
    public var timeToFirstFrame: TimeInterval? {
        guard let start = loadStartedAt, let first = firstFrameAt else { return nil }
        return first - start
    }
}
