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

    /// Story 10-1: fakes default to "not ambiguous" — these suites predate the ambiguity
    /// concept and assert routing outcomes, not drop-reason discrimination. The tests that
    /// DO exercise ambiguity supply their own closure.
    func isTenantIdAmbiguous(_ tenantId: String) -> Bool { false }


    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        stubbedAuthResult
    }

    func switchAccount(id: String) async -> Bool { stubbedSwitchResult }

    func activateAccount(id: String) -> Bool {
        activatedAccountIds.append(id)
        return true
    }

    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) {}

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

    /// The token returned by `getToken()`. Set this to simulate a token Firebase already
    /// delivered (possibly BEFORE any account existed — the AC8.b race).
    var storedToken: String?

    /// Every token passed to `registerTokenWithAllAccounts`, in call order.
    private(set) var registeredTokens: [String] = []

    /// Every server URL passed to `unregisterToken(for:)`, in call order.
    private(set) var unregisteredServerUrls: [String] = []

    /// Invoked at the end of each `registerTokenWithAllAccounts` call so a test can
    /// fulfill an `XCTestExpectation` and await the detached reconcile Task.
    var onRegister: (@Sendable () -> Void)?

    init(storedToken: String? = nil) {
        self.storedToken = storedToken
    }

    func saveToken(_ token: String) { storedToken = token }

    func getToken() -> String? { storedToken }

    func registerTokenWithAllAccounts(_ token: String) async {
        registeredTokens.append(token)
        onRegister?()
    }

    func unregisterToken(for serverUrl: String) async {
        unregisteredServerUrls.append(serverUrl)
    }
}
