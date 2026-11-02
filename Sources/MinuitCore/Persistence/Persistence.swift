import Foundation

/// Stockage clé-valeur de petites données (préférences).
///
/// Sur tvOS, une application ne dispose pas de stockage local persistant garanti :
/// le répertoire Caches peut être purgé quand l'application ne tourne pas, et
/// `UserDefaults` est limité en taille. On y range donc uniquement ce qui est petit
/// et précieux (favoris, réglages) ; le catalogue et le guide vont dans Caches et
/// sont reconstructibles.
public protocol KeyValueStorage: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class UserDefaultsStorage: KeyValueStorage, @unchecked Sendable {
    // UserDefaults est documenté comme thread-safe.
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "minuit.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: prefix + key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }
}

public final class InMemoryStorage: KeyValueStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }
}

/// Lecture/écriture typée et versionnée d'une valeur Codable.
public struct StoredValue<Value: Codable & Sendable>: Sendable {
    public let key: String
    public let storage: KeyValueStorage
    /// Taille maximale encodée : protège contre un dépassement du quota UserDefaults de tvOS.
    public let maxBytes: Int

    public init(key: String, storage: KeyValueStorage, maxBytes: Int = 128 * 1024) {
        self.key = key
        self.storage = storage
        self.maxBytes = maxBytes
    }

    private struct Envelope: Codable {
        var version: Int
        var value: Value
    }

    public static var currentVersion: Int { 1 }

    public func load() -> Value? {
        guard let data = storage.data(forKey: key) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.value
    }

    /// Lève `StoredValueError` (typed throws évité : plantage du compilateur 6.1 en contexte générique).
    public func save(_ value: Value) throws {
        let data: Data
        do { data = try JSONEncoder().encode(Envelope(version: Self.currentVersion, value: value)) }
        catch { throw StoredValueError.encoding }
        guard data.count <= maxBytes else { throw StoredValueError.tooLarge(data.count) }
        storage.set(data, forKey: key)
    }

    public func clear() { storage.set(nil, forKey: key) }
}

public enum StoredValueError: Error, Equatable, Sendable { case tooLarge(Int), encoding }

/// Cache disque reconstructible (catalogue, guide) avec écriture atomique.
public struct FileCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Répertoire Caches de l'application (le seul accessible en écriture durable-ish sur tvOS).
    public static func applicationCaches(subdirectory: String = "Minuit") -> FileCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return FileCache(directory: base.appendingPathComponent(subdirectory, isDirectory: true))
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
    }

    public func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(CacheEnvelope(savedAt: Date(), value: value))
        try data.write(to: url(for: name), options: .atomic)
    }

    public func read<T: Decodable>(_ type: T.Type, name: String) -> (value: T, savedAt: Date)? {
        guard let data = try? Data(contentsOf: url(for: name)),
              let envelope = try? JSONDecoder().decode(CacheEnvelope<T>.self, from: data) else { return nil }
        return (envelope.value, envelope.savedAt)
    }

    public func remove(name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    public func sizeOnDisk() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

struct CacheEnvelope<T> {
    var savedAt: Date
    var value: T
}

extension CacheEnvelope: Encodable where T: Encodable {}
extension CacheEnvelope: Decodable where T: Decodable {}

/// Réglages de l'application.
public struct AppSettings: Sendable, Codable, Equatable {
    public var resumeLastChannelOnLaunch: Bool = true
    public var enginePreference: EnginePreference = .automatic
    public var transportSecurity: TransportSecurityPolicy = .preferHTTPS
    public var userAgentPreset: UserAgentPreset = .minuit
    public var catchup: CatchupSettings = CatchupSettings()
    /// Inverse le sens haut/bas du zapping.
    public var invertZapDirection: Bool = false
    /// Affiche le bandeau d'information à chaque changement de chaîne.
    public var showInfoOnZap: Bool = true
    public var matchContentFrameRate: Bool = true
    public var useXMLTV: Bool = true
    public var epgDaysAhead: Int = 2

    public init() {}
}

public enum UserAgentPreset: String, Sendable, Codable, CaseIterable {
    case minuit
    case vlc
    case okhttp

    public var value: String {
        switch self {
        case .minuit: return "Minuit/1.0 (tvOS)"
        case .vlc: return "VLC/3.0.21 LibVLC/3.0.21"
        case .okhttp: return "okhttp/4.12.0"
        }
    }

    public var displayName: String {
        switch self {
        case .minuit: return "Minuit (par défaut)"
        case .vlc: return "Compatible VLC"
        case .okhttp: return "Compatible Android"
        }
    }
}
