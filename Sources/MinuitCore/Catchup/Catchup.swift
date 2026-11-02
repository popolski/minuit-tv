import Foundation

/// Fenêtre d'archive à demander au serveur.
public struct ArchiveWindow: Sendable, Hashable, Codable {
    /// Début demandé (programme.start - marge avant), arrondi à la minute inférieure :
    /// les URL de timeshift Xtream ont une précision d'une minute.
    public var requestStart: Date
    public var durationMinutes: Int
    /// Début réel du programme, pour positionner la lecture et l'interface.
    public var programmeStart: Date
    public var programmeEnd: Date
    public var title: String
    /// Programme encore en cours (« Reprendre au début »).
    public var isStartOver: Bool

    public init(requestStart: Date, durationMinutes: Int, programmeStart: Date, programmeEnd: Date, title: String, isStartOver: Bool) {
        self.requestStart = requestStart
        self.durationMinutes = durationMinutes
        self.programmeStart = programmeStart
        self.programmeEnd = programmeEnd
        self.title = title
        self.isStartOver = isStartOver
    }

    /// Décalage, dans le flux d'archive, du début réel du programme.
    public var programmeOffset: TimeInterval { programmeStart.timeIntervalSince(requestStart) }
    public var requestEnd: Date { requestStart.addingTimeInterval(TimeInterval(durationMinutes * 60)) }

    /// Fenêtre décalée pour reprendre à `offset` secondes du début du flux (repositionnement par nouvelle requête).
    public func shifted(toStreamOffset offset: TimeInterval) -> (window: ArchiveWindow, residual: TimeInterval) {
        let clamped = max(0, min(offset, TimeInterval(durationMinutes * 60) - 60))
        let wholeMinutes = Int(clamped / 60)
        var copy = self
        copy.requestStart = requestStart.addingTimeInterval(TimeInterval(wholeMinutes * 60))
        copy.durationMinutes = max(1, durationMinutes - wholeMinutes)
        return (copy, clamped - TimeInterval(wholeMinutes * 60))
    }
}

/// Disponibilité du rattrapage pour un programme donné.
public enum CatchupAvailability: Sendable, Equatable {
    /// La chaîne n'annonce pas d'archive.
    case channelHasNoArchive
    /// Le programme n'a pas encore commencé.
    case upcoming
    /// Programme en cours : « Reprendre au début » possible (à confirmer par sondage).
    case startOver(ArchiveWindow)
    /// Programme terminé et dans la fenêtre d'archive annoncée.
    case available(ArchiveWindow, expiresAt: Date)
    /// Programme trop ancien pour l'archive annoncée.
    case expired
    /// Le fournisseur indique explicitement l'absence d'archive pour ce programme.
    case notArchivedByProvider

    public var window: ArchiveWindow? {
        switch self {
        case .startOver(let w), .available(let w, _): return w
        default: return nil
        }
    }

    public var userLabel: String {
        switch self {
        case .channelHasNoArchive: return "Pas de replay sur cette chaîne"
        case .upcoming: return "À venir"
        case .startOver: return "Reprendre au début"
        case .available: return "Disponible en replay"
        case .expired: return "Replay expiré"
        case .notArchivedByProvider: return "Non archivé par le fournisseur"
        }
    }
}

public struct CatchupSettings: Sendable, Codable, Equatable {
    /// Marge avant le début annoncé (les horaires EPG sont souvent approximatifs).
    public var paddingBefore: TimeInterval = 120
    /// Marge après la fin annoncée.
    public var paddingAfter: TimeInterval = 300
    /// Style d'URL de timeshift confirmé pour ce serveur (nil : à déterminer).
    public var confirmedStyle: XtreamURLBuilder.TimeshiftStyle?

    public init() {}
}

public enum CatchupEvaluator {
    /// Évalue la disponibilité **annoncée**. Le résultat doit encore être confirmé
    /// par un sondage réel (`ArchiveProbe`) avant d'afficher le replay comme lisible.
    public static func evaluate(programme: Programme, channel: Channel, now: Date,
                                settings: CatchupSettings = CatchupSettings()) -> CatchupAvailability {
        guard let archive = channel.archive, archive.days > 0 else { return .channelHasNoArchive }
        if programme.start > now { return .upcoming }
        if programme.archiveFlag == false && programme.end <= now { return .notArchivedByProvider }

        let oldestAvailable = now.addingTimeInterval(-archive.window)
        if programme.start < oldestAvailable { return .expired }

        let paddedStart = max(oldestAvailable, programme.start.addingTimeInterval(-settings.paddingBefore))
        let requestStart = floorToMinute(paddedStart)

        if programme.end > now {
            // En cours : on demande jusqu'à la fin prévue ; le serveur sert ce qui est enregistré.
            let end = programme.end.addingTimeInterval(settings.paddingAfter)
            let minutes = max(1, Int((end.timeIntervalSince(requestStart) / 60).rounded(.up)))
            return .startOver(ArchiveWindow(requestStart: requestStart, durationMinutes: minutes,
                                            programmeStart: programme.start, programmeEnd: programme.end,
                                            title: programme.title, isStartOver: true))
        }
        // Terminé : la marge après ne doit pas dépasser « maintenant ».
        let end = min(now, programme.end.addingTimeInterval(settings.paddingAfter))
        let minutes = max(1, Int((end.timeIntervalSince(requestStart) / 60).rounded(.up)))
        let expiresAt = programme.start.addingTimeInterval(archive.window)
        return .available(ArchiveWindow(requestStart: requestStart, durationMinutes: minutes,
                                        programmeStart: programme.start, programmeEnd: programme.end,
                                        title: programme.title, isStartOver: false),
                          expiresAt: expiresAt)
    }

    static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }
}

/// Classification du début de réponse d'une URL de flux, pour distinguer
/// une archive réellement lisible d'une archive seulement annoncée.
public enum ArchiveProbe {
    public enum Verdict: Sendable, Equatable {
        case playable(StreamFormat)
        /// Le serveur répond, mais pas avec un flux vidéo (page d'erreur, JSON, vide).
        case notMedia(hint: String)
        case httpError(Int)
        case empty
    }

    public static let probeByteCount = 4096

    public static func classify(statusCode: Int, contentType: String?, body: Data) -> Verdict {
        guard (200..<300).contains(statusCode) else { return .httpError(statusCode) }
        guard !body.isEmpty else { return .empty }
        let bytes = [UInt8](body.prefix(probeByteCount))

        if isMPEGTS(bytes) { return .playable(.mpegts) }
        if let text = String(bytes: bytes.prefix(512), encoding: .utf8) ?? String(bytes: bytes.prefix(512), encoding: .isoLatin1) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#EXTM3U") {
                // Une playlist sans segment est un refus déguisé.
                return trimmed.contains("#EXTINF") || trimmed.contains("#EXT-X-STREAM-INF") ? .playable(.hls) : .notMedia(hint: "playlist vide")
            }
            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("<") { return .notMedia(hint: "page HTML") }
            if lowered.hasPrefix("{") || lowered.hasPrefix("[") { return .notMedia(hint: "réponse JSON") }
        }
        if let type = contentType?.lowercased(), type.contains("video/mp2t") || type.contains("mpegurl") {
            // En-tête plausible mais contenu non reconnu : on reste prudent.
            return .notMedia(hint: "contenu non reconnu (\(type))")
        }
        return .notMedia(hint: "contenu non reconnu")
    }

    /// Paquets TS de 188 octets commençant par 0x47 (on tolère un décalage initial).
    static func isMPEGTS(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 188 * 2 else {
            return bytes.first == 0x47 && bytes.count >= 188
        }
        for offset in 0..<min(188, bytes.count - 188 * 2) {
            if bytes[offset] == 0x47, bytes[offset + 188] == 0x47, bytes[offset + 376] == 0x47 {
                return true
            }
        }
        return false
    }
}
