//
//  MultiAccountDeepLinkRoutingTests.swift
//  odooTests
//
//  S2 (iOS) of the multi-account notification deep-link fix (P0 cross-tenant isolation).
//
//  Covers the frozen acceptance matrix:
//   - Cross-account routing: active=A, tap B → routes to B, NEVER A during the transition.
//   - Same-account tap regression.
//   - Target not-logged-in / unresolved tenant id → DROP (A untouched).
//   - Old-plugin payload (no tenant id) → current behaviour.
//   - Warm same-host different-#fragment → JS hash navigation, not a no-op load().
//   - Per-account deep-link binding: single-consume, TTL, drop-on-foreign-login.
//   - Tenant-id parsing from the device-registration response.
//

import XCTest
import WebKit
@testable import odoo

// MARK: - Test fixtures

private enum Fixtures {
    static let accountA = OdooAccount(
        id: "AAAAAAAA-0000-0000-0000-000000000001",
        serverUrl: "https://a-odoo.woowtech.io",
        database: "dbA", username: "userA", displayName: "A",
        isActive: true, tenantId: "tenant-A"
    )
    static let accountB = OdooAccount(
        id: "BBBBBBBB-0000-0000-0000-000000000002",
        serverUrl: "https://b-odoo.woowtech.io",
        database: "dbB", username: "userB", displayName: "B",
        isActive: false, tenantId: "tenant-B"
    )
}

/// In-memory repository that records the account-switch side effects, so tests can assert
/// that account A is NEVER activated during a cross-account tap.
private final class RoutingFakeRepository: AccountRepositoryProtocol, @unchecked Sendable {
    var accounts: [OdooAccount]
    private(set) var activatedIds: [String] = []
    var tenantWrites: [(tenantId: String, serverUrl: String)] = []

    init(accounts: [OdooAccount]) { self.accounts = accounts }

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        .error("stub", .unknown)
    }
    func getActiveAccount() -> OdooAccount? { accounts.first(where: { $0.isActive }) }
    func getAllAccounts() -> [OdooAccount] { accounts }
    func getAccount(byTenantId tenantId: String) -> OdooAccount? {
        guard !tenantId.isEmpty else { return nil }
        return accounts.first(where: { $0.tenantId == tenantId })
    }
    func switchAccount(id: String) async -> Bool { activateAccount(id: id) }
    func activateAccount(id: String) -> Bool {
        guard accounts.contains(where: { $0.id == id }) else { return false }
        activatedIds.append(id)
        accounts = accounts.map { account in
            OdooAccount(
                id: account.id, serverUrl: account.serverUrl, database: account.database,
                username: account.username, displayName: account.displayName,
                userId: account.userId, isActive: account.id == id, tenantId: account.tenantId
            )
        }
        return true
    }
    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) {
        tenantWrites.append((tenantId, serverUrl))
    }
    func logout(accountId: String?) async {}
    func removeAccount(id: String) async {}
    func getSessionId(for serverUrl: String) -> String? { nil }
}

// MARK: - Router decision tests (pure)

final class NotificationDeepLinkRouterTests: XCTestCase {

    private func resolver(_ repo: RoutingFakeRepository) -> (String) -> OdooAccount? {
        { repo.getAccount(byTenantId: $0) }
    }

    /// Cross-account: active=A, tap B's notification → switch to B. The decision must carry
    /// B's account id and NEVER A's.
    func test_crossAccountTap_routesToTargetB_neverA() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA, Fixtures.accountB])
        let userInfo: [AnyHashable: Any] = [
            "odoo_action_url": "/web#active_id=mail.channel_9",
            "odoo_tenant_id": "tenant-B",
        ]

        let decision = NotificationDeepLinkRouter.decide(
            userInfo: userInfo,
            resolveTenant: resolver(repo),
            activeAccount: repo.getActiveAccount()
        )

        XCTAssertEqual(
            decision,
            .switchAndRoute(accountId: Fixtures.accountB.id, url: "/web#active_id=mail.channel_9")
        )
        if case .switchAndRoute(let accountId, _) = decision {
            XCTAssertNotEqual(accountId, Fixtures.accountA.id, "Cross-account tap must never target A")
        } else {
            XCTFail("Expected switchAndRoute")
        }
    }

    /// Same-account: active=A, tap A's own notification → route to A unchanged.
    func test_sameAccountTap_routesToA() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA, Fixtures.accountB])
        let userInfo: [AnyHashable: Any] = [
            "odoo_action_url": "/web#active_id=mail.channel_1",
            "odoo_tenant_id": "tenant-A",
        ]

        let decision = NotificationDeepLinkRouter.decide(
            userInfo: userInfo, resolveTenant: resolver(repo), activeAccount: repo.getActiveAccount()
        )

        XCTAssertEqual(
            decision,
            .switchAndRoute(accountId: Fixtures.accountA.id, url: "/web#active_id=mail.channel_1")
        )
    }

    /// Tenant id resolves to no local account (B not logged in) → DROP, never fall back to A.
    func test_notLoggedIn_dropsAndNeverTargetsA() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA]) // B absent
        let userInfo: [AnyHashable: Any] = [
            "odoo_action_url": "/web#active_id=mail.channel_9",
            "odoo_tenant_id": "tenant-B",
        ]

        let decision = NotificationDeepLinkRouter.decide(
            userInfo: userInfo, resolveTenant: resolver(repo), activeAccount: repo.getActiveAccount()
        )

        XCTAssertEqual(decision, .drop(.unresolvedTenant))
    }

    /// Present-but-unknown tenant id → DROP (never A).
    func test_unresolvedTenant_drops() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA, Fixtures.accountB])
        let userInfo: [AnyHashable: Any] = [
            "odoo_action_url": "/web#active_id=mail.channel_9",
            "odoo_tenant_id": "tenant-UNKNOWN",
        ]

        let decision = NotificationDeepLinkRouter.decide(
            userInfo: userInfo, resolveTenant: resolver(repo), activeAccount: repo.getActiveAccount()
        )

        XCTAssertEqual(decision, .drop(.unresolvedTenant))
    }

    /// Old-plugin payload (no tenant id) → current behaviour: keep active account A.
    func test_oldPayload_noTenantId_usesActiveAccount() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA, Fixtures.accountB])
        let userInfo: [AnyHashable: Any] = ["odoo_action_url": "/web#active_id=mail.channel_5"]

        let decision = NotificationDeepLinkRouter.decide(
            userInfo: userInfo, resolveTenant: resolver(repo), activeAccount: repo.getActiveAccount()
        )

        XCTAssertEqual(
            decision,
            .useActive(accountId: Fixtures.accountA.id, url: "/web#active_id=mail.channel_5")
        )
    }

    /// Missing action url → drop (nothing to navigate to).
    func test_missingActionUrl_drops() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA])
        let decision = NotificationDeepLinkRouter.decide(
            userInfo: ["odoo_tenant_id": "tenant-A"],
            resolveTenant: resolver(repo),
            activeAccount: repo.getActiveAccount()
        )
        XCTAssertEqual(decision, .drop(.noActionUrl))
    }

    /// A resolved tenant with a malformed action url → drop (validated against target host).
    func test_resolvedTenant_withExternalUrl_drops() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA, Fixtures.accountB])
        let userInfo: [AnyHashable: Any] = [
            "odoo_action_url": "https://evil.com/phish",
            "odoo_tenant_id": "tenant-B",
        ]
        let decision = NotificationDeepLinkRouter.decide(
            userInfo: userInfo, resolveTenant: resolver(repo), activeAccount: repo.getActiveAccount()
        )
        XCTAssertEqual(decision, .drop(.invalidUrl))
    }
}

// MARK: - AppDelegate side-effect tests

@MainActor
final class MultiAccountAppDelegateTests: XCTestCase {

    private var sut: AppDelegate!

    override func setUp() async throws {
        try await super.setUp()
        sut = AppDelegate()
        _ = DeepLinkManager.shared.consume()
    }

    override func tearDown() async throws {
        _ = DeepLinkManager.shared.consume()
        sut = nil
        try await super.tearDown()
    }

    /// Cross-account tap must activate B (not A) and bind the pending link to B.
    func test_handleTap_crossAccount_activatesBAndBindsLinkToB() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA, Fixtures.accountB])
        let userInfo: [AnyHashable: Any] = [
            "odoo_action_url": "/web#active_id=mail.channel_9",
            "odoo_tenant_id": "tenant-B",
        ]

        sut.handleNotificationTap(userInfo: userInfo, accountRepository: repo)

        XCTAssertEqual(repo.activatedIds, [Fixtures.accountB.id], "Only B must be activated")
        XCTAssertFalse(repo.activatedIds.contains(Fixtures.accountA.id), "A must never be activated")
        XCTAssertEqual(DeepLinkManager.shared.pending?.accountId, Fixtures.accountB.id)
        XCTAssertEqual(DeepLinkManager.shared.pending?.url, "/web#active_id=mail.channel_9")
    }

    /// Unresolved tenant id must NOT switch accounts and must NOT set a pending link.
    func test_handleTap_unresolved_dropsAndLeavesAUntouched() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA])
        let userInfo: [AnyHashable: Any] = [
            "odoo_action_url": "/web#active_id=mail.channel_9",
            "odoo_tenant_id": "tenant-B",
        ]

        sut.handleNotificationTap(userInfo: userInfo, accountRepository: repo)

        XCTAssertTrue(repo.activatedIds.isEmpty, "No account may be activated on an unresolved tenant")
        XCTAssertNil(DeepLinkManager.shared.pending, "No pending link may be set on drop")
    }

    /// Old-plugin payload keeps A active and binds the link to A.
    func test_handleTap_oldPayload_bindsToActiveAccount() {
        let repo = RoutingFakeRepository(accounts: [Fixtures.accountA])
        let userInfo: [AnyHashable: Any] = ["odoo_action_url": "/web#active_id=mail.channel_5"]

        sut.handleNotificationTap(userInfo: userInfo, accountRepository: repo)

        XCTAssertTrue(repo.activatedIds.isEmpty, "Old payload must not force a switch")
        XCTAssertEqual(DeepLinkManager.shared.pending?.accountId, Fixtures.accountA.id)
    }
}

// MARK: - DeepLinkManager binding tests

@MainActor
final class DeepLinkBindingTests: XCTestCase {

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "bind.\(UUID().uuidString)")!
    }

    /// A link bound to B is consumable by B but NEVER by A (cross-tenant guard).
    func test_boundLink_consumableOnlyByTargetAccount() {
        let sut = DeepLinkManager(defaults: makeSuite())
        sut.setPending("/web#active_id=mail.channel_9", accountId: Fixtures.accountB.id)

        XCTAssertNil(sut.consume(for: Fixtures.accountA.id), "A must never take B's link")
        XCTAssertEqual(sut.consume(for: Fixtures.accountB.id), "/web#active_id=mail.channel_9")
    }

    /// consume(for:) is single-consume — the second call returns nil.
    func test_boundLink_singleConsume() {
        let sut = DeepLinkManager(defaults: makeSuite())
        sut.setPending("/web#x=1", accountId: Fixtures.accountB.id)

        XCTAssertEqual(sut.consume(for: Fixtures.accountB.id), "/web#x=1")
        XCTAssertNil(sut.consume(for: Fixtures.accountB.id))
    }

    /// A foreign-account login drops a link bound to a different account.
    func test_invalidateIfNotTarget_dropsForeignBoundLink() {
        let sut = DeepLinkManager(defaults: makeSuite())
        sut.setPending("/web#x=1", accountId: Fixtures.accountB.id)

        sut.invalidateIfNotTarget(accountId: Fixtures.accountA.id)

        XCTAssertNil(sut.pending, "A link bound to B must be dropped when A logs in")
    }

    /// invalidateIfNotTarget keeps a link bound to the same account.
    func test_invalidateIfNotTarget_keepsMatchingLink() {
        let sut = DeepLinkManager(defaults: makeSuite())
        sut.setPending("/web#x=1", accountId: Fixtures.accountB.id)

        sut.invalidateIfNotTarget(accountId: Fixtures.accountB.id)

        XCTAssertNotNil(sut.pending)
    }

    /// An expired link (older than the TTL) is never returned.
    func test_expiredLink_isDropped() {
        let expired = PendingDeepLink(
            url: "/web#x=1", accountId: Fixtures.accountB.id,
            createdAt: Date(timeIntervalSinceNow: -3600)
        )
        XCTAssertTrue(expired.isExpired(), "A one-hour-old link must be expired")
    }
}

// MARK: - OdooWebView navigation planning (warm fragment vs load)

final class OdooWebViewDeepLinkPlanTests: XCTestCase {

    private let serverB = "https://b-odoo.woowtech.io"

    /// Warm case: already on B's host, only the #fragment changes → JS hash navigation.
    /// This is the reported bug — a plain load() would be a no-op in the running SPA.
    func test_warmSameHost_fragmentChange_usesHashNavigation() {
        let current = URL(string: "\(serverB)/web?db=dbB#active_id=mail.channel_1")!
        let plan = OdooWebViewCoordinator.deepLinkApplyPlan(
            currentURL: current,
            targetServerUrl: serverB,
            deepLink: "/web#active_id=mail.channel_9"
        )
        XCTAssertEqual(plan, .fragment("#active_id=mail.channel_9"))
    }

    /// Cold/cross-host case: no current URL → full load onto the target host.
    func test_noCurrentURL_usesFullLoad() {
        let plan = OdooWebViewCoordinator.deepLinkApplyPlan(
            currentURL: nil,
            targetServerUrl: serverB,
            deepLink: "/web#active_id=mail.channel_9"
        )
        guard case .load(let url) = plan else {
            return XCTFail("Expected a full load")
        }
        XCTAssertEqual(url.host, "b-odoo.woowtech.io")
        XCTAssertNotEqual(url.host, "a-odoo.woowtech.io", "The target load must never be A's host")
    }

    /// The resolved target URL always points at the target server host, never account A's.
    func test_resolvedDeepLinkURL_targetsBHost_neverA() {
        let url = OdooWebViewCoordinator.resolveDeepLinkURL(
            serverUrl: serverB, deepLink: "/web#active_id=mail.channel_9"
        )
        XCTAssertEqual(url?.host, "b-odoo.woowtech.io")
    }

    /// An invalid deep link yields no plan.
    func test_invalidDeepLink_returnsNil() {
        let plan = OdooWebViewCoordinator.deepLinkApplyPlan(
            currentURL: nil, targetServerUrl: serverB, deepLink: "https://evil.com/x"
        )
        XCTAssertNil(plan)
    }

    /// Per-account data stores must be DISTINCT for two different UUID account ids (iOS 17+).
    func test_dataStore_isDistinctPerAccount() {
        if #available(iOS 17.0, *) {
            let storeA = OdooWebViewCoordinator.dataStore(forAccountId: Fixtures.accountA.id)
            let storeB = OdooWebViewCoordinator.dataStore(forAccountId: Fixtures.accountB.id)
            XCTAssertNotEqual(storeA.identifier, storeB.identifier,
                              "Each account must get its own WKWebsiteDataStore identifier")
        }
    }
}

// MARK: - Tenant-id parsing (device registration)

final class TenantIdParsingTests: XCTestCase {

    func test_parseTenantId_fromStringField() {
        XCTAssertEqual(PushTokenRepository.parseTenantId(from: ["tenant_id": "tenant-B"]), "tenant-B")
    }

    func test_parseTenantId_fromAlternateKey() {
        XCTAssertEqual(PushTokenRepository.parseTenantId(from: ["odoo_tenant_id": "tenant-C"]), "tenant-C")
    }

    func test_parseTenantId_coercesIntegerId() {
        XCTAssertEqual(PushTokenRepository.parseTenantId(from: ["tenant_id": 42]), "42")
    }

    func test_parseTenantId_oldPluginResponse_returnsNil() {
        XCTAssertNil(PushTokenRepository.parseTenantId(from: true))
        XCTAssertNil(PushTokenRepository.parseTenantId(from: ["ok": true]))
        XCTAssertNil(PushTokenRepository.parseTenantId(from: nil))
    }
}
