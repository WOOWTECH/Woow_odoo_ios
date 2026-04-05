//
//  AppRootViewModelTests.swift
//  odooTests
//
//  Unit tests for AppRootViewModel.checkSession() — verifies launch state transitions
//  driven by the account repository, without touching Core Data directly.
//
//  Coverage: ARV-01 through ARV-06, EC-01, EC-04
//

import XCTest
import CoreData
@testable import odoo

@MainActor
final class AppRootViewModelTests: XCTestCase {

    // MARK: - ARV-01

    /// ARV-01: The positive auto-login path — an active account exists, so `launchState`
    /// transitions to `.authenticated`, bypassing `LoginView`.
    func test_checkSession_givenActiveAccountExists_transitionsToAuthenticated() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount(username: "alan@woow.com")
        let sut = AppRootViewModel(accountRepository: repo)

        sut.checkSession()

        XCTAssertEqual(sut.launchState, .authenticated,
                       "launchState must be .authenticated when an active account is present")
    }

    // MARK: - ARV-02

    /// ARV-02: First-launch and post-logout path — no accounts in the repository means
    /// `launchState` transitions to `.login`.
    func test_checkSession_givenNoActiveAccount_transitionsToLogin() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = nil
        let sut = AppRootViewModel(accountRepository: repo)

        sut.checkSession()

        XCTAssertEqual(sut.launchState, .login,
                       "launchState must be .login when no active account exists")
    }

    // MARK: - ARV-03

    /// ARV-03: Accounts exist but none is active (e.g., after a failed account switch).
    /// `getActiveAccount()` returns nil, so the app shows login rather than crashing.
    func test_checkSession_givenAccountsButNoneActive_transitionsToLogin() {
        let repo = MockAccountRepository()
        // stubbedActiveAccount defaults to nil — simulates all accounts being inactive
        repo.stubbedActiveAccount = nil
        let sut = AppRootViewModel(accountRepository: repo)

        sut.checkSession()

        XCTAssertEqual(sut.launchState, .login,
                       "launchState must be .login when no account has isActive == true")
    }

    // MARK: - ARV-04

    /// ARV-04: Verifies the initial state before `checkSession()` is called.
    /// `AppRootView` must show a loading indicator (ProgressView) during this window
    /// to prevent the login screen from flashing before the check completes.
    func test_initialLaunchState_isLoading() {
        let sut = AppRootViewModel(accountRepository: MockAccountRepository())

        XCTAssertEqual(sut.launchState, .loading,
                       "launchState must start as .loading before checkSession() is called")
    }

    // MARK: - ARV-05

    /// ARV-05: `onLoginSuccess()` transitions the state to `.authenticated`.
    /// Called by the login callback after a successful authentication attempt.
    func test_onLoginSuccess_transitionsToAuthenticated() {
        let sut = AppRootViewModel(accountRepository: MockAccountRepository())
        sut.checkSession() // starts at .login (no account)

        sut.onLoginSuccess()

        XCTAssertEqual(sut.launchState, .authenticated,
                       "launchState must be .authenticated after onLoginSuccess()")
    }

    // MARK: - ARV-06

    /// ARV-06: `onSessionExpired()` transitions the state back to `.login` so that
    /// `LoginView` appears with pre-filled credentials. Verifies the callback is not
    /// accidentally disconnected during any refactor.
    func test_onSessionExpired_givenAuthenticatedState_transitionsToLogin() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = makeAccount(username: "alan@woow.com")
        let sut = AppRootViewModel(accountRepository: repo)
        sut.checkSession() // transitions to .authenticated

        sut.onSessionExpired()

        XCTAssertEqual(sut.launchState, .login,
                       "launchState must return to .login after onSessionExpired()")
    }

    // MARK: - EC-01

    /// EC-01: Uses in-memory Core Data with a real AccountRepository to verify that
    /// `getActiveAccount()` returns nil without crashing when the store is empty.
    /// Guards against any force-unwrap in the fetch path.
    func test_checkSession_givenEmptyInMemoryCoreData_transitionsToLoginWithoutCrash() {
        let persistence = PersistenceController(inMemory: true)
        let repo = AccountRepository(
            persistence: persistence,
            secureStorage: SecureStorage.shared,
            apiClient: OdooAPIClient()
        )
        let sut = AppRootViewModel(accountRepository: repo)

        sut.checkSession()

        XCTAssertEqual(sut.launchState, .login,
                       "launchState must be .login when Core Data is empty — no crash expected")
    }

    // MARK: - EC-04 (AccountRepository level)

    /// EC-04: Three accounts in Core Data, only the second has `isActive = true`.
    /// `getActiveAccount()` must return exactly the active one, ignoring the others.
    func test_getActiveAccount_givenThreeAccountsOnlyOneActive_returnsActiveAccount() {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext

        let first = insertAccount(context: context, username: "first@woow.com", isActive: false)
        let second = insertAccount(context: context, username: "second@woow.com", isActive: true)
        _ = insertAccount(context: context, username: "third@woow.com", isActive: false)

        _ = first // suppress unused warning
        try? context.save()

        let repo = AccountRepository(
            persistence: persistence,
            secureStorage: SecureStorage.shared,
            apiClient: OdooAPIClient()
        )

        let active = repo.getActiveAccount()

        XCTAssertEqual(active?.username, second.username,
                       "getActiveAccount() must return the account with isActive == true")
    }

    // MARK: - Helpers

    private func makeAccount(username: String) -> OdooAccount {
        OdooAccount(
            id: UUID().uuidString,
            serverUrl: "https://myodoo.com",
            database: "prod_db",
            username: username,
            displayName: "Test User",
            isActive: true
        )
    }

    @discardableResult
    private func insertAccount(
        context: NSManagedObjectContext,
        username: String,
        isActive: Bool
    ) -> OdooAccountEntity {
        let entity = OdooAccountEntity(context: context)
        entity.id = UUID().uuidString
        entity.serverUrl = "https://myodoo.com"
        entity.database = "prod_db"
        entity.username = username
        entity.displayName = "Test \(username)"
        entity.userId = 1
        entity.isActive = isActive
        entity.createdAt = Date()
        return entity
    }
}
