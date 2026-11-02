import Foundation

/// Géométrie de la grille du guide : conversion temps ↔ abscisse.
///
/// Tous les calculs se font en temps absolu ; seules les graduations
/// (« 20:30 ») dépendent du fuseau de l'appareil. Lors d'un changement d'heure,
/// la grille reste continue et les graduations sautent ou se répètent comme
/// sur une montre — c'est le comportement attendu par l'utilisateur.
public struct GuideTimeline: Sendable, Equatable {
    public var origin: Date
    public var end: Date
    public var pointsPerMinute: Double
    public var timeZone: TimeZone

    public init(origin: Date, end: Date, pointsPerMinute: Double, timeZone: TimeZone) {
        self.origin = origin
        self.end = max(origin, end)
        self.pointsPerMinute = pointsPerMinute
        self.timeZone = timeZone
    }

    /// Grille centrée sur `now` : de `pastHours` avant à `futureHours` après,
    /// origine alignée sur la demi-heure locale.
    public static func around(_ now: Date, pastHours: Double, futureHours: Double,
                              pointsPerMinute: Double, timeZone: TimeZone) -> GuideTimeline {
        let start = alignDown(now.addingTimeInterval(-pastHours * 3600), toMinutes: 30, timeZone: timeZone)
        return GuideTimeline(origin: start, end: now.addingTimeInterval(futureHours * 3600),
                             pointsPerMinute: pointsPerMinute, timeZone: timeZone)
    }

    public var totalWidth: Double { x(for: end) }
    public var interval: DateInterval { DateInterval(start: origin, end: end) }

    public func x(for date: Date) -> Double {
        date.timeIntervalSince(origin) / 60 * pointsPerMinute
    }

    public func date(forX x: Double) -> Date {
        origin.addingTimeInterval(x / pointsPerMinute * 60)
    }

    public func width(for interval: DateInterval) -> Double {
        interval.duration / 60 * pointsPerMinute
    }

    /// Cadre horizontal d'une case, rogné aux bornes de la grille.
    public func span(for interval: DateInterval) -> (x: Double, width: Double)? {
        let start = max(interval.start, origin)
        let stop = min(interval.end, end)
        guard stop > start else { return nil }
        return (x(for: start), width(for: DateInterval(start: start, end: stop)))
    }

    /// Intervalle de temps visible pour un défilement donné.
    public func visibleInterval(offsetX: Double, viewportWidth: Double) -> DateInterval {
        let start = date(forX: max(0, offsetX))
        let stop = date(forX: min(totalWidth, offsetX + viewportWidth))
        return DateInterval(start: start, end: max(start, stop))
    }

    /// Graduations toutes les `stepMinutes` minutes, alignées sur l'heure locale.
    public func ticks(stepMinutes: Int = 30) -> [Tick] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var result: [Tick] = []
        var current = Self.alignDown(origin, toMinutes: stepMinutes, timeZone: timeZone)
        if current < origin { current = current.addingTimeInterval(TimeInterval(stepMinutes * 60)) }
        while current <= end {
            let c = calendar.dateComponents([.hour, .minute], from: current)
            result.append(Tick(date: current, x: x(for: current), hour: c.hour ?? 0, minute: c.minute ?? 0))
            // Pas en temps absolu : continu à travers les changements d'heure.
            current = current.addingTimeInterval(TimeInterval(stepMinutes * 60))
        }
        return result
    }

    public struct Tick: Sendable, Hashable {
        public var date: Date
        public var x: Double
        public var hour: Int
        public var minute: Int

        public var label: String { String(format: "%02d:%02d", hour, minute) }
    }

    /// Arrondi inférieur à un multiple de `minutes` dans le fuseau donné
    /// (gère les fuseaux à décalage non entier, ex. +05:30).
    public static func alignDown(_ date: Date, toMinutes minutes: Int, timeZone: TimeZone) -> Date {
        let offset = TimeInterval(timeZone.secondsFromGMT(for: date))
        let local = date.timeIntervalSince1970 + offset
        let step = TimeInterval(minutes * 60)
        let aligned = (local / step).rounded(.down) * step
        return Date(timeIntervalSince1970: aligned - offset)
    }
}

/// Libellés de jour relatifs (« Aujourd'hui », « Hier », « Demain », « jeudi 5 »).
public enum DayLabel {
    public static func label(for date: Date, relativeTo now: Date, timeZone: TimeZone, locale: Locale = Locale(identifier: "fr_FR")) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day ?? 0
        switch days {
        case 0: return "Aujourd'hui"
        case -1: return "Hier"
        case 1: return "Demain"
        default:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate("EEEEd")
            return formatter.string(from: date)
        }
    }
}
