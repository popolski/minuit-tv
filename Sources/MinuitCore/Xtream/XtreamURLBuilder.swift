import Foundation

/// Construction des URL Xtream. Seul endroit du code qui assemble des URL
/// contenant les identifiants ; ces URL ne doivent jamais être journalisées
/// autrement qu'au travers de `Redactor`.
public struct XtreamURLBuilder: Sendable {
    public let credentials: XtreamCredentials

    public init(credentials: XtreamCredentials) {
        self.credentials = credentials
    }

    private var base: URL { credentials.server.baseURL }

    /// Concatène un chemin déjà encodé à l'URL de base (préfixe éventuel inclus).
    private func joined(_ encodedPath: String) -> URL {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + "/" + encodedPath)!
    }

    private func encodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: API

    public func apiURL(action: String?, parameters: [String: String] = [:]) -> URL {
        var components = URLComponents(url: base.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "username", value: credentials.username),
                     URLQueryItem(name: "password", value: credentials.password)]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        // `+` doit être encodé, sinon certains serveurs PHP l'interprètent comme une espace.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    public func xmltvURL() -> URL {
        var components = URLComponents(url: base.appendingPathComponent("xmltv.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "username", value: credentials.username),
                                 URLQueryItem(name: "password", value: credentials.password)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    // MARK: Direct

    /// URL du direct : `/live/<user>/<pass>/<id>.<ext>`.
    public func liveURL(channel: ChannelID, format: StreamFormat) -> URL {
        let path = "live/\(encodedPathComponent(credentials.username))/\(encodedPathComponent(credentials.password))/\(channel.rawValue).\(format.fileExtension)"
        return joined(path)
    }

    // MARK: Films et séries

    /// Film : `/movie/<user>/<pass>/<id>.<ext>`.
    public func movieURL(id: Int, containerExtension: String) -> URL {
        joined("movie/\(encodedPathComponent(credentials.username))/\(encodedPathComponent(credentials.password))/\(id).\(encodedPathComponent(containerExtension))")
    }

    /// Épisode : `/series/<user>/<pass>/<id épisode>.<ext>`.
    public func episodeURL(id: String, containerExtension: String) -> URL {
        joined("series/\(encodedPathComponent(credentials.username))/\(encodedPathComponent(credentials.password))/\(encodedPathComponent(id)).\(encodedPathComponent(containerExtension))")
    }

    // MARK: Rattrapage

    public enum TimeshiftStyle: String, Sendable, Codable, CaseIterable {
        /// `/timeshift/<user>/<pass>/<durée min>/<YYYY-MM-DD:HH-mm>/<id>.ts` (le plus répandu)
        case path
        /// `/streaming/timeshift.php?username=…&password=…&stream=…&start=…&duration=…`
        case query
    }

    /// URL d'archive. L'heure de début est exprimée **dans le fuseau du serveur**,
    /// pas dans celui de l'appareil : c'est la cause la plus fréquente de replays décalés.
    public func timeshiftURL(channel: ChannelID, start: Date, durationMinutes: Int,
                             serverTimeZone: TimeZone, style: TimeshiftStyle,
                             format: StreamFormat = .mpegts) -> URL {
        let startText = Self.timeshiftTimestamp(start, timeZone: serverTimeZone)
        let duration = max(1, durationMinutes)
        switch style {
        case .path:
            let path = "timeshift/\(encodedPathComponent(credentials.username))/\(encodedPathComponent(credentials.password))/\(duration)/\(startText)/\(channel.rawValue).\(format.fileExtension)"
            return joined(path)
        case .query:
            var components = URLComponents(url: base.appendingPathComponent("streaming/timeshift.php"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "username", value: credentials.username),
                URLQueryItem(name: "password", value: credentials.password),
                URLQueryItem(name: "stream", value: String(channel.rawValue)),
                URLQueryItem(name: "start", value: startText),
                URLQueryItem(name: "duration", value: String(duration)),
            ]
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return components.url!
        }
    }

    public static func timeshiftTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d:%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
