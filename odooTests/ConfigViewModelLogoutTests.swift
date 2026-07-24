//
//  ConfigViewModelLogoutTests.swift
//  odooTests
//
//  Verifies that ConfigViewModel.logout() returns the correct "stay-authenticated" Bool that drives
//  navigation after a logout:
//    - true  → a remaining account was promoted to active; the app stays on the main screen.
//    - false → no accounts remain; the caller returns to the login screen.
//
//  Uses the REAL AccountRepository backed by an in-memory Core Data store (mirrors
//  MultiAccountLogoutTests). No network: seeded accounts carry no FCM token, so the best-effort
//  `unregister_device` call inside AccountRepository.logout is skipped (getFcmToken() → nil).
//

import XCTest
@testable import odoo

@MainActor
final class ConfigViewModelLogoutTests: XCTestCase {

    private var persistence: PersistenceController!
    private var repo: AccountRepository!
    private var viewModel: ConfigViewModel!

    override func setUp() async throws {
        try await super.setUp()
        persistence = PersistenceController(inMemory: true)
        repo = AccountRepository(persistence: persistence)
        // A = demo777 (inactive), B = demo888 (active) — B is the account that gets logged out first.
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: "https://demo777-odoo.woowtech.io", database: "demo777",
                          username: "admin", sessionCookie: "sess-a", tenantId: "demo777", isActive: false),
            SeededAccount(serverURL: "https://demo888-odoo.woowtech.io", database: "demo888",
                          username: "admin", sessionCookie: "sess-b", tenantId: "demo888", isActive: true),
        ])
        viewModel = ConfigViewModel(accountRepository: repo)
    }

    override func tearDown() async throws {
        viewModel = nil
        repo = nil
        persistence = nil
        try await super.tearDown()
    }

    /// Logging out the active account (B) while another (A) remains: logout() must return `true`
    /// (stay authenticated) and A must be promoted to the active account.
    func test_logoutWithRemainingAccount_returnsTrue_andPromotesRemaining() async {
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo888", "precondition: B active")

        let stayAuthenticated = await viewModel.logout()

        XCTAssertTrue(stayAuthenticated, "a remaining account was promoted → app should stay on main")
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo777",
                       "the remaining account A must be promoted to active")
    }

    /// Logging out twice drains all accounts: the second logout() must return `false` (go to login)
    /// and no account remains active.
    func test_logoutUntilNoAccountsRemain_returnsFalse_andNoActiveAccount() async {
        let first = await viewModel.logout()  // B out → A promoted
        XCTAssertTrue(first, "first logout still has A remaining → stay authenticated")
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo777")

        let second = await viewModel.logout() // A out → last account gone

        XCTAssertFalse(second, "no accounts left → caller returns to login")
        XCTAssertNil(repo.getActiveAccount(), "no account should be active after the last logout")
    }
}
