import Foundation
import Security

/// The one place a secret is allowed to live.
///
/// Tokens never go into UserDefaults, a file, or the repository — only the
/// harmless parts (which account, when it expires) are stored as ordinary
/// preferences so the Settings pane can show them without unlocking anything.
///
/// Worth knowing: the sandbox does NOT give the app a private keychain. An
/// item written here is the same item any other process running as this user
/// can address by service and account name — which is how a test once deleted
/// a real credential. Anything reaching this type in a test must therefore
/// pass its own throwaway account name (see `GitHubAccount.init`).
enum Keychain {
    /// Namespaced so the item is obviously ours in Keychain Access, and so a
    /// second service later doesn't collide with this one.
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "me.alangari.Sahifa.credentials",
         kSecAttrAccount as String: account]
    }

    /// Returns whether the secret was actually stored.
    ///
    /// The result is checked by callers on purpose. An earlier version ignored
    /// it, and when the write failed the app went on reporting a connected
    /// account until the next launch, when the credential simply wasn't there
    /// — a silent failure that looked like the app forgetting its settings.
    @discardableResult
    static func set(_ secret: String, for account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        // Replace rather than add: SecItemAdd refuses an existing item, and
        // reconnecting an account is the common case.
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        // Available once the Mac has been unlocked, and never synced to other
        // devices or included in a backup.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
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
