import Foundation
import MinuitCore

/// Mode démonstration / tests d'interface (argument de lancement `-uitest`).
///
/// Simule un serveur Xtream avec des chaînes **inventées** et un guide calculé autour de
/// l'heure courante. Aucun compte, aucun réseau : sert aux tests d'interface sur simulateur
/// (CI) pour reproduire les parcours (ouvrir une chaîne, zapper, revenir) sans fournisseur.
enum DemoMode {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-uitest")

    static let credentials = XtreamCredentials(
        server: ServerAddress(scheme: .http, host: "demo.minuit.invalid"),
        username: "demo",
        password: "demo-pass"
    )

    /// Vidéo locale lue à la place des flux (fichier embarqué dans l'application).
    static var mediaURL: URL? {
        Bundle.main.url(forResource: "demo-h264-aac", withExtension: "mp4")
            ?? Bundle.main.url(forResource: "demo-h264-aac", withExtension: "mp4", subdirectory: "TestMedia")
    }
}

final class DemoXtreamHTTPClient: HTTPClient {
    struct DemoChannel {
        let id: Int, name: String, category: String, archiveDays: Int
    }

    static let categories: [(id: String, name: String)] = [
        ("1", "Généralistes"), ("2", "Information"), ("3", "Sport"), ("4", "Cinéma"), ("5", "Jeunesse"),
    ]

    static let channels: [DemoChannel] = [
        .init(id: 101, name: "Aurore 1 HD", category: "1", archiveDays: 7),
        .init(id: 102, name: "Horizon FHD", category: "1", archiveDays: 3),
        .init(id: 103, name: "Canal Lune", category: "1", archiveDays: 0),
        .init(id: 201, name: "Minuit Info HD", category: "2", archiveDays: 2),
        .init(id: 202, name: "Météo Nuit", category: "2", archiveDays: 0),
        .init(id: 301, name: "Stade 4K", category: "3", archiveDays: 1),
        .init(id: 302, name: "Arena Sport HD", category: "3", archiveDays: 0),
        .init(id: 401, name: "Ciné Étoile FHD", category: "4", archiveDays: 7),
        .init(id: 402, name: "Classiques", category: "4", archiveDays: 0),
        .init(id: 501, name: "Petit Phare", category: "5", archiveDays: 0),
    ]

    static let titles = ["Le Journal", "Grand Format", "La Nuit des Étoiles", "Magazine du Soir", "Match en direct",
                         "Documentaire : Les Marées", "Film : Le Phare", "Dessins animés", "Météo", "Débat"]

    func send(_ request: HTTPRequest) async throws(TransportError) -> HTTPResponse {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let action = components?.queryItems?.first { $0.name == "action" }?.value
        let streamID = components?.queryItems?.first { $0.name == "stream_id" }?.value.flatMap(Int.init)
        let path = request.url.path
        try? await Task.sleep(nanoseconds: 80_000_000)

        if path.contains("timeshift") {
            // Archive « lisible » : paquets MPEG-TS factices (le sondage les reconnaît).
            var data = Data(repeating: 0xFF, count: 188 * 22)
            for offset in stride(from: 0, to: data.count, by: 188) { data[offset] = 0x47 }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "video/mp2t"], body: data)
        }
        if path.hasSuffix("xmltv.php") {
            return json("<?xml version=\"1.0\"?><tv></tv>")
        }
        switch action {
        case nil: return json(Self.authJSON())
        case "get_live_categories": return json(Self.categoriesJSON())
        case "get_live_streams": return json(Self.streamsJSON())
        case "get_short_epg", "get_simple_data_table": return json(Self.epgJSON(streamID: streamID ?? 0))
        default: return HTTPResponse(statusCode: 404, body: Data())
        }
    }

    private func json(_ text: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    static func authJSON() -> String {
        let now = Int(Date().timeIntervalSince1970)
        return """
        {"user_info":{"username":"demo","auth":1,"status":"Active","exp_date":"\(now + 365 * 86_400)","is_trial":"0",
        "active_cons":"0","max_connections":"2","allowed_output_formats":["m3u8","ts"]},
        "server_info":{"url":"demo.minuit.invalid","port":"80","https_port":"","timezone":"Europe/Paris","timestamp_now":\(now)}}
        """
    }

    static func categoriesJSON() -> String {
        "[" + categories.map { "{\"category_id\":\"\($0.id)\",\"category_name\":\"\($0.name)\",\"parent_id\":0}" }.joined(separator: ",") + "]"
    }

    static func streamsJSON() -> String {
        "[" + channels.enumerated().map { index, c in
            "{\"num\":\(index + 1),\"name\":\"\(c.name)\",\"stream_type\":\"live\",\"stream_id\":\(c.id),\"stream_icon\":\"\","
            + "\"epg_channel_id\":\"demo.\(c.id)\",\"category_id\":\"\(c.category)\",\"tv_archive\":\(c.archiveDays > 0 ? 1 : 0),"
            + "\"tv_archive_duration\":\(c.archiveDays)}"
        }.joined(separator: ",") + "]"
    }

    /// Programmes d'une heure (alignés sur l'heure pleine), de -6 h à +12 h.
    static func epgJSON(streamID: Int) -> String {
        let hour = 3600
        let now = Int(Date().timeIntervalSince1970)
        let base = now - now % hour
        var items: [String] = []
        for slot in -6..<12 {
            let start = base + slot * hour
            let title = titles[abs(streamID + slot) % titles.count]
            let encoded = Data(title.utf8).base64EncodedString()
            let summary = Data("Programme de démonstration.".utf8).base64EncodedString()
            items.append("{\"id\":\"\(slot)\",\"title\":\"\(encoded)\",\"description\":\"\(summary)\","
                         + "\"start_timestamp\":\"\(start)\",\"stop_timestamp\":\"\(start + hour)\",\"has_archive\":\(slot < 0 ? 1 : 0)}")
        }
        return "{\"epg_listings\":[" + items.joined(separator: ",") + "]}"
    }
}
