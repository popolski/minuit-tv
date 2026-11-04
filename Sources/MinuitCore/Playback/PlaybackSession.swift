import Foundation

/// Ce que l'utilisateur veut regarder.
public enum PlaybackTarget: Sendable, Hashable {
    case live(ChannelID)
    /// Programme archivé, lu depuis `offset` secondes après son début.
    case archive(ChannelID, ArchiveWindow, offset: TimeInterval)

    public var channel: ChannelID {
        switch self {
        case .live(let id): return id
        case .archive(let id, _, _): return id
        }
    }

    public var isLive: Bool { if case .live = self { return true } else { return false } }
}

/// Jeton de génération : chaque nouveau chargement invalide tous les précédents.
/// Un rappel asynchrone (première image, erreur…) portant un jeton périmé est ignoré,
/// ce qui garantit qu'une chaîne zappée ne peut jamais « revenir » à l'écran.
public struct PlaybackGeneration: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt64
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public var description: String { "#\(value)" }
}

/// Regroupe les appuis rapides de zapping : l'écran affiche immédiatement la chaîne
/// visée, mais un seul chargement est lancé une fois la saisie stabilisée.
public struct ZapAccumulator: Sendable, Equatable {
    public var settleDelay: TimeInterval
    public private(set) var pendingTarget: ChannelID?
    public private(set) var lastInputAt: TimeInterval?

    public init(settleDelay: TimeInterval = 0.35) {
        self.settleDelay = settleDelay
    }

    public mutating func register(target: ChannelID, at time: TimeInterval) {
        pendingTarget = target
        lastInputAt = time
    }

    /// Renvoie la chaîne à charger si la saisie est stable, et vide l'accumulateur.
    public mutating func commitIfSettled(at time: TimeInterval) -> ChannelID? {
        guard let target = pendingTarget, let last = lastInputAt, time - last >= settleDelay else { return nil }
        pendingTarget = nil
        lastInputAt = nil
        return target
    }

    public mutating func cancel() {
        pendingTarget = nil
        lastInputAt = nil
    }
}

/// Retard sur le direct accumulé par les pauses (le tampon local du moteur garde l'image).
/// Plafonné à la taille de ce tampon. Remis à zéro à chaque chargement ou retour au direct.
// ponytail: ne compte que les pauses, pas les arrêts de mise en mémoire tampon ; lire la
// position réelle du moteur dans son tampon si les deux moteurs l'exposent un jour.
public struct LiveDelayClock: Sendable, Equatable {
    public let limit: TimeInterval
    private var accumulated: TimeInterval = 0
    private var pausedAt: Date?

    public init(limit: TimeInterval = 600) {
        self.limit = limit
    }

    public mutating func pause(at date: Date) {
        if pausedAt == nil { pausedAt = date }
    }

    public mutating func resume(at date: Date) {
        accumulated = delay(at: date)
        pausedAt = nil
    }

    public mutating func reset() {
        accumulated = 0
        pausedAt = nil
    }

    public func delay(at date: Date) -> TimeInterval {
        let running = pausedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        return min(limit, accumulated + running)
    }

    /// « −12:36 », ou nil sous une seconde de retard.
    public static func label(_ delay: TimeInterval) -> String? {
        let total = Int(delay)
        guard total >= 1 else { return nil }
        return total >= 3600 ? String(format: "−%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
                             : String(format: "−%d:%02d", total / 60, total % 60)
    }
}

/// Raisons d'échec d'un chargement, indépendantes du moteur.
public enum PlaybackFailure: Sendable, Equatable {
    case network
    case http(Int)
    case connectionLimit
    case unsupportedFormat
    case decoder
    case health(HealthVerdict)
    case sourceEnded
    case archiveUnavailable
    /// Le serveur du flux présente un certificat HTTPS refusé par tvOS.
    case certificateRejected
    /// Le fournisseur renvoie une page web ou un message à la place de la vidéo.
    case providerMessage
    case unknown(String)

    public var userMessage: String {
        switch self {
        case .providerMessage:
            return "Le fournisseur a renvoyé une page d'erreur au lieu de la vidéo. Le problème vient de son côté (abonnement, connexions ou serveur)."
        case .network: return "Connexion au flux interrompue."
        case .http(let code) where code == 404: return "Chaîne indisponible sur le serveur (404)."
        case .http(let code) where code == 401 || code == 403: return "Accès au flux refusé (\(code))."
        case .http(let code): return "Le serveur du flux a répondu \(code)."
        case .connectionLimit: return "Nombre maximal de connexions atteint. Fermez un autre appareil."
        case .unsupportedFormat: return "Format vidéo non pris en charge par l'Apple TV."
        case .decoder: return "Le décodage vidéo a échoué."
        case .health(let verdict):
            switch verdict {
            case .frozenVideo: return "L'image est figée."
            case .audioWithoutVideo: return "Le son est reçu mais pas l'image."
            case .startupTimeout: return "La chaîne ne démarre pas."
            default: return "La lecture est bloquée."
            }
        case .sourceEnded: return "Le flux s'est arrêté."
        case .archiveUnavailable: return "Ce programme n'est pas disponible en replay."
        case .certificateRejected: return "Le serveur de cette chaîne redirige vers une connexion sécurisée dont le certificat est refusé par l'Apple TV."
        case .unknown: return "Lecture impossible."
        }
    }

    /// Précise un abandon à l'aide d'un sondage du flux : les moteurs signalent souvent un
    /// refus HTTP ou une page d'erreur du fournisseur comme un échec générique.
    public func refined(by verdict: ArchiveProbe.Verdict) -> PlaybackFailure {
        switch self {
        case .unknown, .network, .health, .sourceEnded, .decoder: break
        default: return self   // déjà précis
        }
        switch verdict {
        case .providerMessage: return .providerMessage
        case .httpError(456), .httpError(458): return .connectionLimit
        // Pas les autres codes : un serveur peut répondre 416 à l'en-tête Range du sondage.
        case .httpError(let code) where [401, 403, 404].contains(code) || (500...599).contains(code): return .http(code)
        default: return self
        }
    }

    /// Recharger la même combinaison a-t-il une chance d'aider ?
    var isWorthReloading: Bool {
        switch self {
        case .network, .health(.stalled), .health(.frozenVideo), .sourceEnded, .http(500...599): return true
        default: return false
        }
    }

    /// Changer de moteur/format a-t-il une chance d'aider ?
    var isWorthFallingBack: Bool {
        switch self {
        case .connectionLimit, .archiveUnavailable, .http(401), .http(403), .http(404): return false
        default: return true
        }
    }
}

/// Décision de reprise après incident.
public enum RecoveryAction: Sendable, Equatable {
    case reload(after: TimeInterval)
    case fallBack(to: PlaybackAttempt)
    case giveUp(PlaybackFailure)
}

/// Échelle de reprise bornée : quelques rechargements espacés, puis repli moteur,
/// puis abandon explicite. Jamais de boucle infinie sur une chaîne morte.
public struct RecoveryPlanner: Sendable, Equatable {
    public var reloadDelays: [TimeInterval]
    /// Fenêtre glissante au-delà de laquelle le compteur de rechargements est remis à zéro.
    public var budgetWindow: TimeInterval

    private var ladder: [PlaybackAttempt]
    private var ladderIndex = 0
    private var reloadTimestamps: [TimeInterval] = []

    public init(ladder: [PlaybackAttempt], reloadDelays: [TimeInterval] = [1, 3, 6], budgetWindow: TimeInterval = 120) {
        self.ladder = ladder
        self.reloadDelays = reloadDelays
        self.budgetWindow = budgetWindow
    }

    public var currentAttempt: PlaybackAttempt? { ladderIndex < ladder.count ? ladder[ladderIndex] : nil }

    /// Le flux a joué correctement assez longtemps : on oublie les incidents passés.
    public mutating func markStable() {
        reloadTimestamps.removeAll()
    }

    public mutating func next(after failure: PlaybackFailure, hadFirstFrame: Bool, at time: TimeInterval) -> RecoveryAction {
        reloadTimestamps.removeAll { time - $0 > budgetWindow }

        // Un flux qui a déjà affiché des images puis décroche : on recharge d'abord.
        if hadFirstFrame, failure.isWorthReloading, reloadTimestamps.count < reloadDelays.count {
            let delay = reloadDelays[reloadTimestamps.count]
            reloadTimestamps.append(time)
            return .reload(after: delay)
        }
        // Échec au démarrage ou rechargements épuisés : moteur/format suivant.
        if failure.isWorthFallingBack, ladderIndex + 1 < ladder.count {
            ladderIndex += 1
            reloadTimestamps.removeAll()
            return .fallBack(to: ladder[ladderIndex])
        }
        return .giveUp(failure)
    }
}
