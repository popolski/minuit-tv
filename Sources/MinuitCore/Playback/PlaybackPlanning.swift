import Foundation

/// Moteurs vidéo connus de la logique métier. L'implémentation concrète vit dans
/// l'application tvOS ; le cœur ne fait que planifier.
public enum EngineKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// AetherEngine : démultiplexage FFmpeg, décodage VideoToolbox, rendu AVPlayer.
    case aether
    /// AVPlayer seul (HLS uniquement).
    case avPlayer

    public var displayName: String {
        switch self {
        case .aether: return "AetherEngine"
        case .avPlayer: return "AVPlayer"
        }
    }

    /// Formats que le moteur sait lire en direct.
    public var supportedFormats: Set<StreamFormat> {
        switch self {
        case .aether: return [.mpegts, .hls]
        case .avPlayer: return [.hls]
        }
    }
}

/// Préférence de lecture choisie dans les réglages.
public enum EnginePreference: String, Sendable, Codable, CaseIterable {
    case automatic
    case preferAVPlayerHLS
    case preferAetherTS

    public var displayName: String {
        switch self {
        case .automatic: return "Automatique"
        case .preferAVPlayerHLS: return "AVPlayer (HLS)"
        case .preferAetherTS: return "AetherEngine (MPEG-TS)"
        }
    }
}

/// Une tentative de lecture : un moteur et un format.
public struct PlaybackAttempt: Sendable, Hashable, Codable, CustomStringConvertible {
    public var engine: EngineKind
    public var format: StreamFormat

    public init(engine: EngineKind, format: StreamFormat) {
        self.engine = engine
        self.format = format
    }

    public var description: String { "\(engine.displayName)/\(format.rawValue)" }
}

/// Construit l'échelle de repli moteur × format.
///
/// Principe : on commence par la combinaison la plus robuste pour l'IPTV, puis on
/// bascule vers un moteur **indépendant** avant de réessayer une variante du même
/// moteur. Un succès récent sur une chaîne est retenu et rejoué en premier.
public struct PlaybackPlanner: Sendable {
    public var availableEngines: Set<EngineKind>
    public var preference: EnginePreference

    public init(availableEngines: Set<EngineKind>, preference: EnginePreference) {
        self.availableEngines = availableEngines
        self.preference = preference
    }

    public func ladder(allowedFormats: Set<StreamFormat>, remembered: PlaybackAttempt? = nil) -> [PlaybackAttempt] {
        let formats = allowedFormats.isEmpty ? Set(StreamFormat.allCases) : allowedFormats
        var order: [PlaybackAttempt]
        switch preference {
        case .automatic, .preferAetherTS:
            order = [
                PlaybackAttempt(engine: .aether, format: .mpegts),
                PlaybackAttempt(engine: .avPlayer, format: .hls),
                PlaybackAttempt(engine: .aether, format: .hls),
            ]
        case .preferAVPlayerHLS:
            order = [
                PlaybackAttempt(engine: .avPlayer, format: .hls),
                PlaybackAttempt(engine: .aether, format: .mpegts),
                PlaybackAttempt(engine: .aether, format: .hls),
            ]
        }
        order = order.filter { availableEngines.contains($0.engine) && formats.contains($0.format) && $0.engine.supportedFormats.contains($0.format) }
        if let remembered, let index = order.firstIndex(of: remembered) {
            order.remove(at: index)
            order.insert(remembered, at: 0)
        }
        return order
    }
}

/// Mémoire des combinaisons qui ont fonctionné, par chaîne (LRU borné).
public struct PlaybackMemory: Sendable, Codable, Equatable {
    private var entries: [ChannelID: PlaybackAttempt] = [:]
    private var order: [ChannelID] = []
    public var capacity: Int

    public init(capacity: Int = 200) { self.capacity = capacity }

    public func attempt(for channel: ChannelID) -> PlaybackAttempt? { entries[channel] }

    public mutating func remember(_ attempt: PlaybackAttempt, for channel: ChannelID) {
        entries[channel] = attempt
        order.removeAll { $0 == channel }
        order.append(channel)
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries[evicted] = nil
        }
    }

    public mutating func forget(_ channel: ChannelID) {
        entries[channel] = nil
        order.removeAll { $0 == channel }
    }
}

/// Qualité adaptative entre les versions d'une chaîne (HD, FHD, 4K…) : descend d'un cran
/// quand l'image s'arrête à répétition, remonte vers la version par défaut après une longue
/// période stable. Une version qui a calé est écartée un moment, pour éviter les allers-retours
/// (chaque changement coupe l'image une seconde).
public struct AdaptiveQuality: Sendable, Equatable {
    public var stallWindow: TimeInterval = 300
    public var stallsBeforeStepDown = 3
    public var stableBeforeStepUp: TimeInterval = 900
    public var blockDuration: TimeInterval = 1800

    private var stalls: [TimeInterval] = []
    private var stableSince: TimeInterval?
    private var blockedUntil: [ChannelID: TimeInterval] = [:]

    public init() {}

    /// Nouvelle chaîne (pas une autre version de la même) : on repart de zéro, sauf les versions écartées.
    public mutating func reset() {
        stalls = []
        stableSince = nil
    }

    /// Image affichée (premier chargement ou reprise après un arrêt) : point de départ de la
    /// période stable. Les arrêts récents restent comptés : une reprise ne les efface pas.
    public mutating func notePlaying(at time: TimeInterval) {
        stableSince = time
    }

    /// Arrêt de l'image ; vrai quand il faut descendre d'un cran.
    public mutating func noteStall(at time: TimeInterval) -> Bool {
        stableSince = nil
        stalls = stalls.filter { time - $0 < stallWindow } + [time]
        return stalls.count >= stallsBeforeStepDown
    }

    public mutating func block(_ id: ChannelID, at time: TimeInterval) {
        blockedUntil[id] = time + blockDuration
    }

    public func isBlocked(_ id: ChannelID, at time: TimeInterval) -> Bool {
        (blockedUntil[id] ?? 0) > time
    }

    /// Définition annoncée : 4K > FHD > HD > sans mention > SD.
    public static func resolutionRank(_ channel: Channel) -> Int {
        switch QualityBadge.parse(channel.name) {
        case .uhd: return 4
        case .fhd: return 3
        case .hd: return 2
        case nil: return 1
        case .sd: return 0
        }
    }

    /// Version de définition immédiatement inférieure, non écartée.
    public func stepDown(from current: Channel, among variants: [Channel], at time: TimeInterval) -> Channel? {
        let rank = Self.resolutionRank(current)
        return variants
            .filter { Self.resolutionRank($0) < rank && !isBlocked($0.id, at: time) }
            .max { Self.resolutionRank($0) < Self.resolutionRank($1) }
    }

    /// Retour à la version par défaut (première de `variants`) quand elle est meilleure,
    /// non écartée, et que la version actuelle tient depuis assez longtemps.
    public func stepUp(from current: Channel, among variants: [Channel], at time: TimeInterval) -> Channel? {
        guard let stableSince, time - stableSince >= stableBeforeStepUp, let preferred = variants.first,
              preferred.id != current.id, Self.resolutionRank(preferred) > Self.resolutionRank(current),
              !isBlocked(preferred.id, at: time) else { return nil }
        return preferred
    }
}
