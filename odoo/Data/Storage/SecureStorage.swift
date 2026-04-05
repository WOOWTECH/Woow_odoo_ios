import Foundation
import Security

/// Protocol for secure credential storage, enabling injection and testing without Keychain access.
protocol SecureStorageProtocol: Sendable {
    func savePassword(accountId: String, password: String)
    func getPassword(accountId: String) -> String?
    func deletePassword(accountId: String)
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

    // MARK: - Password Storage (per account)

    /// Saves an encrypted password for an account.
    func savePassword(accountId: String, password: String) {
        save(key: "pwd_\(accountId)", value: password)
    }

    /// Retrieves the password for an account.
    func getPassword(accountId: String) -> String? {
        get(key: "pwd_\(accountId)")
    }

    /// Deletes the password for an account.
    func deletePassword(accountId: String) {
        delete(key: "pwd_\(accountId)")
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
