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
        let styles: [XtreamURLBuilder.TimeshiftStyle] = settings.confirmedStyle.map { [$0] } ?? [.path, .query]
        var lastHint = "aucune réponse exploitable"
        for style in styles {
            var playable: [StreamFormat] = []
            for format in formats {
                let url = client.urls.timeshiftURL(channel: channel, start: window.requestStart, durationMinutes: window.durationMinutes,
                                                   serverTimeZone: serverTimeZone, style: style, format: format)
                let verdict = await probe(url, http: client.http)
                log.log(.info, "replay", "Sondage \(style.rawValue)/\(format.rawValue) : \(verdict)")
                switch verdict {
                case .playable(let detected):
                    // Un serveur peut répondre en MPEG-TS à une URL .m3u8 : on retient le format réel.
                    if !playable.contains(detected) { playable.append(detected) }
                case .httpError(let code):
                    lastHint = "le serveur répond \(code)"
                case .notMedia(let hint):
                    lastHint = hint
                case .empty:
                    lastHint = "réponse vide"
                }
            }
            if !playable.isEmpty {
                if settings.confirmedStyle == nil {
                    settings.confirmedStyle = style
                    onStyleConfirmed?(style)
                }
                return .playable(formats: playable, style: style)
            }
        }
        return .unavailable("Archive annoncée mais non lisible (\(lastHint)).")
    }

    private func probe(_ url: URL, http: HTTPClient) async -> ArchiveProbe.Verdict {
        do {
            let response = try await http.fetchPrefix(HTTPRequest(url: url, timeout: 12, byteRange: 0...(ArchiveProbe.probeByteCount - 1)),
                                                     maxBytes: ArchiveProbe.probeByteCount)
            return ArchiveProbe.classify(statusCode: response.statusCode, contentType: response.header("Content-Type"),
                                         body: response.body.prefix(ArchiveProbe.probeByteCount))
        } catch {
            log.log(.warning, "replay", "Sondage : erreur réseau \(error)")
            return .httpError(0)
        }
    }
}
