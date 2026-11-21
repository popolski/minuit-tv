import Foundation

/// Logique du relais local des flux (testable sous Linux ; le serveur lui-même est dans l'app).
///
/// Comme le lecteur web qui lit ce fournisseur sans souci : le moteur vidéo ne parle plus au
/// fournisseur, il lit `http://127.0.0.1:<port>/s/<séance>/<n>.<ext>` ; le relais va chercher le
/// flux (redirections réparées à chaque saut, agent VLC) et coupe la séance précédente avant
/// d'ouvrir la suivante (compte à une connexion). Les chemins locaux sont opaques : aucun
/// identifiant n'y figure.
public final class StreamRelayRoutes: @unchecked Sendable {
    private let lock = NSLock()
    private var session = 0
    private var next = 0
    private var urls: [Int: URL] = [:]

    public init() {}

    public enum Lookup: Equatable {
        case found(URL, session: Int)
        /// Chemin d'une séance remplacée : le flux a été coupé (410).
        case stale
        case unknown
    }

    /// Ouvre une séance : les chemins des séances précédentes ne sont plus servis.
    public func newSession() -> Int {
        lock.lock(); defer { lock.unlock() }
        session += 1
        urls = [:]
        return session
    }

    public var currentSession: Int {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    /// Chemin local d'une adresse amont, dans la séance donnée (extension gardée : certains
    /// moteurs s'en servent pour deviner le format).
    public func path(for url: URL, session s: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        next += 1
        if s == session { urls[next] = url }
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return "/s/\(s)/\(next)\(ext)"
    }

    public func lookup(_ path: String) -> Lookup {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "s", let s = Int(parts[1]),
              let n = Int(parts[2].split(separator: ".").first ?? "") else { return .unknown }
        lock.lock(); defer { lock.unlock() }
        guard s == session else { return s < session ? .stale : .unknown }
        guard let url = urls[n] else { return .unknown }
        return .found(url, session: s)
    }
}

/// Listes HLS : chaque adresse (segment, sous-liste, clé) repasse par le relais.
public enum HLSPlaylistRewriter {
    public static func isPlaylist(contentType: String?, url: URL) -> Bool {
        (contentType ?? "").lowercased().contains("mpegurl") || url.pathExtension.lowercased() == "m3u8"
    }

    /// - Parameter map: adresse amont absolue → adresse locale.
    public static func rewrite(_ text: String, base: URL, map: (URL) -> String) -> String {
        func wrap(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let absolute = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return raw }
            return map(absolute)
        }
        var out: [String] = []
        // « \r\n » est un seul caractère pour Swift : normalisé avant découpe.
        for sub in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sub)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                out.append(wrap(trimmed))
            } else if let start = line.range(of: "URI=\""),
                      let end = line.range(of: "\"", range: start.upperBound..<line.endIndex) {
                out.append(line.replacingCharacters(in: start.upperBound..<end.lowerBound,
                                                    with: wrap(String(line[start.upperBound..<end.lowerBound]))))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}

/// En-tête de réponse du relais : statut amont et en-têtes utiles au moteur, connexion fermée ensuite.
public enum RelayResponseHead {
    /// En-têtes amont transmis tels quels.
    public static let forwarded = ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"]

    public static func make(status: Int, headers: [String: String]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for name in forwarded {
            if let value = headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value {
                head += "\(name): \(value)\r\n"
            }
        }
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 407: return "Proxy Authentication Required"
        case 410: return "Gone"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }
}
