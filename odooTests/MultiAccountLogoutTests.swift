//
//  MultiAccountLogoutTests.swift
//  odooTests
//
//  Story: Fix Multi-Account LOGOUT. Verifies the fallback-promotion behavior (Bug A) against the
//  REAL AccountRepository + an in-memory Core Data store: logging out the ACTIVE account must
//  promote a remaining account (stay authenticated), and only the LAST logout leaves no active
//  account (→ login). No network: seeded accounts have no FCM token, so the best-effort
//  `unregister_device` call is skipped.
//

import XCTest
@testable import odoo

@MainActor
final class MultiAccountLogoutTests: XCTestCase {

    private var persistence: PersistenceController!
    private var repo: AccountRepository!

    override func setUp() async throws {
        try await super.setUp()
        persistence = PersistenceController(inMemory: true)
        repo = AccountRepository(persistence: persistence)
        // A = demo777 (inactive), B = demo888 (active) — mirrors the manual device test.
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: "https://demo777-odoo.woowtech.io", database: "demo777",
                          username: "admin", sessionCookie: "sess-a", tenantId: "demo777", isActive: false),
            SeededAccount(serverURL: "https://demo888-odoo.woowtech.io", database: "demo888",
                          username: "admin", sessionCookie: "sess-b", tenantId: "demo888", isActive: true),
        ])
    }

    override func tearDown() async throws {
        repo = nil
        persistence = nil
        try await super.tearDown()
    }

    /// Bug A: logging out the ACTIVE account (B) while another (A) remains must promote A and keep
    /// the app authenticated — NOT strand the user with no active account (which forces Login).
    func test_logoutActiveAccount_promotesRemaining_staysAuthenticated() async {
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo888", "precondition: B active")

        await repo.logout(accountId: nil) // logs out the active account (B)

        let active = repo.getActiveAccount()
        XCTAssertNotNil(active, "must fall back to a remaining account, not nil (nil => stuck on Login)")
        XCTAssertEqual(active?.database, "demo777", "the remaining account A must be promoted to active")
        XCTAssertEqual(repo.getAllAccounts().count, 1, "only the logged-out account is removed")
        XCTAssertEqual(repo.getAllAccounts().first?.database, "demo777")
    }

    /// Logging out the LAST remaining account leaves no active account, so the caller returns to Login.
    func test_logoutLastAccount_leavesNoActiveAccount() async {
        await repo.logout(accountId: nil) // B out → A promoted
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo777")

        await repo.logout(accountId: nil) // A out → last account gone

        XCTAssertNil(repo.getActiveAccount(), "no account should be active after the last logout")
        XCTAssertTrue(repo.getAllAccounts().isEmpty, "all accounts removed")
    }

    /// The promotion only happens for the logged-out ACTIVE account; the remaining account keeps its
    /// own identity (isolation — logging out B must not disturb A's stored data).
    func test_remainingAccount_isUnchanged() async {
        await repo.logout(accountId: nil) // B out → A promoted
        let a = repo.getActiveAccount()
        XCTAssertEqual(a?.database, "demo777")
        XCTAssertEqual(a?.tenantId, "demo777", "A's tenant id (for push routing) must be intact")
    }
}
