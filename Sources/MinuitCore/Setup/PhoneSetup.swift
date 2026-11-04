import Foundation

/// Configuration depuis le téléphone : l'Apple TV ouvre un petit serveur web sur le réseau
/// local, affiche un QR code (adresse + code à 6 chiffres) ; le téléphone envoie le serveur,
/// l'identifiant et le mot de passe. Ici : la logique testable (code, requêtes, page).
///
/// Sécurité : le code est exigé à chaque requête, expire, et se bloque après quelques essais
/// faux ; le serveur ne vit que pendant l'écran de connexion. Les identifiants circulent en
/// HTTP sur le réseau local (pas de certificat possible pour une adresse locale) : la page le dit.
public struct PhoneSetupSession: Sendable, Equatable {
    public let code: String
    public let expiresAt: Date
    public private(set) var failedAttempts = 0
    public static let maxFailedAttempts = 5

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }

    /// Nouveau code à 6 chiffres (générateur système), valable `lifetime` secondes.
    public static func make(now: Date = Date(), lifetime: TimeInterval = 600) -> PhoneSetupSession {
        var generator = SystemRandomNumberGenerator()
        let code = String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
        return PhoneSetupSession(code: code, expiresAt: now.addingTimeInterval(lifetime))
    }

    public var isLocked: Bool { failedAttempts >= Self.maxFailedAttempts }

    /// Vérifie un code reçu ; un code faux compte comme un essai.
    public mutating func check(_ candidate: String?, at date: Date) -> Bool {
        guard !isLocked, date < expiresAt else { return false }
        let digits = (candidate ?? "").filter(\.isNumber)
        if digits == code { return true }
        failedAttempts += 1
        return false
    }

    /// « 482 913 » : plus facile à lire à 3 m.
    public var displayCode: String { String(code.prefix(3)) + " " + String(code.suffix(3)) }
}

/// Requête HTTP/1.1 minimale (le téléphone n'envoie que GET / et POST /config).
public struct LocalHTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    /// Taille maximale acceptée (en-têtes + corps) : la page n'envoie que trois champs.
    public static let maxSize = 16 * 1024

    public enum ParseResult: Equatable {
        case complete(LocalHTTPRequest)
        case needMoreData
        case invalid
    }

    public static func parse(_ data: Data) -> ParseResult {
        guard data.count <= maxSize else { return .invalid }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .needMoreData }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return .needMoreData }
        let target = String(parts[1])
        let pathEnd = target.firstIndex(of: "?") ?? target.endIndex
        let query = pathEnd < target.endIndex ? FormDecoding.decode(String(target[target.index(after: pathEnd)...])) : [:]
        return .complete(LocalHTTPRequest(method: String(parts[0]), path: String(target[..<pathEnd]), query: query,
                                          headers: headers, body: Data(data[bodyStart..<(bodyStart + length)])))
    }

    /// Réponse complète (connexion fermée ensuite).
    public static func response(status: Int, contentType: String, body: Data) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// `application/x-www-form-urlencoded` (corps de formulaire et paramètres d'URL).
public enum FormDecoding {
    public static func decode(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = unescape(String(kv[0]))
            guard !key.isEmpty else { continue }
            result[key] = kv.count > 1 ? unescape(String(kv[1])) : ""
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? text
    }
}

/// Page servie au téléphone : formulaire en trois champs, envoyé à `/config`.
public enum PhoneSetupPage {
    public static func html(code: String) -> String {
        """
        <!doctype html>
        <html lang="fr"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Configurer Minuit</title>
        <style>
        body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#0B1426;color:#EEF2FA}
        main{max-width:520px;margin:0 auto;padding:28px 20px}
        h1{font-size:26px;margin:0 0 6px}p{color:#9AA8C7;line-height:1.45}
        label{display:block;font-weight:600;margin:18px 0 6px}
        input{width:100%;box-sizing:border-box;font-size:17px;padding:13px 14px;border-radius:12px;border:1px solid #2A3A5E;background:#111C33;color:#EEF2FA}
        button{margin-top:24px;width:100%;font-size:18px;font-weight:600;padding:15px;border:0;border-radius:14px;background:#EEF2FA;color:#0B1426}
        #msg{margin-top:18px;font-weight:600}.note{font-size:14px;color:#8391B0}
        </style></head><body><main>
        <h1>Configurer Minuit</h1>
        <p>Saisissez les informations Xtream Codes de votre fournisseur. Elles sont envoyées à l’Apple TV, qui les range dans son trousseau.</p>
        <form id="f">
        <label for="server">Adresse du serveur</label>
        <input id="server" name="server" inputmode="url" autocapitalize="none" autocorrect="off" placeholder="http://exemple.tv:8080" required>
        <label for="username">Identifiant</label>
        <input id="username" name="username" autocapitalize="none" autocorrect="off" autocomplete="username" required>
        <label for="password">Mot de passe</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
        <input type="hidden" name="code" value="\(code)">
        <button type="submit">Envoyer à l’Apple TV</button>
        </form>
        <p id="msg" role="status"></p>
        <p class="note">Le téléphone et l’Apple TV doivent être sur le même réseau. L’envoi reste sur ce réseau local, sans chiffrement : utilisez-le chez vous, pas sur un Wi-Fi public.</p>
        </main><script>
        document.getElementById('f').addEventListener('submit', async (e) => {
          e.preventDefault();
          const msg = document.getElementById('msg');
          msg.textContent = 'Envoi…';
          try {
            const r = await fetch('/config', {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                                              body: new URLSearchParams(new FormData(e.target)).toString()});
            msg.textContent = await r.text();
          } catch (err) { msg.textContent = 'L’Apple TV ne répond pas. Rouvrez l’écran de connexion.'; }
        });
        </script></body></html>
        """
    }
}
