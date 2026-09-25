//
//  TestDoubles.swift
//  odooTests
//
//  Shared mock objects used across the auto-login / deep-link unit test suite.
//

import Foundation
@testable import odoo

// MARK: - MockAccountRepository

/// In-memory stub conforming to `AccountRepositoryProtocol`.
/// Returns pre-configured values without touching Core Data or the network.
final class MockAccountRepository: AccountRepositoryProtocol, @unchecked Sendable {

    /// The account returned by `getActiveAccount()`. Set to non-nil to simulate a logged-in user.
    var stubbedActiveAccount: OdooAccount? = nil

    /// The result returned by `authenticate(...)`. Defaults to an `.error` so tests must
    /// explicitly opt in to the success path.
    var stubbedAuthResult: AuthResult = .error("stub", .unknown)

    /// The result returned by `switchAccount(id:)`. Defaults to `false` so tests must
    /// explicitly opt in to a successful switch.
    var stubbedSwitchResult: Bool = false

    /// Accounts resolvable by tenant id via `getAccount(byTenantId:)`.
    var stubbedTenantAccounts: [String: OdooAccount] = [:]

    /// Records ids passed to `activateAccount(id:)`, most-recent last.
    private(set) var activatedAccountIds: [String] = []

    func getActiveAccount() -> OdooAccount? { stubbedActiveAccount }

    func getAllAccounts() -> [OdooAccount] { [] }

    func getAccount(byTenantId tenantId: String) -> OdooAccount? {
        tenantId.isEmpty ? nil : stubbedTenantAccounts[tenantId]
    }

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        stubbedAuthResult
    }

    func switchAccount(id: String) async -> Bool { stubbedSwitchResult }

    func activateAccount(id: String) -> Bool {
        activatedAccountIds.append(id)
        return true
    }

    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) {}

    /// 記錄以 account id 回寫的 tenant，供 FCM 註冊路徑的歸屬斷言使用。
    private(set) var tenantWritesByAccountId: [String: String] = [:]

    func setTenantId(_ tenantId: String, forAccountId accountId: String) {
        tenantWritesByAccountId[accountId] = tenantId
    }

    func logout(accountId: String?) async {}

    func removeAccount(id: String) async {}

    func getSessionId(for serverUrl: String) -> String? { nil }
}

// MARK: - MockSecureStorage

/// In-memory stub conforming to `SecureStorageProtocol`.
/// Stores passwords in a plain dictionary — no Keychain access required.
final class MockSecureStorage: SecureStorageProtocol, @unchecked Sendable {

    /// Internal dictionary keyed as `"pwd_{host}_{username}"`, matching SecureStorage's scoped format (H6).
    var store: [String: String] = [:]

    func savePassword(serverUrl: String, username: String, password: String) {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        store["pwd_\(host)_\(username)"] = password
    }

    func getPassword(serverUrl: String, username: String) -> String? {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        return store["pwd_\(host)_\(username)"]
    }

    func deletePassword(serverUrl: String, username: String) {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        store.removeValue(forKey: "pwd_\(host)_\(username)")
    }

    func migratePasswordKeys(accounts: [OdooAccount]) {
        // No-op in mock — migration only applies to real Keychain
    }

    // H3: Session cookie storage
    func saveSessionId(serverUrl: String, username: String, sessionId: String) {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        store["session_\(host)_\(username)"] = sessionId
    }

    func getSessionId(serverUrl: String, username: String) -> String? {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        return store["session_\(host)_\(username)"]
    }

    func deleteSessionId(serverUrl: String, username: String) {
        let host = URL(string: serverUrl)?.host ?? serverUrl
        store.removeValue(forKey: "session_\(host)_\(username)")
    }
}

// MARK: - MockPushTokenRepository

/// In-memory stub conforming to `PushTokenRepositoryProtocol`.
///
/// Records every `registerTokenWithAllAccounts` / `unregisterToken` call so a test can
/// assert that an event-driven reconcile (token-arrived, account-restored, login, switch)
/// upserted the current token — without any real network / DNS. The reconcile triggers run
/// on a detached `Task`, so `onRegister` lets a test `fulfill` an expectation and await it
/// deterministically.
final class MockPushTokenRepository: PushTokenRepositoryProtocol, @unchecked Sendable {
    // Non-isolated async protocol calls can execute concurrently even when the test is
    // @MainActor. Protect every mutable field; @unchecked Sendable alone is not a lock.
    private let lock = NSLock()
    private var token: String?
    private var registrations: [String] = []
    private var unregistrations: [String] = []
    private var registrationCallback: (@Sendable () -> Void)?

    var storedToken: String? {
        get { synchronized { token } }
        set { synchronized { token = newValue } }
    }

    /// Snapshots ordered by the lock's serialization of calls.
    var registeredTokens: [String] { synchronized { registrations } }
    var unregisteredServerUrls: [String] { synchronized { unregistrations } }

    var onRegister: (@Sendable () -> Void)? {
        get { synchronized { registrationCallback } }
        set { synchronized { registrationCallback = newValue } }
    }

    init(storedToken: String? = nil) {
        token = storedToken
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func saveToken(_ token: String) { storedToken = token }
    func getToken() -> String? { storedToken }

    func registerTokenWithAllAccounts(_ token: String) async {
        let callback = synchronized {
            registrations.append(token)
            return registrationCallback
        }
        // A callback may re-enter the mock. Invoke it after releasing the lock, but
        // only after publishing the corresponding registration to snapshot readers.
        callback?()
    }

    func unregisterToken(for serverUrl: String) async {
        synchronized { unregistrations.append(serverUrl) }
    }
}
