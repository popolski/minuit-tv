import Foundation

/// Journal de diagnostic en mémoire (tampon circulaire), consultable depuis
/// les réglages. Tout message passe par le `Redactor` avant stockage.
public final class DiagnosticsLog: @unchecked Sendable {
    public enum Level: String, Sendable, Codable { case debug, info, warning, error }

    public struct Entry: Sendable, Identifiable, Codable, Hashable {
        public let id: UInt64
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var counter: UInt64 = 0
    private var redactor: Redactor
    public let capacity: Int

    public init(capacity: Int = 500, redactor: Redactor = Redactor()) {
        self.capacity = capacity
        self.redactor = redactor
    }

    public static let shared = DiagnosticsLog()

    /// Met à jour les secrets à masquer (après connexion).
    public func updateRedactor(_ redactor: Redactor) {
        lock.lock(); defer { lock.unlock() }
        self.redactor = redactor
    }

    public func log(_ level: Level, _ category: String, _ message: @autoclosure () -> String) {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        let entry = Entry(id: counter, date: Date(), level: level, category: category, message: redactor.redact(message()))
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}

/// Mesures de lecture agrégées pour l'écran de diagnostic.
public struct PlaybackStatistics: Sendable, Codable, Equatable {
    public var tunes = 0
    public var firstFrameTimes: [TimeInterval] = []
    public var recoveries = 0
    public var fallbacks = 0
    public var failures = 0

    public init() {}

    public mutating func recordFirstFrame(_ seconds: TimeInterval) {
        firstFrameTimes.append(seconds)
        if firstFrameTimes.count > 50 { firstFrameTimes.removeFirst(firstFrameTimes.count - 50) }
    }

    public var medianFirstFrame: TimeInterval? {
        guard !firstFrameTimes.isEmpty else { return nil }
        let sorted = firstFrameTimes.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
