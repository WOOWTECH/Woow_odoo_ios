//
//  StaleWebViewInstanceTests.swift
//  odooTests
//
//  F1 (0930, account isolation — the iOS twin of Android's 0929 P1): every account switch swaps
//  the coordinator's child WKWebView, but the replaced instance kept the coordinator as its
//  navigation/UI delegate. A callback it had already queued could still arrive after the switch
//  and was judged only by host — so on two accounts of the SAME server, account A's late
//  `didFinish` opened account B's load gate (B's pending deep link applied before B's own page,
//  history state flipped), and A's late `/web/login` redirect ran B's session-expiry self-heal.
//
//  Each account target owns one WebView instance; a callback from any other instance must not
//  touch the current account (no link apply, no load gate, no spinner, no expiry, no base load).
//

import XCTest
import WebKit
import SwiftUI
@testable import odoo

/// A WebView whose URL can be pinned without a network load, so a stale instance can report a
/// finished page on the shared host exactly as WebKit would.
private final class PinnedURLWebView: WKWebView {
    var pinnedURL: URL?
    override var url: URL? { pinnedURL }
}

private final class LoadingFlag {
    var value = false
}

@MainActor
final class StaleWebViewInstanceTests: XCTestCase {

    private let host = "same.example.com"
    private var serverUrl: String { "https://\(host)" }
    private var events: [String] = []
    private var baseLoads: [ObjectIdentifier] = []
    private var expired = 0
    private let loading = LoadingFlag()

    private func makeCoordinator() -> OdooWebViewCoordinator {
        let flag = loading
        return OdooWebViewCoordinator(
            serverUrl: serverUrl,
            onSessionExpired: { [weak self] in self?.expired += 1 },
            isLoading: Binding(get: { flag.value }, set: { flag.value = $0 }),
            openExternalURL: { _ in XCTFail("No Safari") },
            brand: .woowtech,
            websiteDataStore: { _ in .nonPersistent() },
            loadBaseRequest: { [weak self] webView, _ in
                self?.events.append("base")
                self?.baseLoads.append(ObjectIdentifier(webView))
            },
            loadDeepLinkRequest: { [weak self] _, request in
                self?.events.append("deeplink:\(request.url?.fragment ?? "")")
            },
            makeWebView: { config in PinnedURLWebView(frame: .zero, configuration: config) }
        )
    }

    private func current(_ sut: OdooWebViewCoordinator) throws -> PinnedURLWebView {
        try XCTUnwrap(sut.webView as? PinnedURLWebView)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A→B on the same host: A's late `didFinish` must not apply B's link or open B's load gate.
    func test_lateDidFinishFromReplacedWebView_sameHost_doesNotApplyNewAccountsLink() async throws {
        let sut = makeCoordinator()
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let oldA = try current(sut)
        oldA.pinnedURL = URL(string: "\(serverUrl)/odoo/discuss")
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil,
                  deepLink: "/web#action=calendar.action_calendar_event")
        let newB = try current(sut)
        XCTAssertFalse(newB === oldA, "precondition: the switch built a new WebView")

        sut.webView(oldA, didFinish: nil)

        XCTAssertFalse(events.contains { $0.hasPrefix("deeplink:") },
                       "A's late didFinish must not apply B's deep link: \(events)")
        XCTAssertFalse(sut.hasFinishedAccountLoad, "A's late didFinish must not open B's load gate")

        newB.pinnedURL = URL(string: "\(serverUrl)/odoo/discuss")
        sut.webView(newB, didFinish: nil)
        XCTAssertEqual(events.last, "deeplink:action=calendar.action_calendar_event",
                       "B's own finished page applies B's link: \(events)")
        XCTAssertTrue(sut.hasFinishedAccountLoad)
    }

    /// A→B→A on the same host: the FIRST A instance is stale even though A is active again.
    func test_lateDidFinishFromFirstInstance_afterAtoBtoA_doesNotApplyLink() async throws {
        let sut = makeCoordinator()
        let a = UUID().uuidString, b = UUID().uuidString
        sut.apply(serverUrl: serverUrl, database: "db", accountId: a, sessionId: nil, deepLink: nil)
        let firstA = try current(sut)
        firstA.pinnedURL = URL(string: "\(serverUrl)/odoo")
        sut.apply(serverUrl: serverUrl, database: "db", accountId: b, sessionId: nil, deepLink: nil)
        sut.apply(serverUrl: serverUrl, database: "db", accountId: a, sessionId: nil,
                  deepLink: "/web#action=contacts.action_contacts")
        XCTAssertFalse(try current(sut) === firstA, "precondition: A got a fresh WebView")

        sut.webView(firstA, didFinish: nil)

        XCTAssertFalse(events.contains { $0.hasPrefix("deeplink:") }, "\(events)")
        XCTAssertFalse(sut.hasFinishedAccountLoad)
    }

    /// A late `/web/login` redirect in A's replaced WebView must not run B's session-expiry path.
    func test_sessionExpiryFromReplacedWebView_isIgnoredAndCancelled() async throws {
        let sut = makeCoordinator()
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let oldA = try current(sut)
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)

        var policy: WKNavigationActionPolicy?
        sut.webView(oldA, decidePolicyFor: StaleNavigationActionStub(url: URL(string: "\(serverUrl)/web/login")!)) {
            policy = $0
        }

        XCTAssertEqual(policy, .cancel, "a stale instance never navigates")
        XCTAssertEqual(expired, 0, "A's stale redirect must not trigger B's self-heal / login")
    }

    /// A late provisional start in A's replaced WebView must not turn B's spinner on.
    func test_didStartFromReplacedWebView_doesNotTouchLoadingState() async throws {
        let sut = makeCoordinator()
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let oldA = try current(sut)
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        loading.value = false

        sut.webView(oldA, didStartProvisionalNavigation: nil)

        XCTAssertFalse(loading.value)
    }

    /// The replaced WebView is detached: no delegates, no longer in the container.
    func test_switch_detachesReplacedWebViewDelegates() async throws {
        let sut = makeCoordinator()
        let container = UIView()
        sut.attach(to: container)
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let oldA = try current(sut)
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)

        XCTAssertNil(oldA.navigationDelegate)
        XCTAssertNil(oldA.uiDelegate)
        XCTAssertNil(oldA.superview)
        XCTAssertTrue(try current(sut).superview === container)
    }

    /// Rapid A→B: A's cookie-store completion arrives after B was built — it must not load A's
    /// (replaced) WebView; only B's instance gets a base load.
    func test_rapidSwitch_supersededCookieCompletion_doesNotLoadReplacedWebView() async throws {
        let sut = makeCoordinator()
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: "sess-a", deepLink: nil)
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: "sess-b", deepLink: nil)
        let newB = try current(sut)

        await waitUntil(self.baseLoads.contains(ObjectIdentifier(newB)))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(baseLoads, [ObjectIdentifier(newB)],
                       "only the current account's WebView may be loaded: \(events)")
    }

    /// pi 0930 (P2): logging out the last account left its live WebView holding (and writing to)
    /// the account's data store, so the store's localStorage survived until the next launch. Before
    /// the store is removed the account's WebView is retired — stopped, detached and dropped.
    func test_retireNotice_forCurrentAccount_detachesAndDropsItsWebView() async throws {
        let sut = makeCoordinator()
        let container = UIView()
        sut.attach(to: container)
        let a = UUID().uuidString
        sut.apply(serverUrl: serverUrl, database: "db", accountId: a, sessionId: nil, deepLink: nil)
        let live = try current(sut)

        NotificationCenter.default.post(name: .accountWebViewMustRetire, object: nil, userInfo: ["accountId": a])

        XCTAssertNil(sut.webView, "the logged-out account's WebView must be dropped")
        XCTAssertNil(live.navigationDelegate)
        XCTAssertNil(live.uiDelegate)
        XCTAssertNil(live.superview)
        XCTAssertFalse(sut.hasFinishedAccountLoad)

        // A SwiftUI update still carrying the removed account must not rebuild (and so recreate)
        // its store.
        sut.apply(serverUrl: serverUrl, database: "db", accountId: a, sessionId: nil, deepLink: nil)
        XCTAssertNil(sut.webView, "a retired account's WebView is never rebuilt")
    }

    /// A retire notice for another account never touches the account on screen.
    func test_retireNotice_forAnotherAccount_keepsTheCurrentWebView() async throws {
        let sut = makeCoordinator()
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let live = try current(sut)

        NotificationCenter.default.post(name: .accountWebViewMustRetire, object: nil,
                                        userInfo: ["accountId": UUID().uuidString])

        XCTAssertTrue(sut.webView === live)
        XCTAssertNotNil(live.navigationDelegate)
    }
}

/// Minimal navigation action for a stale-instance policy check.
private final class StaleNavigationActionStub: WKNavigationAction {
    private let stubRequest: URLRequest
    init(url: URL) {
        stubRequest = URLRequest(url: url)
        super.init()
    }
    override var request: URLRequest { stubRequest }
}
