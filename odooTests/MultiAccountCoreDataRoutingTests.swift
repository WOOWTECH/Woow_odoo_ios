//
//  MultiAccountCoreDataRoutingTests.swift
//  odooTests
//
//  Integration test for the REAL Core Data path of the P0 cross-tenant deep-link fix.
//
//  The existing MultiAccountDeepLinkRoutingTests prove the pure router + handleNotificationTap
//  logic using an in-memory FAKE repository. They do NOT exercise the real
//  `AccountRepository.replaceAccountsForTesting` → Core Data persistence → `getAccount(byTenantId:)`
//  → `activateAccount` chain that the E2E depends on. This test closes that gap: it seeds two
//  accounts on different servers through the production seed hook (against an in-memory Core Data
//  store), then verifies the tenant id resolves and a cross-account notification tap switches the
//  active account to B — never leaving A active.
//
//  If this passes, every non-UI link of Problem #2 is verified in-process; any remaining E2E
//  failure is a WebView/probe observability issue in the XCUITest harness, not a product defect.
//

import XCTest
@testable import odoo

@MainActor
final class MultiAccountCoreDataRoutingTests: XCTestCase {

    private var persistence: PersistenceController!
    private var repo: AccountRepository!

    private let tenantA = "demo777"
    private let tenantB = "demo888"
    private let serverA = "https://demo777-odoo.woowtech.io"
    private let serverB = "https://demo888-odoo.woowtech.io"

    override func setUp() async throws {
        try await super.setUp()
        persistence = PersistenceController(inMemory: true)
        repo = AccountRepository(persistence: persistence)
        _ = DeepLinkManager.shared.consume()

        let seeded = [
            SeededAccount(
                serverURL: serverA, database: tenantA, username: "admin",
                sessionCookie: "sess-A", tenantId: tenantA, isActive: true),
            SeededAccount(
                serverURL: serverB, database: tenantB, username: "admin",
                sessionCookie: "sess-B", tenantId: tenantB, isActive: false),
        ]
        repo.replaceAccountsForTesting(seeded)
    }

    override func tearDown() async throws {
        _ = DeepLinkManager.shared.consume()
        repo = nil
        persistence = nil
        try await super.tearDown()
    }

    /// The real Core Data seed must persist each account's opaque tenant id so the router can
    /// resolve an incoming push back to the right local account.
    func test_realSeed_persistsTenantId_andResolvesBothAccounts() {
        XCTAssertEqual(repo.getAllAccounts().count, 2, "Both seeded accounts must be installed")
        XCTAssertEqual(repo.getActiveAccount()?.tenantId, tenantA, "A must start active")

        let a = repo.getAccount(byTenantId: tenantA)
        let b = repo.getAccount(byTenantId: tenantB)
        XCTAssertNotNil(a, "tenant id \(tenantA) must resolve to the seeded account A")
        XCTAssertNotNil(b, "tenant id \(tenantB) must resolve to the seeded account B — this is the router's lookup")
        XCTAssertEqual(b?.serverHost, "demo888-odoo.woowtech.io")
    }

    /// The real activate path must flip the active account to B in Core Data.
    func test_realActivate_switchesActiveAccountToB() {
        guard let b = repo.getAccount(byTenantId: tenantB) else {
            return XCTFail("Precondition: B must resolve")
        }
        let ok = repo.activateAccount(id: b.id)
        XCTAssertTrue(ok, "activateAccount must succeed for B")
        XCTAssertEqual(repo.getActiveAccount()?.tenantId, tenantB,
                       "After activating B, the active account must be B — the WebView-driving state")
    }

    /// Full production tap path against the REAL repository: active=A, tap B's payload → B active,
    /// pending link bound to B, A never left active. This is the E2E's logic minus the WebView.
    func test_realHandleNotificationTap_crossAccount_switchesToB_neverA() {
        let appDelegate = AppDelegate()
        let userInfo: [AnyHashable: Any] = [
            "odoo_tenant_id": tenantB,
            "odoo_action_url": "/web#active_id=mail.channel_9",
        ]

        appDelegate.handleNotificationTap(userInfo: userInfo, accountRepository: repo)

        let active = repo.getActiveAccount()
        XCTAssertEqual(active?.tenantId, tenantB,
                       "Cross-account tap must switch the real active account to B (\(tenantB))")
        XCTAssertNotEqual(active?.tenantId, tenantA,
                          "CROSS-TENANT LEAK: A must never remain active after a cross-account tap")
        XCTAssertEqual(DeepLinkManager.shared.pending?.accountId, active?.id,
                       "The pending deep link must be bound to B's account id")
    }
}
