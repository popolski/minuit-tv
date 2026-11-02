import Foundation
import Security
import MinuitCore

/// Stockage des identifiants Xtream dans le trousseau (Keychain).
///
/// Pas de groupe d'accès explicite : atvloadly re-signe l'application et modifie
/// l'identifiant de bundle ; un groupe codé en dur ne correspondrait plus.
/// Accessibilité `AfterFirstUnlock` : l'Apple TV n'a pas de verrouillage, et la
/// reconnexion automatique doit fonctionner après un redémarrage.
struct KeychainCredentialStore {
    private let service = "minuit.xtream"
    private let account = "primary"

    enum KeychainError: Error { case unexpectedStatus(OSStatus), encoding }

    func load() -> XtreamCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(XtreamCredentials.self, from: data)
    }

    func save(_ credentials: XtreamCredentials) throws {
        guard let data = try? JSONEncoder().encode(credentials) else { throw KeychainError.encoding }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert.merge(attributes) { $1 }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
