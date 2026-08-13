import Foundation
import Security

/// API keys live in the login keychain, never in the database, the vault, or a config
/// file. The database is meant to be copyable and inspectable; a key is not.
public enum Keychain {
    static let service = "com.dunes.apikey"

    /// What the service was called before the app was renamed.
    ///
    /// A keychain item is keyed by its service string, so renaming the constant would
    /// have quietly orphaned every key already stored: `read` would return nil, the app
    /// would report "no model connected", and the real key would sit invisibly in the
    /// login keychain forever. The old name is kept only to be migrated away from.
    private static let retiredService = "com.innerjoin.apikey"

    public static func read(account: String) -> String? {
        if let current = read(account: account, from: service) { return current }
        // Nothing under the new name. If the key was stored before the rename, adopt it
        // once and forget the old name — so this costs one extra lookup exactly once,
        // and never asks the user to paste a key they already gave us.
        guard let inherited = read(account: account, from: retiredService) else { return nil }
        write(inherited, account: account)
        delete(account: account, from: retiredService)
        return inherited
    }

    private static func read(account: String, from service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func delete(account: String, from service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    @discardableResult
    public static func write(_ key: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
