//
//  OfflineScreenTests.swift
//  odooTests
//
//  W2-4 L1 (Android Pixel 7a, 2026-10-08): a cold start without network showed WebView's own
//  error page with the server address and `net::ERR_NAME_NOT_RESOLVED`, no retry, and no reload
//  when the network returned. On iOS the same failure stopped the spinner and left a blank page
//  with no retry. A network-level load failure of the current account's page now shows the app's
//  own offline screen (no address, no error code) with a retry, and retries once by itself when
//  the network comes back. A failure from a replaced account WebView changes nothing.
//

import XCTest
import WebKit
import SwiftUI
@testable import odoo

/// Records start/stop and lets the test deliver "network is back".
private final class FakeNetworkRecovery: NetworkRecoveryMonitoring {
    private(set) var starts = 0
    private var onRecovered: (() -> Void)?
    var isWatching: Bool { onRecovered != nil }

    func start(onRecovered: @escaping () -> Void) {
        starts += 1
        self.onRecovered = onRecovered
    }

    func stop() { onRecovered = nil }

    func networkReturns() {
        let action = onRecovered
        onRecovered = nil
        action?()
    }
}

private func urlError(_ code: Int, failing url: URL? = nil) -> NSError {
    var info: [String: Any] = [:]
    if let url { info[NSURLErrorFailingURLErrorKey] = url }
    return NSError(domain: NSURLErrorDomain, code: code, userInfo: info)
}

// MARK: - Pure rules

final class NetworkRecoveryDetectorTests: XCTestCase {

    func test_observe_givenUnsatisfiedThenSatisfied_returnsTrueOnce() {
        var detector = NetworkRecoveryDetector()
        XCTAssertFalse(detector.observe(isSatisfied: false))
        XCTAssertTrue(detector.observe(isSatisfied: true), "network came back: retry once")
        XCTAssertFalse(detector.observe(isSatisfied: false))
        XCTAssertFalse(detector.observe(isSatisfied: true), "only once per watch")
    }

    /// The network is up but the server is unreachable: NWPathMonitor's first report is already
    /// satisfied. Firing on it would retry a failing server in a loop.
    func test_observe_givenSatisfiedFromTheStart_returnsFalse() {
        var detector = NetworkRecoveryDetector()
        XCTAssertFalse(detector.observe(isSatisfied: true))
        XCTAssertFalse(detector.observe(isSatisfied: true))
    }
}

final class OfflineScreenRuleTests: XCTestCase {

    func test_showsOfflineScreen_givenNetworkFailures_returnsTrue() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                     NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
                     NSURLErrorSecureConnectionFailed] {
            XCTAssertTrue(OdooWebViewCoordinator.showsOfflineScreen(for: urlError(code)), "code \(code)")
        }
    }

    func test_showsOfflineScreen_givenCancellationOrWebKitError_returnsFalse() {
        XCTAssertFalse(OdooWebViewCoordinator.showsOfflineScreen(for: urlError(NSURLErrorCancelled)),
                       "session expiry / Safari hand-off cancel is control flow, not offline")
        let interrupted = NSError(domain: WKError.errorDomain, code: 102, userInfo: nil)
        XCTAssertFalse(OdooWebViewCoordinator.showsOfflineScreen(for: interrupted))
    }

    func test_retryURL_givenFailedPageOnAccountOrigin_returnsThatPage() {
        let page = URL(string: "https://odoo.example.invalid/odoo/discuss?x=1")!
        XCTAssertEqual(OdooWebViewCoordinator.retryURL(failedURL: page, serverUrl: "https://ODOO.example.invalid",
                                                       database: "db"), page)
    }

    func test_retryURL_givenOtherOriginLoginOrNothing_returnsBasePage() {
        let base = URL(string: "https://odoo.example.invalid/web?db=db")!
        for failed in [nil,
                       URL(string: "https://other.example.invalid/odoo"),
                       URL(string: "https://odoo.example.invalid:8443/odoo"),
                       URL(string: "http://odoo.example.invalid/odoo"),
                       URL(string: "https://odoo.example.invalid/web/login")] {
            XCTAssertEqual(OdooWebViewCoordinator.retryURL(failedURL: failed, serverUrl: "https://odoo.example.invalid",
                                                           database: "db"), base, "\(String(describing: failed))")
        }
    }

    func test_offlineCopy_givenEveryLanguage_isLocalizedAndHasNoAddressOrCode() throws {
        let expected = [
            "en": ["Unable to connect", "Check your network connection and try again.", "Try Again"],
            "zh-Hant": ["無法連線", "請檢查網路連線後再試一次。", "重試"],
            "zh-Hans": ["无法连接", "请检查网络连接后再试一次。", "重试"],
        ]
        for (lang, texts) in expected {
            let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let actual = ["offline_title", "offline_message", "offline_retry"].map {
                bundle.localizedString(forKey: $0, value: nil, table: nil)
            }
            XCTAssertEqual(actual, texts, lang)
            for text in actual {
                XCTAssertNil(text.range(of: "http|://|ERR_|NSURL|-10\\d\\d", options: .regularExpression), text)
            }
        }
    }
}

// MARK: - Coordinator without an account WebView (delegate driven directly)

@MainActor
final class OfflineScreenDelegateTests: XCTestCase {

    private final class LoadingBox { var value = false }

    private var box: LoadingBox!
    private var recovery: FakeNetworkRecovery!
    private var state: WebViewOfflineState!
    private var coordinator: OdooWebViewCoordinator!
    private var webView: WKWebView!

    override func setUp() async throws {
        try await super.setUp()
        box = LoadingBox()
        recovery = FakeNetworkRecovery()
        state = WebViewOfflineState()
        coordinator = OdooWebViewCoordinator(
            serverUrl: "https://odoo.example.invalid",
            onSessionExpired: {},
            isLoading: Binding(get: { [box] in box!.value }, set: { [box] in box!.value = $0 }),
            offlineState: state,
            networkRecovery: recovery
        )
        webView = WKWebView(frame: .zero)
    }

    override func tearDown() async throws {
        webView = nil
        coordinator = nil
        state = nil
        recovery = nil
        box = nil
        try await super.tearDown()
    }

    func test_didFailProvisionalNavigation_givenOffline_showsOfflineScreenAndWatchesNetwork() {
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        coordinator.webView(webView, didFailProvisionalNavigation: nil,
                            withError: urlError(NSURLErrorNotConnectedToInternet))

        XCTAssertFalse(box.value, "spinner stops")
        XCTAssertTrue(state.isShowingOfflineScreen)
        XCTAssertEqual(recovery.starts, 1)
        XCTAssertTrue(recovery.isWatching)
    }

    func test_didFail_givenConnectionLostAfterCommit_showsOfflineScreen() {
        coordinator.webView(webView, didFail: nil, withError: urlError(NSURLErrorNetworkConnectionLost))
        XCTAssertTrue(state.isShowingOfflineScreen)
    }

    func test_didFailProvisionalNavigation_givenCancellation_keepsWebViewVisible() {
        coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: urlError(NSURLErrorCancelled))
        XCTAssertFalse(state.isShowingOfflineScreen)
        XCTAssertEqual(recovery.starts, 0)
    }

    func test_didCommit_givenOfflineScreenShown_hidesItAndStopsWatching() {
        coordinator.webView(webView, didFailProvisionalNavigation: nil,
                            withError: urlError(NSURLErrorTimedOut))
        XCTAssertTrue(state.isShowingOfflineScreen)

        coordinator.webView(webView, didCommit: nil)

        XCTAssertFalse(state.isShowingOfflineScreen)
        XCTAssertFalse(recovery.isWatching)
    }

    /// The retry button goes through the state object to the coordinator. With no account WebView
    /// there is nothing to load, but the screen is dismissed and the watcher stopped.
    func test_retry_givenNoAccountWebView_hidesScreenWithoutLoading() {
        coordinator.webView(webView, didFailProvisionalNavigation: nil,
                            withError: urlError(NSURLErrorCannotFindHost))

        state.retry()

        XCTAssertFalse(state.isShowingOfflineScreen)
        XCTAssertFalse(recovery.isWatching)
        XCTAssertNil(webView.url)
    }
}

// MARK: - Coordinator with real per-account WebViews (loads intercepted)

@MainActor
final class OfflineScreenRetryTests: XCTestCase {

    private final class LoadingBox { var value = false }

    private let serverUrl = "https://odoo.example.invalid"
    private var loads: [(webView: WKWebView, url: URL)] = []
    private var recovery: FakeNetworkRecovery!
    private var state: WebViewOfflineState!
    private var flag = LoadingBox()

    override func setUp() async throws {
        try await super.setUp()
        loads = []
        recovery = FakeNetworkRecovery()
        state = WebViewOfflineState()
    }

    override func tearDown() async throws {
        loads = []
        recovery = nil
        state = nil
        try await super.tearDown()
    }

    private func makeCoordinator() -> OdooWebViewCoordinator {
        OdooWebViewCoordinator(
            serverUrl: serverUrl,
            onSessionExpired: {},
            isLoading: Binding(get: { [flag] in flag.value }, set: { [flag] in flag.value = $0 }),
            openExternalURL: { _ in XCTFail("No Safari") },
            brand: .woowtech,
            websiteDataStore: { _ in .nonPersistent() },
            loadBaseRequest: { [weak self] webView, request in self?.loads.append((webView, request.url!)) },
            loadDeepLinkRequest: { _, _ in XCTFail("No deep link") },
            offlineState: state,
            networkRecovery: recovery
        )
    }

    func test_networkReturns_givenFailedAccountPage_reloadsThatPageInCurrentWebViewOnce() throws {
        let sut = makeCoordinator()
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let live = try XCTUnwrap(sut.webView)
        XCTAssertEqual(loads.count, 1, "precondition: base page requested")
        sut.accountPageDidFinish(loadedHost: "odoo.example.invalid")
        XCTAssertTrue(sut.hasFinishedAccountLoad, "precondition: base page finished")
        let page = URL(string: "\(serverUrl)/odoo/discuss")!

        sut.webView(live, didFailProvisionalNavigation: nil,
                    withError: urlError(NSURLErrorNotConnectedToInternet, failing: page))
        XCTAssertTrue(state.isShowingOfflineScreen)

        recovery.networkReturns()

        XCTAssertFalse(state.isShowingOfflineScreen)
        XCTAssertEqual(loads.count, 2, "exactly one automatic retry")
        XCTAssertTrue(loads[1].webView === live, "retry reloads the current account's own WebView")
        XCTAssertEqual(loads[1].url, page)
        XCTAssertFalse(sut.hasFinishedAccountLoad, "a queued deep link waits for the retried page")
        recovery.networkReturns()
        XCTAssertEqual(loads.count, 2, "the watcher was consumed")
    }

    func test_retryButton_givenFailureOutsideAccountOrigin_reloadsBasePage() throws {
        let sut = makeCoordinator()
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let live = try XCTUnwrap(sut.webView)

        sut.webView(live, didFailProvisionalNavigation: nil,
                    withError: urlError(NSURLErrorCannotFindHost, failing: URL(string: "https://cdn.example.invalid/x")!))
        state.retry()

        XCTAssertEqual(loads.map { $0.url.absoluteString }, ["\(serverUrl)/web?db=db", "\(serverUrl)/web?db=db"])
        XCTAssertTrue(loads[1].webView === live)
    }

    /// Multi-account ownership: switching accounts clears the outgoing account's failure, and a late
    /// failure from the replaced WebView never brings the screen back over the new account.
    func test_accountSwitch_givenOfflineScreenFromPreviousAccount_clearsItAndIgnoresStaleFailure() throws {
        let sut = makeCoordinator()
        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let oldWebView = try XCTUnwrap(sut.webView)
        sut.webView(oldWebView, didFailProvisionalNavigation: nil,
                    withError: urlError(NSURLErrorNotConnectedToInternet))
        XCTAssertTrue(state.isShowingOfflineScreen)

        sut.apply(serverUrl: serverUrl, database: "db", accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        let newWebView = try XCTUnwrap(sut.webView)
        XCTAssertFalse(newWebView === oldWebView)
        XCTAssertFalse(state.isShowingOfflineScreen, "switch clears the previous account's failure")
        XCTAssertFalse(recovery.isWatching)

        sut.webView(oldWebView, didFailProvisionalNavigation: nil,
                    withError: urlError(NSURLErrorNotConnectedToInternet))
        XCTAssertFalse(state.isShowingOfflineScreen, "a replaced WebView's failure is ignored")
        XCTAssertEqual(loads.count, 2)
        XCTAssertTrue(loads[1].webView === newWebView)
    }
}
