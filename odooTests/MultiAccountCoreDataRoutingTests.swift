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

// MARK: - Story 10-1 review: the REPOSITORY half, against real Core Data

/// A mutation test proved the first version of story 10-1 had **zero** coverage of its own
/// production change: reverting `getAccount(byTenantId:)` to `.first` and `isTenantIdAmbiguous`
/// to `false` left the entire 377-test suite green. All four new tests fed the router a
/// hand-written closure that re-implemented the repository's count-and-refuse, so the repository
/// itself — and the `fetchLimit` removal that makes counting possible — was exercised by nothing.
///
/// These run the real `AccountRepository` over an in-memory Core Data stack, so they fail if the
/// production logic is reverted.
@MainActor
final class AmbiguousTenantCoreDataTests: XCTestCase {

    private var persistence: PersistenceController!
    private var repo: AccountRepository!

    /// The §4.3 default: every STB box ships with the same POSTGRES_DB, so two unrelated
    /// customer servers hand back an identical tenant id.
    private let collidingTenant = "odoo18_ecpay"
    private let serverX = "https://x-odoo.woowtech.io"
    private let serverY = "https://y-odoo.woowtech.io"
    /// Two USERS on ONE server — the collision that is unavoidable, not a mis-provisioning.
    private let sharedServer = "https://shared-odoo.woowtech.io"

    override func setUp() async throws {
        try await super.setUp()
        persistence = PersistenceController(inMemory: true)
        repo = AccountRepository(persistence: persistence)
    }

    override func tearDown() async throws {
        repo = nil
        persistence = nil
        try await super.tearDown()
    }

    private func seed(_ accounts: [SeededAccount]) {
        repo.replaceAccountsForTesting(accounts)
    }

    func test_twoBoxesSharingATenantId_resolveToNothing() {
        seed([
            SeededAccount(serverURL: serverX, database: collidingTenant, username: "u",
                          sessionCookie: "s1", tenantId: collidingTenant, isActive: true),
            SeededAccount(serverURL: serverY, database: collidingTenant, username: "u",
                          sessionCookie: "s2", tenantId: collidingTenant, isActive: false),
        ])
        XCTAssertNil(repo.getAccount(byTenantId: collidingTenant),
                     "a colliding tenant id must not resolve to an arbitrary row")
        XCTAssertTrue(repo.isTenantIdAmbiguous(collidingTenant))
    }

    func test_aUniqueTenantIdStillResolves() {
        seed([
            SeededAccount(serverURL: serverX, database: "dbX", username: "u",
                          sessionCookie: "s1", tenantId: "tenant-X", isActive: true),
            SeededAccount(serverURL: serverY, database: "dbY", username: "u",
                          sessionCookie: "s2", tenantId: "tenant-Y", isActive: false),
        ])
        XCTAssertEqual(repo.getAccount(byTenantId: "tenant-Y")?.serverUrl, serverY)
        XCTAssertFalse(repo.isTenantIdAmbiguous("tenant-Y"))
    }

    /// The defect the review found: the WRITE side destroyed the evidence the read side needs.
    ///
    /// `setTenantId` took `.first` of the accounts matching a serverUrl and then short-circuited
    /// on `tenantId != tenantId`. Two users on one database share a serverUrl, so the registration
    /// loop's second pass hit the SAME row and was swallowed — only one row was ever stamped.
    /// `isTenantIdAmbiguous` then reported false, `getAccount` returned that single row, and a
    /// push for the OTHER user opened this one's session. The ambiguity refusal never fired.
    func test_bothUsersOnOneServerAreStamped_soAmbiguityIsDetectable() {
        seed([
            SeededAccount(serverURL: sharedServer, database: "shared", username: "alice",
                          sessionCookie: "s1", tenantId: nil, isActive: true),
            SeededAccount(serverURL: sharedServer, database: "shared", username: "bob",
                          sessionCookie: "s2", tenantId: nil, isActive: false),
        ])

        // What FCM registration does: one call per account, both on the same server.
        repo.setTenantId(collidingTenant, forServerUrl: sharedServer)
        repo.setTenantId(collidingTenant, forServerUrl: sharedServer)

        let stamped = repo.getAllAccounts().filter { $0.tenantId == collidingTenant }
        XCTAssertEqual(stamped.count, 2,
                       "only one row was stamped, so the ambiguity is invisible to the read side")
        XCTAssertTrue(repo.isTenantIdAmbiguous(collidingTenant))
        XCTAssertNil(repo.getAccount(byTenantId: collidingTenant))
    }

    func test_theActiveAccountIsRecognisedAsACandidate() {
        seed([
            SeededAccount(serverURL: serverX, database: collidingTenant, username: "u",
                          sessionCookie: "s1", tenantId: collidingTenant, isActive: true),
            SeededAccount(serverURL: serverY, database: collidingTenant, username: "u",
                          sessionCookie: "s2", tenantId: collidingTenant, isActive: false),
        ])
        let active = repo.getAllAccounts().first { $0.isActive }!
        XCTAssertTrue(repo.isAccount(active.id, candidateForTenantId: collidingTenant))
        XCTAssertFalse(repo.isAccount(active.id, candidateForTenantId: "some-other-tenant"))
    }
}
