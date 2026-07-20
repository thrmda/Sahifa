import Foundation
import Security

/// The one place a secret is allowed to live.
///
/// Tokens never go into UserDefaults, a file, or the repository — only the
/// harmless parts (which account, when it expires) are stored as ordinary
/// preferences so the Settings pane can show them without unlocking anything.
enum Keychain {
    /// Namespaced so the item is obviously ours in Keychain Access, and so a
    /// second service later doesn't collide with this one.
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "me.alangari.Sahifa.credentials",
         kSecAttrAccount as String: account]
    }

    static func set(_ secret: String, for account: String) {
        guard let data = secret.data(using: .utf8) else { return }
        // Replace rather than add: SecItemAdd fails on an existing item, and
        // reconnecting an account is the common case.
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        // Available once the Mac has been unlocked, and never synced to other
        // devices or included in a backup.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        var attributes = query(account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
