import Foundation
import Security

/// Protocol for secure credential storage, enabling injection and testing without Keychain access.
protocol SecureStorageProtocol: Sendable {
    /// Passwords are keyed by the saved account's id (pi 1001d): host+username collided for two
    /// databases on one host with the same username.
    func savePassword(accountId: String, password: String)
    func getPassword(accountId: String) -> String?
    func deletePassword(accountId: String)
    func migratePasswordKeys(accounts: [OdooAccount])

    /// Session ids are keyed by the saved account's id (pi 1001c): host+username collided for two
    /// databases on one host with the same username.
    func saveSessionId(accountId: String, sessionId: String)
    func getSessionId(accountId: String) -> String?
    func deleteSessionId(accountId: String)
    func migrateSessionKeys(accounts: [OdooAccount])
}

/// Keychain-backed secure storage for passwords, PIN hash, FCM token, and settings.
/// Replaces Android's EncryptedSharedPreferences.
///
/// All data stored with:
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (passwords, PIN)
/// - `kSecAttrSynchronizable: false` (no iCloud sync)
final class SecureStorage: SecureStorageProtocol, PushCredentialStorage, Sendable {

    static let shared = SecureStorage()

    private let service: String

    /// `service` is the Keychain service the items live under; tests pass their own so they never
    /// touch the app's items.
    init(service: String = AppBrand.current.keychainService) {
        self.service = service
    }

#if DEBUG
    // MARK: - Legacy-key test hooks (pi 1001e: upgrade scenarios through the real Keychain)

    func saveLegacyCredentialForTesting(serverUrl: String, username: String, password: String?, sessionId: String?) {
        if let password { _ = save(key: legacyPasswordKey(serverUrl: serverUrl, username: username), value: password) }
        if let sessionId { _ = save(key: legacySessionKey(serverUrl: serverUrl, username: username), value: sessionId) }
    }

    func legacyCredentialForTesting(serverUrl: String, username: String) -> (password: String?, sessionId: String?) {
        (get(key: legacyPasswordKey(serverUrl: serverUrl, username: username)),
         get(key: legacySessionKey(serverUrl: serverUrl, username: username)))
    }

    func deleteLegacyCredentialForTesting(serverUrl: String, username: String) {
        delete(key: legacyPasswordKey(serverUrl: serverUrl, username: username))
        delete(key: legacySessionKey(serverUrl: serverUrl, username: username))
    }
#endif

    // MARK: - Password Storage (per saved account)

    /// pi 1001d: a password is keyed by the saved account's id. The former key
    /// (`pwd_{host}_{username}`) collided when one host served two databases (or ports) with the
    /// same username, so switching to one account authenticated with the other's password.
    private func passwordKey(accountId: String) -> String { "pwd_acct_\(accountId)" }

    /// The former keys, read only by ``migratePasswordKeys(accounts:)``.
    private func legacyPasswordKey(serverUrl: String, username: String) -> String {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        return "pwd_\(host)_\(username)"
    }

    /// Saves one saved account's password.
    func savePassword(accountId: String, password: String) {
        guard !accountId.isEmpty else { return }
        save(key: passwordKey(accountId: accountId), value: password)
    }

    /// Retrieves one saved account's password.
    func getPassword(accountId: String) -> String? {
        guard !accountId.isEmpty else { return nil }
        return get(key: passwordKey(accountId: accountId))
    }

    /// Deletes one saved account's password.
    func deletePassword(accountId: String) {
        guard !accountId.isEmpty else { return }
        delete(key: passwordKey(accountId: accountId))
    }

    /// Moves each legacy password — `pwd_{host}_{username}`, or the oldest `pwd_{username}` — to its
    /// account's key. A legacy key that two or more saved accounts map to (same host and username,
    /// different databases or ports) cannot say whose password it was: it is dropped, not guessed —
    /// that account asks for its password again. Idempotent: legacy keys are deleted once processed.
    func migratePasswordKeys(accounts: [OdooAccount]) {
        for (legacyKey, owners) in Dictionary(grouping: accounts, by: { legacyPasswordKey(serverUrl: $0.fullServerUrl, username: $0.username) }) {
            guard let legacy = get(key: legacyKey) else { continue }
            if owners.count == 1, let owner = owners.first, getPassword(accountId: owner.id) == nil {
                savePassword(accountId: owner.id, password: legacy)
            }
            delete(key: legacyKey)
        }
        for (legacyKey, owners) in Dictionary(grouping: accounts, by: { "pwd_\($0.username)" }) {
            guard let legacy = get(key: legacyKey) else { continue }
            if owners.count == 1, let owner = owners.first, getPassword(accountId: owner.id) == nil {
                savePassword(accountId: owner.id, password: legacy)
            }
            delete(key: legacyKey)
        }
    }

    // MARK: - Session Cookie Storage (per saved account)

    /// pi 1001c: the session_id copy is keyed by the saved account's id. The former key
    /// (`session_{host}_{username}`) collided when one host served two databases with the same
    /// username, so one account's session was read, replaced or revoked as the other's.
    private func sessionKey(accountId: String) -> String { "session_acct_\(accountId)" }

    /// The former host+username key, read only by ``migrateSessionKeys(accounts:)``.
    private func legacySessionKey(serverUrl: String, username: String) -> String {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        return "session_\(host)_\(username)"
    }

    /// Saves the Odoo session_id cookie value to Keychain for one saved account.
    /// Storing the session in Keychain (hardware-backed, excluded from backups) instead of
    /// relying solely on HTTPCookieStorage (plaintext on disk) prevents session hijacking via
    /// backup extraction, MDM forensics tools, and jailbroken device file access.
    func saveSessionId(accountId: String, sessionId: String) {
        guard !accountId.isEmpty else { return }
        save(key: sessionKey(accountId: accountId), value: sessionId)
    }

    /// Retrieves the stored session_id for one saved account from Keychain.
    func getSessionId(accountId: String) -> String? {
        guard !accountId.isEmpty else { return nil }
        return get(key: sessionKey(accountId: accountId))
    }

    /// Deletes one saved account's session_id. Call on logout so the session cannot be reused.
    func deleteSessionId(accountId: String) {
        guard !accountId.isEmpty else { return }
        delete(key: sessionKey(accountId: accountId))
    }

    /// Moves each legacy host+username session copy to its account's key. A legacy key shared by
    /// two or more saved accounts (same host and username, different databases) cannot say whose
    /// session it was: it is dropped, not guessed — that account signs in again or self-heals.
    /// Idempotent: legacy keys are deleted once processed.
    func migrateSessionKeys(accounts: [OdooAccount]) {
        let groups = Dictionary(grouping: accounts) { legacySessionKey(serverUrl: $0.fullServerUrl, username: $0.username) }
        for (legacyKey, owners) in groups {
            guard let legacy = get(key: legacyKey) else { continue }
            if owners.count == 1, let owner = owners.first, getSessionId(accountId: owner.id) == nil {
                saveSessionId(accountId: owner.id, sessionId: legacy)
            }
            delete(key: legacyKey)
        }
    }

    // MARK: - Account-ID scoped Apporo push credentials

    @MainActor func pushCredential(accountId: String) -> PushCredential? {
        guard let value = get(key: "push_account_\(accountId)"),
              let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PushCredential.self, from: data)
    }

    @MainActor func savePushCredential(_ credential: PushCredential) {
        guard let data = try? JSONEncoder().encode(credential),
              let value = String(data: data, encoding: .utf8) else { return }
        save(key: "push_account_\(credential.accountId)", value: value)
    }

    @MainActor func deletePushCredential(accountId: String) {
        delete(key: "push_account_\(accountId)")
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

    // MARK: - Location Enabled Flag

    /// Keychain account key for the location-enabled preference.
    /// Stored as a standalone "true"/"false" string alongside the full settings JSON blob
    /// so it can be read in isolation without decoding the entire settings object.
    let locationEnabledKey = "location_enabled"

    /// Saves the location-enabled preference to Keychain.
    func saveLocationEnabled(_ enabled: Bool) {
        save(key: locationEnabledKey, value: enabled ? "true" : "false")
    }

    /// Reads the location-enabled preference from Keychain.
    /// Returns `true` (opt-in default) when no value has been stored yet.
    func getLocationEnabled() -> Bool {
        guard let raw = get(key: locationEnabledKey) else { return true }
        return raw == "true"
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
            AppLogger.data.error("SecureStorage failed to save key=\(key): OSStatus \(status, privacy: .public)")
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
