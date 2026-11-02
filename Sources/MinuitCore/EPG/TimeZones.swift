import Foundation

/// Détermine le fuseau horaire du serveur Xtream.
///
/// Ordre de préférence :
/// 1. l'identifiant IANA annoncé (`server_info.timezone`, ex. `Europe/Paris`) ;
/// 2. un décalage déduit de `time_now` (heure murale du serveur) et `timestamp_now` (UTC) ;
/// 3. UTC.
///
/// Un fuseau IANA gère les changements d'heure ; un décalage fixe ne le peut pas,
/// d'où la priorité donnée à l'identifiant.
public enum ServerTimeZoneResolver {
    public static func resolve(identifier: String?, timestampNow: Int?, timeNow: String?) -> TimeZone {
        if let identifier = identifier?.trimmingCharacters(in: .whitespaces), !identifier.isEmpty,
           let zone = TimeZone(identifier: identifier) {
            return zone
        }
        if let timestampNow, let timeNow, let wall = parseWallClock(timeNow, in: TimeZone(identifier: "UTC")!) {
            let raw = wall.timeIntervalSince1970 - TimeInterval(timestampNow)
            // Arrondi au quart d'heure (fuseaux réels : multiples de 15 min).
            let rounded = Int((raw / 900).rounded()) * 900
            if abs(rounded) <= 14 * 3600, let zone = TimeZone(secondsFromGMT: rounded) {
                return zone
            }
        }
        return TimeZone(identifier: "UTC")!
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
