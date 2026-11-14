import Foundation
import MinuitCore

/// Vérifie qu'une archive annoncée est **réellement** lisible avant de la proposer,
/// et détermine le style d'URL de timeshift accepté par le serveur.
///
/// Le sondage télécharge au plus 4 Ko (en-tête Range). Il consomme brièvement une
/// connexion du compte : on ne sonde qu'à la demande de l'utilisateur (ouverture
/// d'un programme passé), jamais en masse.
@MainActor
final class ArchiveService {
    enum Resolution: Equatable {
        /// Formats réellement lisibles (vérifiés), dans l'ordre de préférence, et style d'URL.
        case playable(formats: [StreamFormat], style: XtreamURLBuilder.TimeshiftStyle)
        case unavailable(String)
    }

    private var client: XtreamClient?
    private var serverTimeZone = TimeZone(identifier: "UTC")!
    private var settings = CatchupSettings()
    private let log = DiagnosticsLog.shared
    /// Style confirmé, mémorisé par l'appelant dans les réglages.
    var onStyleConfirmed: ((XtreamURLBuilder.TimeshiftStyle) -> Void)?

    func configure(client: XtreamClient, session: XtreamSession, settings: CatchupSettings) {
        self.client = client
        self.serverTimeZone = session.server.timeZone
        self.settings = settings
    }

    /// Trouve une URL d'archive lisible pour la fenêtre, en essayant HLS d'abord
    /// (repositionnement précis possible avec AVPlayer), puis MPEG-TS, et les deux
    /// styles d'URL si aucun n'est encore confirmé.
    func resolve(channel: ChannelID, window: ArchiveWindow, formats: [StreamFormat]) async -> Resolution {
        guard let client else { return .unavailable("Session non initialisée.") }
        // Style confirmé d'abord, l'autre ensuite : une confirmation ancienne peut être fausse.
        let confirmed = settings.confirmedStyle
        let styles: [XtreamURLBuilder.TimeshiftStyle] = confirmed.map { [$0] + XtreamURLBuilder.TimeshiftStyle.allCases.filter { $0 != confirmed } }
            ?? [.path, .query]
        // Réponses toutes vides : le serveur n'a peut-être pas encore libéré la connexion
        // précédente, ou prépare l'archive. Une seconde passe, 2 s plus tard.
        var lastHint = "aucune réponse exploitable"
        let startText = XtreamURLBuilder.timeshiftTimestamp(window.requestStart, timeZone: serverTimeZone)
        log.log(.info, "replay", "Archive demandée : \(startText) (\(serverTimeZone.identifier)), \(window.durationMinutes) min")
        for round in 0..<2 {
            var allEmpty = true
            if round > 0 {
                log.log(.info, "replay", "Réponses vides : nouvel essai dans 2 s")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            if let result = await probeStyles(styles, client: client, channel: channel, window: window, formats: formats,
                                              lastHint: &lastHint, allEmpty: &allEmpty) {
                return result
            }
            if !allEmpty { break }
        }
        return .unavailable("Archive annoncée mais non lisible (\(lastHint)).")
    }

    private func probeStyles(_ styles: [XtreamURLBuilder.TimeshiftStyle], client: XtreamClient, channel: ChannelID,
                             window: ArchiveWindow, formats: [StreamFormat],
                             lastHint: inout String, allEmpty: inout Bool) async -> Resolution? {
        for style in styles {
            var playable: [StreamFormat] = []
            for format in formats {
                let url = client.urls.timeshiftURL(channel: channel, start: window.requestStart, durationMinutes: window.durationMinutes,
                                                   serverTimeZone: serverTimeZone, style: style, format: format)
                let verdict = await ArchiveProbe.probe(url, using: client.http)
                log.log(.info, "replay", "Sondage \(style.rawValue)/\(format.rawValue) : \(verdict)")
                switch verdict {
                case .playable(let detected):
                    // Un serveur peut répondre en MPEG-TS à une URL .m3u8 : on retient le format réel.
                    if !playable.contains(detected) { playable.append(detected) }
                case .httpError(let code):
                    lastHint = code == 0 ? "pas de réponse du serveur" : "le serveur répond \(code)"
                    allEmpty = false
                case .notMedia(let hint), .providerMessage(let hint):
                    lastHint = hint
                    allEmpty = false
                case .empty:
                    lastHint = "réponse vide"
                }
            }
            if !playable.isEmpty {
                if settings.confirmedStyle != style {
                    settings.confirmedStyle = style
                    onStyleConfirmed?(style)
                }
                return .playable(formats: playable, style: style)
            }
        }
        return nil
    }
}
