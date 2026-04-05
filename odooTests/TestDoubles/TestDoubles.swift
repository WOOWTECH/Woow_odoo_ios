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

    func getActiveAccount() -> OdooAccount? { stubbedActiveAccount }

    func getAllAccounts() -> [OdooAccount] { [] }

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        stubbedAuthResult
    }

    func switchAccount(id: String) async -> Bool { false }

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
