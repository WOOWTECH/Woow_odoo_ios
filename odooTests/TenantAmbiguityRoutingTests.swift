//
//  TenantAmbiguityRoutingTests.swift
//  odooTests
//
//  EP-08F-iOS (run WT-ENG-20260917A) — reproduction of the "take the first match"
//  behaviour in the push-routing tenant lookup.
//
//  WHY THIS MATTERS
//    `woow_fcm_push.tenant_id_for` falls back to the Odoo database name when the
//    `woow_fcm_push.tenant_id` system parameter is unset — the host is not part of the
//    value. Two unrelated customers whose databases are both called e.g. "odoo" therefore
//    publish the SAME opaque tenant id. The plugin revision deployed on the QA instances
//    (ffc0285f3) carries that same fallback, and its own `DEVICE_ID_DATA_KEY` comment
//    states the client contract explicitly:
//
//        "Clients must COUNT and refuse an ambiguous value rather than take a first match"
//
//    iOS does the opposite today:
//      * odoo/Data/Storage/OdooAccountEntity.swift:74-79  → request.fetchLimit = 1
//      * odoo/Data/Repository/AccountRepository.swift:133-138 → (try? fetch)?.first
//
//    There is no count and no ambiguity refusal, so a notification for customer X can open
//    customer Y's account.
//
//  THIS IS NOT A NEW PRODUCT BEHAVIOUR
//    `getAccount(byTenantId:)` already documents the invariant it fails to honour
//    (AccountRepository.swift:124-132): "the caller MUST drop the deep link in that case
//    and never fall back to the active account (cross-tenant isolation invariant)".
//    Refusing an ambiguous match is making the implementation match its own declared
//    contract — the router already treats `nil` as "drop the link"
//    (NotificationDeepLinkRouter.swift:65, AppDelegate.swift:300-301).
//
//  ISOLATION
//    In-memory Core Data only. No network, no ERP, no FCM/APNs, no secrets, no device.
//    All hosts/db names below are the QA fixtures, not customer data.
//
//  MAPPING: TEST-CASES T15 (unknown/ambiguous tenant), T17 (tenant configuration risk).
//

import XCTest
@testable import odoo

@MainActor
final class TenantAmbiguityRoutingTests: XCTestCase {

    private var persistence: PersistenceController!
    private var repo: AccountRepository!

    /// The collision: two different customers, two different hosts, but both Odoo
    /// databases are called "odoo", so `tenant_id_for` returns "odoo" for both.
    private let collidingTenantId = "odoo"
    private let serverX = "https://customer-x.invalid"
    private let serverY = "https://customer-y.invalid"

    /// A tenant id that is unique, used for the must-still-work regression guards.
    private let uniqueTenantId = "wt-app-qa-unique-fixture"
    private let serverZ = "https://customer-z.invalid"

    override func setUp() async throws {
        try await super.setUp()
        persistence = PersistenceController(inMemory: true)
        repo = AccountRepository(persistence: persistence)
        _ = DeepLinkManager.shared.consume()
    }

    override func tearDown() async throws {
        _ = DeepLinkManager.shared.consume()
        repo = nil
        persistence = nil
        try await super.tearDown()
    }

    private func seedCollidingAccounts() {
        repo.replaceAccountsForTesting([
            SeededAccount(
                serverURL: serverX, database: "odoo", username: "user-x",
                sessionCookie: "sess-X", tenantId: collidingTenantId, isActive: true),
            SeededAccount(
                serverURL: serverY, database: "odoo", username: "user-y",
                sessionCookie: "sess-Y", tenantId: collidingTenantId, isActive: false),
        ])
    }

    // MARK: - Precondition

    /// Both colliding accounts must actually be persisted; otherwise the ambiguity tests
    /// below would pass for the wrong reason (only one row ever existed).
    func test_replaceAccountsForTesting_givenCollidingTenantIds_returnsTwoPersistedAccounts() {
        seedCollidingAccounts()

        let all = repo.getAllAccounts()
        XCTAssertEqual(all.count, 2, "Both accounts must persist — the seed must not silently dedupe")
        XCTAssertEqual(
            all.filter { $0.tenantId == collidingTenantId }.count, 2,
            "Both accounts must carry the same tenant id — that IS the collision under test"
        )
        XCTAssertEqual(
            Set(all.map(\.serverHost)).count, 2,
            "The two accounts must be on different hosts — different customers, same db name"
        )
    }

    // MARK: - EXPECTED RED · the ambiguity itself

    /// **EXPECTED RED before the EP-08F-iOS fix.**
    ///
    /// An ambiguous tenant id must resolve to `nil` so the caller drops the deep link.
    /// Current code sets `fetchLimit = 1` and takes `.first`, so it silently returns one
    /// of the two — a coin flip between two unrelated customers.
    func test_getAccountByTenantId_givenAmbiguousTenantId_returnsNil() {
        seedCollidingAccounts()

        let resolved = repo.getAccount(byTenantId: collidingTenantId)

        XCTAssertNil(
            resolved,
            """
            EP-08F-iOS: tenant id "\(collidingTenantId)" matches 2 stored accounts \
            (\(serverX), \(serverY)) but the lookup returned \
            \(resolved?.serverHost ?? "<nil>"). An ambiguous tenant must be refused, not \
            resolved to an arbitrary first match — see the cross-tenant isolation invariant \
            in the function's own doc comment.
            """
        )
    }

    /// **EXPECTED RED before the fix.**
    ///
    /// The routing decision built on top of the lookup must drop the link entirely. If the
    /// lookup picks an arbitrary account, the router will happily switch to it — delivering
    /// customer X's notification into customer Y's session.
    func test_decide_givenAmbiguousTenantId_returnsDropNotSwitch() {
        seedCollidingAccounts()

        let decision = NotificationDeepLinkRouter.decide(
            userInfo: [
                "odoo_tenant_id": collidingTenantId,
                "odoo_action_url": "/web#id=1&model=mail.message",
            ],
            resolveTenant: { [repo] in repo!.getAccount(byTenantId: $0) },
            activeAccount: repo.getActiveAccount()
        )

        switch decision {
        case .switchAndRoute(let accountId, _):
            XCTFail(
                """
                EP-08F-iOS: an ambiguous tenant id produced a switch to account \(accountId). \
                A notification whose target cannot be determined must never switch accounts.
                """
            )
        default:
            break  // any non-switch decision (drop / ignore) is acceptable here
        }
    }

    // MARK: - EXPECTED GREEN · regression guards the fix must not break

    /// An unambiguous tenant id must still resolve. This is the guard against "fix the
    /// ambiguity by breaking all routing".
    func test_getAccountByTenantId_givenUniqueTenantId_returnsThatAccount() {
        repo.replaceAccountsForTesting([
            SeededAccount(
                serverURL: serverZ, database: "db-z", username: "user-z",
                sessionCookie: "sess-Z", tenantId: uniqueTenantId, isActive: true),
            SeededAccount(
                serverURL: serverX, database: "db-x", username: "user-x",
                sessionCookie: "sess-X", tenantId: "some-other-tenant", isActive: false),
        ])

        let resolved = repo.getAccount(byTenantId: uniqueTenantId)

        XCTAssertNotNil(resolved, "A unique tenant id must still resolve after the fix")
        XCTAssertEqual(resolved?.serverHost, "customer-z.invalid")
    }

    /// A tenant id nobody carries must resolve to nil (existing contract, unchanged).
    func test_getAccountByTenantId_givenUnknownTenantId_returnsNil() {
        seedCollidingAccounts()
        XCTAssertNil(repo.getAccount(byTenantId: "tenant-that-does-not-exist"))
    }

    /// An empty tenant id must never match, including when accounts with empty/nil tenant
    /// ids exist (existing guard at AccountRepository.swift:134, unchanged).
    func test_getAccountByTenantId_givenEmptyTenantId_returnsNil() {
        repo.replaceAccountsForTesting([
            SeededAccount(
                serverURL: serverZ, database: "db-z", username: "user-z",
                sessionCookie: "sess-Z", tenantId: nil, isActive: true),
        ])
        XCTAssertNil(repo.getAccount(byTenantId: ""), "An empty tenant id must never match")
    }

    /// Two accounts with DIFFERENT tenant ids must each resolve to their own account —
    /// the normal multi-instance case must be untouched by the ambiguity refusal.
    func test_getAccountByTenantId_givenTwoDistinctTenants_returnsEachOwnAccount() {
        repo.replaceAccountsForTesting([
            SeededAccount(
                serverURL: serverX, database: "db-x", username: "user-x",
                sessionCookie: "sess-X", tenantId: "tenant-x", isActive: true),
            SeededAccount(
                serverURL: serverY, database: "db-y", username: "user-y",
                sessionCookie: "sess-Y", tenantId: "tenant-y", isActive: false),
        ])

        XCTAssertEqual(repo.getAccount(byTenantId: "tenant-x")?.serverHost, "customer-x.invalid")
        XCTAssertEqual(repo.getAccount(byTenantId: "tenant-y")?.serverHost, "customer-y.invalid")
    }
}
