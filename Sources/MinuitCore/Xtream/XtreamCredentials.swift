import Foundation

/// Identifiants d'un compte Xtream Codes.
///
/// `description` et `debugDescription` sont volontairement masqués : une
/// interpolation accidentelle dans un journal ne révèle jamais le mot de passe.
public struct XtreamCredentials: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var server: ServerAddress
    public var username: String
    public var password: String

    public init(server: ServerAddress, username: String, password: String) {
        self.server = server
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var description: String { "XtreamCredentials(\(server.displayHost), user: ***)" }
    public var debugDescription: String { description }

    public var isComplete: Bool { !username.isEmpty && !password.isEmpty }
}

/// Adresse de serveur normalisée.
///
/// Les utilisateurs saisissent des formes très variées : `exemple.com:8080`,
/// `http://exemple.com:8080/`, `http://exemple.com/player_api.php`,
/// voire une URL M3U complète `http://exemple.com/get.php?username=…`.
/// On ne conserve que schéma, hôte, port et éventuel préfixe de chemin.
public struct ServerAddress: Sendable, Hashable, Codable {
    public enum Scheme: String, Sendable, Codable { case http, https }

    public var scheme: Scheme
    public var host: String
    public var port: Int?
    /// Préfixe de chemin éventuel (certains panneaux sont servis sous `/xc`).
    public var pathPrefix: String

    public init(scheme: Scheme, host: String, port: Int? = nil, pathPrefix: String = "") {
        self.scheme = scheme
        self.host = host.lowercased()
        self.port = port
        self.pathPrefix = pathPrefix
    }

    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case invalid
        case unsupportedScheme(String)
    }

    /// Interprète une saisie libre.
    public static func parse(_ raw: String) throws(ParseError) -> ServerAddress {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .empty }
        if !text.contains("://") { text = "http://" + text }
        guard let components = URLComponents(string: text),
              let schemeText = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              !host.contains(" ")
        else { throw .invalid }
        guard let scheme = Scheme(rawValue: schemeText) else { throw .unsupportedScheme(schemeText) }

        var path = components.path
        let knownEndpoints = ["player_api.php", "get.php", "xmltv.php", "panel_api.php", "c/"]
        for endpoint in knownEndpoints {
            if let range = path.range(of: "/" + endpoint) {
                path = String(path[path.startIndex..<range.lowerBound])
            }
        }
        while path.hasSuffix("/") { path.removeLast() }

        var port = components.port
        if port == 80 && scheme == .http { port = nil }
        if port == 443 && scheme == .https { port = nil }
        return ServerAddress(scheme: scheme, host: host, port: port, pathPrefix: path)
    }

    public var baseURL: URL {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        components.path = pathPrefix
        // Construction sûre : les champs sont déjà validés par `parse`.
        return components.url ?? URL(string: "\(scheme.rawValue)://\(host)")!
    }

    public var displayHost: String {
        port.map { "\(host):\($0)" } ?? host
    }

    public var isSecure: Bool { scheme == .https }

    /// Variante HTTPS lorsque le serveur annonce un port HTTPS.
    public func upgradedToHTTPS(port httpsPort: Int?) -> ServerAddress {
        ServerAddress(scheme: .https, host: host, port: httpsPort == 443 ? nil : httpsPort, pathPrefix: pathPrefix)
    }
}
