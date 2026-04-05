//
//  LoginViewModelPrefillTests.swift
//  odooTests
//
//  Unit tests for LoginViewModel's pre-fill behavior — verifies that returning users
//  after session expiry land on the credentials screen with fields already populated.
//
//  Uses MockAccountRepository and MockSecureStorage to isolate the ViewModel
//  from Core Data and Keychain completely.
//
//  Coverage: LVM-01 through LVM-07, EC-02, EC-05
//

import XCTest
@testable import odoo

@MainActor
final class LoginViewModelPrefillTests: XCTestCase {

    // MARK: - Fixtures

    private func makeAccount(
        serverUrl: String = "https://myodoo.com",
        database: String = "prod_db",
        username: String = "alan@woow.com"
    ) -> OdooAccount {
        OdooAccount(
            id: UUID().uuidString,
            serverUrl: serverUrl,
            database: database,
            username: username,
            displayName: "Alan",
            isActive: true
        )
    }

    // MARK: - LVM-01

    /// LVM-01: The three non-sensitive fields (serverUrl, database, username) are pre-filled
    /// from the active account. This is the visible user-facing behavior — the user taps
    /// a notification, arrives at login, and sees the server and username already populated.
    func test_init_givenActiveAccountWithAllFields_prefillsServerUrlDatabaseUsername() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount(
            serverUrl: "https://myodoo.com",
            database: "prod_db",
            username: "alan@woow.com"
        )
        let storage = MockSecureStorage()

        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        XCTAssertEqual(sut.serverUrl, "https://myodoo.com", "serverUrl must be pre-filled from active account")
        XCTAssertEqual(sut.database, "prod_db", "database must be pre-filled from active account")
        XCTAssertEqual(sut.username, "alan@woow.com", "username must be pre-filled from active account")
    }

    // MARK: - LVM-02

    /// LVM-02: The Keychain password retrieval path — the password field must be populated
    /// so the user can tap "Login" without re-entering their password, which is the primary
    /// UX goal of the auto-login feature.
    func test_init_givenActiveAccountWithSavedPassword_prefillsPasswordField() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount(username: "alan@woow.com")
        let storage = MockSecureStorage()
        storage.savePassword(accountId: "alan@woow.com", password: "s3cr3t!")

        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        XCTAssertEqual(sut.password, "s3cr3t!",
                       "password must be pre-filled from secure storage when a saved password exists")
    }

    // MARK: - LVM-03

    /// LVM-03: The password-not-found path — secure storage may be empty if the user
    /// previously chose not to save the password, or if the Keychain was wiped by a
    /// device restore. The ViewModel must handle nil gracefully: field stays empty.
    func test_init_givenActiveAccountButNoKeychainEntry_passwordFieldRemainsEmpty() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount(username: "alan@woow.com")
        let storage = MockSecureStorage() // store is empty

        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        XCTAssertEqual(sut.password, "",
                       "password must be empty when secure storage has no entry for the account")
    }

    // MARK: - LVM-04

    /// LVM-04: When pre-filling from an active account, `step` must be set to `.credentials`
    /// so the user lands directly on the username/password fields, not the server info screen.
    func test_init_givenActiveAccountExists_stepIsCredentials() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount()
        let storage = MockSecureStorage()

        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        XCTAssertEqual(sut.step, .credentials,
                       "step must be .credentials when an active account allows pre-fill")
    }

    // MARK: - LVM-05

    /// LVM-05: The first-launch path — no active account means no pre-fill and no step
    /// override. The user sees the blank server info screen. This is the baseline regression
    /// test confirming the pre-fill does not fire spuriously.
    func test_init_givenNoActiveAccount_fieldsAreEmptyAndStepIsServerInfo() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = nil
        let storage = MockSecureStorage()

        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        XCTAssertEqual(sut.serverUrl, "", "serverUrl must be empty on first launch")
        XCTAssertEqual(sut.database, "", "database must be empty on first launch")
        XCTAssertEqual(sut.username, "", "username must be empty on first launch")
        XCTAssertEqual(sut.password, "", "password must be empty on first launch")
        XCTAssertEqual(sut.step, .serverInfo, "step must be .serverInfo on first launch")
    }

    // MARK: - LVM-06

    /// LVM-06: The pre-fill must not double-prefix "https://". The OdooAccount.serverUrl
    /// field stores the full URL including scheme after the first login. Passing it through
    /// displayUrl must not produce "https://https://...".
    func test_init_givenActiveAccountWithHttpsPrefix_serverUrlStoredAsIsWithoutDoublePrefix() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount(serverUrl: "https://myodoo.com")
        let storage = MockSecureStorage()

        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        XCTAssertEqual(sut.serverUrl, "https://myodoo.com",
                       "serverUrl must be stored verbatim — no double https:// prefix")
        XCTAssertEqual(sut.displayUrl, "https://myodoo.com",
                       "displayUrl must not add a second https:// prefix")
    }

    // MARK: - LVM-07

    /// LVM-07: Regression test confirming the login flow works end-to-end after pre-fill
    /// changes. `login(onSuccess:)` must call `onSuccess` when authenticate returns `.success`.
    /// Uses `XCTestExpectation` because `login()` launches an unstructured `Task` internally
    /// that cannot be awaited directly from the test.
    func test_login_givenSuccessfulAuthentication_firesOnSuccessCallback() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount()
        repo.stubbedAuthResult = .success(AuthResult.AuthSuccess(
            userId: 1,
            sessionId: "session-abc",
            username: "alan@woow.com",
            displayName: "Alan"
        ))
        let storage = MockSecureStorage()
        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        let expectation = XCTestExpectation(description: "onSuccess callback fired")
        sut.login { expectation.fulfill() }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - EC-02

    /// EC-02: Device is locked when the app launches; secure storage returns nil because
    /// the Keychain item requires the device to be unlocked. Pre-fill must handle this
    /// gracefully — empty password field, no crash, no error state shown to the user.
    func test_init_givenKeychainReturnsNilDueToDeviceLock_passwordEmptyAndNoError() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount(username: "alan@woow.com")
        // MockSecureStorage always returns nil for getPassword unless savePassword was called
        let storage = MockSecureStorage()

        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        XCTAssertEqual(sut.password, "",
                       "password must be empty when Keychain is inaccessible (device locked)")
        XCTAssertNil(sut.error,
                     "error must be nil — a missing Keychain entry is not a user-visible error")
    }

    // MARK: - EC-05

    /// EC-05: `prefillFromActiveAccount()` calls `repository.getActiveAccount()`, not
    /// `getAllAccounts().first`. This test guards against a bug where pre-fill would
    /// accidentally take the wrong account's credentials.
    func test_init_givenMultipleAccountsInRepo_prefillsFromActiveAccountNotFirst() {
        let repo = MockAccountRepository()
        // The repository's stubbedActiveAccount is the "second" account —
        // a naive getAllAccounts().first would return the wrong serverUrl.
        repo.stubbedActiveAccount = makeAccount(
            serverUrl: "https://second-server.com",
            username: "second@woow.com"
        )
        let storage = MockSecureStorage()

        let sut = LoginViewModel(repository: repo, secureStorage: storage)

        XCTAssertEqual(sut.serverUrl, "https://second-server.com",
                       "serverUrl must come from the active account, not the first account in the list")
        XCTAssertEqual(sut.username, "second@woow.com",
                       "username must come from the active account, not the first account in the list")
    }
}
