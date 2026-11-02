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
