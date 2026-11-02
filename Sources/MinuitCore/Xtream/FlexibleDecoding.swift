import Foundation

// Les panneaux Xtream (et leurs clones) renvoient le même champ sous des types
// différents selon la version : `"1"`, `1`, `true`, `null`, `""`… Ces enveloppes
// absorbent ces variantes au lieu de faire échouer tout le décodage d'une liste
// de plusieurs milliers de chaînes pour un seul champ mal typé.

/// Chaîne tolérante : accepte chaîne, nombre, booléen ou null.
public struct LenientString: Decodable, Sendable, Hashable {
    public let value: String?

    public init(_ value: String?) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = nil; return }
        if let string = try? container.decode(String.self) { value = string; return }
        if let int = try? container.decode(Int64.self) { value = String(int); return }
        if let double = try? container.decode(Double.self) { value = String(double); return }
        if let bool = try? container.decode(Bool.self) { value = bool ? "1" : "0"; return }
        value = nil
    }

    /// Valeur non vide, sinon nil.
    public var nonEmpty: String? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }
}

/// Entier tolérant : accepte `12`, `"12"`, `"12.0"`, `true`, null.
public struct LenientInt: Decodable, Sendable, Hashable {
    public let value: Int?

    public init(_ value: Int?) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = nil; return }
        if let int = try? container.decode(Int.self) { value = int; return }
        if let double = try? container.decode(Double.self) { value = Int(exactly: double.rounded()) ; return }
        if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if let int = Int(trimmed) { value = int; return }
            if let double = Double(trimmed), double.isFinite { value = Int(double); return }
            value = nil; return
        }
        if let bool = try? container.decode(Bool.self) { value = bool ? 1 : 0; return }
        value = nil
    }
}

/// Booléen tolérant : `1`, `"1"`, `true`, `"true"`, `"yes"`.
public struct LenientBool: Decodable, Sendable, Hashable {
    public let value: Bool

    public init(_ value: Bool) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = false; return }
        if let bool = try? container.decode(Bool.self) { value = bool; return }
        if let int = try? container.decode(Int.self) { value = int != 0; return }
        if let string = try? container.decode(String.self) {
            value = ["1", "true", "yes", "on"].contains(string.lowercased().trimmingCharacters(in: .whitespaces))
            return
        }
        value = false
    }
}

/// Tableau tolérant : un élément invalide est ignoré au lieu d'invalider la liste.
public struct LossyArray<Element: Decodable>: Decodable {
    public let elements: [Element]
    public let droppedCount: Int

    public init(from decoder: Decoder) throws {
        // Certains panneaux renvoient un objet `{}` ou `false` au lieu d'un tableau vide.
        guard var container = try? decoder.unkeyedContainer() else {
            elements = []
            droppedCount = 0
            return
        }
        var result: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                dropped += 1
                // Avance d'un élément même s'il n'est pas décodable.
                _ = try? container.decode(AnyDecodable.self)
            }
        }
        elements = result
        droppedCount = dropped
    }
}

/// Consomme n'importe quelle valeur JSON.
struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd { _ = try? unkeyed.decode(AnyDecodable.self) }
            return
        }
        if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in keyed.allKeys { _ = try? keyed.decode(AnyDecodable.self, forKey: key) }
            return
        }
        _ = try? decoder.singleValueContainer()
    }
}

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(LenientString.self, forKey: key))??.nonEmpty
    }
    func lenientInt(_ key: Key) -> Int? {
        (try? decodeIfPresent(LenientInt.self, forKey: key))??.value
    }
    func lenientBool(_ key: Key) -> Bool {
        (try? decodeIfPresent(LenientBool.self, forKey: key))??.value ?? false
    }
}
