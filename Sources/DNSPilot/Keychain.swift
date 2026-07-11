import Foundation
import Security

/// Stockage du mot de passe AdGuard Home dans le trousseau de session
/// (jamais dans profiles.json). Une entrée par profil, identifiée par son UUID.
///
/// Note signature ad hoc : chaque rebuild change l'identité de code, macOS peut
/// donc redemander l'accès au trousseau après une mise à jour de l'app
/// (« Toujours autoriser » règle la question jusqu'au rebuild suivant).
enum Keychain {

    private static let service = "DNS Pilot — AdGuard Home"

    /// Compte unique de l'instance AdGuard Home (config globale).
    static let adguardAccount = "adguard-home"

    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, account: String) {
        deletePassword(account: account)
        guard !password.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("DNSPilot: échec d'écriture dans le trousseau (%d)", status)
        }
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
