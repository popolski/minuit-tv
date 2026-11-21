import Foundation

/// Détermine le fuseau horaire du serveur Xtream.
///
/// Comme le lecteur web (dont le replay fonctionne chez ce fournisseur), l'heure murale réelle
/// du serveur fait foi : décalage déduit de `time_now` (heure murale) et `timestamp_now` (UTC).
/// L'identifiant IANA annoncé (`server_info.timezone`) n'est retenu que s'il donne ce même
/// décalage (il gère alors les changements d'heure) ; sans mesure, il sert seul ; sinon UTC.
/// Un identifiant annoncé qui ne correspond pas à l'horloge du serveur décalerait toutes les
/// URL de timeshift.
public enum ServerTimeZoneResolver {
    public static func resolve(identifier: String?, timestampNow: Int?, timeNow: String?) -> TimeZone {
        let announced = identifier.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { TimeZone(identifier: $0) }
        if let timestampNow, let timeNow, let wall = parseWallClock(timeNow, in: TimeZone(identifier: "UTC")!) {
            let raw = wall.timeIntervalSince1970 - TimeInterval(timestampNow)
            // Arrondi au quart d'heure (fuseaux réels : multiples de 15 min).
            let rounded = Int((raw / 900).rounded()) * 900
            if abs(rounded) <= 14 * 3600, let zone = TimeZone(secondsFromGMT: rounded) {
                let now = Date(timeIntervalSince1970: TimeInterval(timestampNow))
                if let announced, announced.secondsFromGMT(for: now) == rounded { return announced }
                return zone
            }
        }
        return announced ?? TimeZone(identifier: "UTC")!
    }

    /// Analyse `YYYY-MM-DD HH:mm:ss` dans le fuseau indiqué.
    public static func parseWallClock(_ text: String, in timeZone: TimeZone) -> Date? {
        let digits = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count >= 5 else { return nil }
        var components = DateComponents()
        components.year = digits[0]
        components.month = digits[1]
        components.day = digits[2]
        components.hour = digits[3]
        components.minute = digits[4]
        components.second = digits.count > 5 ? digits[5] : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let month = components.month, (1...12).contains(month),
              let day = components.day, (1...31).contains(day) else { return nil }
        return calendar.date(from: components)
    }
}
