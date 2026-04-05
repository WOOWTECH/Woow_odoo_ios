import Foundation
import Security

/// Protocol for secure credential storage, enabling injection and testing without Keychain access.
protocol SecureStorageProtocol: Sendable {
    func savePassword(serverUrl: String, username: String, password: String)
    func getPassword(serverUrl: String, username: String) -> String?
    func deletePassword(serverUrl: String, username: String)
    func migratePasswordKeys(accounts: [OdooAccount])
}

/// Keychain-backed secure storage for passwords, PIN hash, FCM token, and settings.
/// Replaces Android's EncryptedSharedPreferences.
///
/// All data stored with:
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (passwords, PIN)
/// - `kSecAttrSynchronizable: false` (no iCloud sync)
final class SecureStorage: SecureStorageProtocol, Sendable {

    static let shared = SecureStorage()

    private let service = "io.woowtech.odoo.keychain"

    // MARK: - Password Storage (per account, scoped to server host)

    /// Builds a Keychain key scoped to both the server host and username, preventing
    /// credential collisions when the same username exists on multiple Odoo servers.
    /// Uses only the hostname component (e.g. "company.odoo.com") to keep the key clean.
    private func passwordKey(serverUrl: String, username: String) -> String {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        return "pwd_\(host)_\(username)"
    }

    /// Saves a password scoped to a specific server and username.
    func savePassword(serverUrl: String, username: String, password: String) {
        save(key: passwordKey(serverUrl: serverUrl, username: username), value: password)
    }

    /// Retrieves the password for a specific server and username combination.
    func getPassword(serverUrl: String, username: String) -> String? {
        get(key: passwordKey(serverUrl: serverUrl, username: username))
    }

    /// Deletes the password for a specific server and username combination.
    func deletePassword(serverUrl: String, username: String) {
        delete(key: passwordKey(serverUrl: serverUrl, username: username))
    }

    /// Migrates legacy Keychain keys from the old format `pwd_{username}` to the
    /// server-scoped format `pwd_{host}_{username}`. Safe to call multiple times —
    /// already-migrated entries are skipped because the old key no longer exists
    /// after the first successful migration.
    func migratePasswordKeys(accounts: [OdooAccount]) {
        for account in accounts {
            let legacyKey = "pwd_\(account.username)"
            let newKey = passwordKey(serverUrl: account.fullServerUrl, username: account.username)

            // Skip if the new key already exists, or if there is nothing to migrate
            guard get(key: newKey) == nil,
                  let existingPassword = get(key: legacyKey) else { continue }

            save(key: newKey, value: existingPassword)
            delete(key: legacyKey)
        }
    }

    // MARK: - PIN Hash

    /// Saves the PBKDF2 PIN hash (salt:hash format).
    func savePinHash(_ hash: String) {
        save(key: "pin_hash", value: hash)
    }

    /// Retrieves the stored PIN hash.
    func getPinHash() -> String? {
        get(key: "pin_hash")
    }

    /// Deletes the PIN hash.
    func deletePinHash() {
        delete(key: "pin_hash")
    }

    // MARK: - FCM Token

    /// Saves the FCM device token.
    func saveFcmToken(_ token: String) {
        save(key: "fcm_token", value: token)
    }

    /// Retrieves the FCM device token.
    func getFcmToken() -> String? {
        get(key: "fcm_token")
    }

    /// Deletes the FCM device token from Keychain.
    /// Called when the last account is logged out. (G9)
    func deleteFcmToken() {
        delete(key: "fcm_token")
    }

    // MARK: - App Settings

    /// Saves app settings as JSON in Keychain.
    func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings),
              let json = String(data: data, encoding: .utf8) else { return }
        save(key: "app_settings", value: json)
    }

    /// Retrieves app settings from Keychain.
    func getSettings() -> AppSettings {
        guard let json = get(key: "app_settings"),
              let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    // MARK: - Generic Keychain Operations

    /// Saves a value to Keychain using atomic update-or-add pattern.
    /// Avoids race condition from delete-then-add.
    @discardableResult
    private func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Try update first (atomic)
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        if status == errSecItemNotFound {
            // Item doesn't exist — add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse!
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess {
            #if DEBUG
            print("[SecureStorage] Failed to save key=\(key): OSStatus \(status)")
            #endif
            return false
        }
        return true
    }

    private func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
