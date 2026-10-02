//
//  SecureStorageKeyMigrationTests.swift
//  odooTests
//
//  pi 1001e (P2): migrating a legacy host+username password/session key to the account-id key must
//  delete the legacy key only after the new key was written AND read back. A failed Keychain write
//  keeps the legacy key so the next launch retries; nothing is lost. Runs against the real Keychain
//  under a per-test service so the app's items are never touched.
//

import XCTest
@testable import odoo

final class SecureStorageKeyMigrationTests: XCTestCase {

    private var service = ""
    private let server = "https://legacy.example.com"
    private lazy var account = OdooAccount(id: "acct-legacy-\(UUID().uuidString.prefix(6))", serverUrl: server,
                                           database: "db", username: "tester", displayName: "Tester")

    override func setUp() {
        super.setUp()
        service = "odoo.tests.migration.\(UUID().uuidString)"
    }

    override func tearDown() {
        let store = SecureStorage(service: service)
        store.deleteLegacyCredentialForTesting(serverUrl: server, username: "tester")
        store.deletePassword(accountId: account.id)
        store.deleteSessionId(accountId: account.id)
        super.tearDown()
    }

    func test_savePassword_givenKeychainWriteFailure_reportsFailure() {
        let failing = SecureStorage(service: service, writeFails: { $0.hasPrefix("pwd_acct_") })
        XCTAssertFalse(failing.savePassword(accountId: account.id, password: "pw"))
        XCTAssertNil(failing.getPassword(accountId: account.id))
        XCTAssertTrue(SecureStorage(service: service).savePassword(accountId: account.id, password: "pw"))
    }

    func test_passwordMigration_givenAccountKeyWriteFails_keepsLegacyKeyAndRetriesNextLaunch() {
        let failing = SecureStorage(service: service, writeFails: { $0.hasPrefix("pwd_acct_") })
        failing.saveLegacyCredentialForTesting(serverUrl: server, username: "tester", password: "pw-legacy", sessionId: nil)

        failing.migratePasswordKeys(accounts: [account])

        XCTAssertEqual(failing.legacyCredentialForTesting(serverUrl: server, username: "tester").password, "pw-legacy",
                       "a failed write must not delete the only copy")
        XCTAssertNil(failing.getPassword(accountId: account.id))

        let nextLaunch = SecureStorage(service: service)
        nextLaunch.migratePasswordKeys(accounts: [account])

        XCTAssertEqual(nextLaunch.getPassword(accountId: account.id), "pw-legacy", "the retry moves it")
        XCTAssertNil(nextLaunch.legacyCredentialForTesting(serverUrl: server, username: "tester").password,
                     "the legacy key is deleted once the account key is verified")
    }

    func test_sessionMigration_givenAccountKeyWriteFails_keepsLegacyKeyAndRetriesNextLaunch() {
        let failing = SecureStorage(service: service, writeFails: { $0.hasPrefix("session_acct_") })
        failing.saveLegacyCredentialForTesting(serverUrl: server, username: "tester", password: nil, sessionId: "sid-legacy")

        failing.migrateSessionKeys(accounts: [account])

        XCTAssertEqual(failing.legacyCredentialForTesting(serverUrl: server, username: "tester").sessionId, "sid-legacy")
        XCTAssertNil(failing.getSessionId(accountId: account.id))

        let nextLaunch = SecureStorage(service: service)
        nextLaunch.migrateSessionKeys(accounts: [account])

        XCTAssertEqual(nextLaunch.getSessionId(accountId: account.id), "sid-legacy")
        XCTAssertNil(nextLaunch.legacyCredentialForTesting(serverUrl: server, username: "tester").sessionId)
    }

    func test_migration_givenAmbiguousLegacyKey_dropsItWithoutGuessing() {
        let other = OdooAccount(id: "acct-other-\(UUID().uuidString.prefix(6))", serverUrl: server,
                                database: "db2", username: "tester", displayName: "Tester db2")
        let store = SecureStorage(service: service)
        store.saveLegacyCredentialForTesting(serverUrl: server, username: "tester", password: "pw-shared", sessionId: "sid-shared")

        store.migratePasswordKeys(accounts: [account, other])
        store.migrateSessionKeys(accounts: [account, other])

        let legacy = store.legacyCredentialForTesting(serverUrl: server, username: "tester")
        XCTAssertNil(legacy.password); XCTAssertNil(legacy.sessionId)
        for id in [account.id, other.id] {
            XCTAssertNil(store.getPassword(accountId: id)); XCTAssertNil(store.getSessionId(accountId: id))
        }
        store.deletePassword(accountId: other.id); store.deleteSessionId(accountId: other.id)
    }
}
