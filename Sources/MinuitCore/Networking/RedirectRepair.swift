import Foundation

/// Redirections mal formées de certains fournisseurs : l'archive (ou le film) redirige vers
/// `https://serveur:8080/…` alors que ce port ne parle que HTTP. La poignée de main TLS
/// échoue (« certificat refusé », NSURLErrorDomain -1200) avant même la première réponse.
/// Constaté avec nginx sur le port 8080 (401 en HTTP sans jeton, rejet TLS en HTTPS).
public enum RedirectRepair {
    /// Cible corrigée : origine en HTTP, cible en HTTPS sur un port explicite autre que
    /// 443 et 8443 (ports TLS usuels) : la cible est gardée en HTTP. Sinon, inchangée.
    public static func repaired(_ target: URL, from origin: URL) -> URL {
        guard origin.scheme?.lowercased() == "http", target.scheme?.lowercased() == "https",
              let port = target.port, port != 443, port != 8443,
              var components = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return target }
        components.scheme = "http"
        return components.url ?? target
    }

    /// URL à donner au lecteur : la cible corrigée si la redirection est de ce type, sinon
    /// l'URL d'origine (le lecteur suit lui-même une redirection correcte et peut la
    /// renouveler en cas de reconnexion).
    public static func playableURL(for url: URL, using http: HTTPClient) async -> URL {
        guard let target = try? await http.redirectTarget(HTTPRequest(url: url, timeout: 8)) else { return url }
        let fixed = repaired(target, from: url)
        return fixed != target ? fixed : url
    }
}
