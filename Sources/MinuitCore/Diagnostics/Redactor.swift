import Foundation

/// Supprime les secrets (identifiant, mot de passe, jetons) de toute chaîne destinée
/// aux journaux, aux diagnostics ou aux messages d'erreur.
///
/// Les URL Xtream contiennent les identifiants en clair, à la fois dans le chemin
/// (`/live/<user>/<pass>/123.ts`) et dans la requête (`?username=…&password=…`).
/// Le rédacteur traite les deux formes, ainsi que toute occurrence littérale des
/// secrets connus.
public struct Redactor: Sendable {
    public static let mask = "***"

    private let secrets: [String]

    public init(secrets: [String] = []) {
        // Les secrets trop courts (1-2 caractères) produiraient des remplacements
        // absurdes dans le texte ; ils restent couverts par le traitement des URL.
        self.secrets = secrets
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
    }

    public init(credentials: XtreamCredentials) {
        self.init(secrets: [credentials.username, credentials.password,
                            credentials.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "",
                            credentials.password.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""])
    }

    private static let sensitiveQueryKeys: Set<String> = ["username", "password", "token", "pass", "user", "auth"]
    private static let credentialPathPrefixes: Set<String> = ["live", "timeshift", "movie", "series", "hls", "hlsr"]

    public func redact(_ text: String) -> String {
        var output = text
        for secret in secrets {
            output = output.replacingOccurrences(of: secret, with: Self.mask)
        }
        return Self.redactURLs(in: output)
    }

    public func redact(_ url: URL) -> String {
        redact(url.absoluteString)
    }

    /// Masque les paramètres sensibles et les segments d'identifiants dans
    /// toutes les URL présentes dans le texte, même sans secret connu.
    static func redactURLs(in text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if let range = text.range(of: "http", range: index..<text.endIndex) {
                result += text[index..<range.lowerBound]
                var end = range.lowerBound
                while end < text.endIndex, !text[end].isWhitespace, text[end] != "\"", text[end] != "'", text[end] != ">" {
                    end = text.index(after: end)
                }
                let candidate = String(text[range.lowerBound..<end])
                result += redactSingleURL(candidate)
                index = end
            } else {
                result += text[index..<text.endIndex]
                break
            }
        }
        return result
    }

    static func redactSingleURL(_ string: String) -> String {
        guard var components = URLComponents(string: string), components.host != nil else { return string }
        if components.user != nil { components.user = mask }
        if components.password != nil { components.password = mask }
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                sensitiveQueryKeys.contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: mask) : item
            }
        }
        // /live/<user>/<pass>/… , /timeshift/<user>/<pass>/…
        var segments = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let first = segments.firstIndex(where: { credentialPathPrefixes.contains($0.lowercased()) }),
           segments.count > first + 2 {
            segments[first + 1] = mask
            segments[first + 2] = mask
            components.percentEncodedPath = segments.joined(separator: "/")
        } else if segments.count >= 4,
                  segments[0].isEmpty,
                  segments.last.map({ $0.hasSuffix(".ts") || $0.hasSuffix(".m3u8") }) == true {
            // Forme courte : http://host/<user>/<pass>/<id>
            segments[1] = mask
            segments[2] = mask
            components.percentEncodedPath = segments.joined(separator: "/")
        }
        return components.string ?? string
    }
}
