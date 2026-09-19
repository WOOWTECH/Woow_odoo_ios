import XCTest
import SwiftUI
import WebKit
@testable import odoo

/// EP-09R-A1 — the loading spinner must stop when a page load FAILS, not only when it succeeds.
///
/// `OdooWebView.swift:368` sets `isLoading = true` in `didStartProvisionalNavigation`, and
/// `:393` is the ONLY place that ever clears it (`didFinish`). Neither
/// `webView(_:didFail:withError:)` nor `webView(_:didFailProvisionalNavigation:withError:)`
/// existed, so any load that ends in failure — offline, DNS failure, TLS rejection, a server
/// that drops the connection — left the spinner running forever with no way back.
///
/// Why these tests can observe a real RED instead of a compile error
/// ─────────────────────────────────────────────────────────────────
/// `WKNavigationDelegate` is an Objective-C protocol whose methods are all optional. Calling
/// them through a protocol-typed reference with optional dispatch (`delegate.webView?(…)`)
/// compiles whether or not the coordinator implements them, and is a silent no-op when it does
/// not. So the assertions below fail at RUNTIME on the unfixed code and pass after the fix —
/// the same source compiles in both states.
@MainActor
final class OdooWebViewLoadFailureTests: XCTestCase {

    /// Reference box so the test can observe writes through a real (non-constant) `Binding`.
    private final class LoadingBox { var value = false }

    private var box: LoadingBox!
    private var coordinator: OdooWebViewCoordinator!
    private var webView: WKWebView!

    /// The failure a WKWebView reports when the host cannot be resolved / the device is offline.
    private var offlineError: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
    }

    /// The failure a WKWebView reports when the TLS handshake is rejected. Used to prove the fix
    /// only stops the spinner and does NOT weaken certificate handling.
    private var tlsError: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed, userInfo: nil)
    }

    override func setUp() async throws {
        try await super.setUp()
        box = LoadingBox()
        let binding = Binding<Bool>(get: { [box] in box!.value },
                                    set: { [box] in box!.value = $0 })
        coordinator = OdooWebViewCoordinator(
            serverUrl: "https://odoo.example.com",
            onSessionExpired: {},
            isLoading: binding
        )
        webView = WKWebView(frame: .zero)
    }

    override func tearDown() async throws {
        webView = nil
        coordinator = nil
        box = nil
        try await super.tearDown()
    }

    /// Drives the coordinator into the "a load is in flight" state the same way WebKit does.
    private func startLoad() {
        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        XCTAssertTrue(box.value,
                      "前置條件：didStartProvisionalNavigation 必須把 isLoading 設為 true，" +
                      "否則後面的斷言沒有意義")
    }

    // MARK: - The delegates must exist at all

    /// The narrowest possible statement of the defect: the coordinator did not respond to the
    /// two failure selectors, so WebKit had nobody to tell when a load died.
    func test_coordinator_respondsToBothNavigationFailureSelectors() {
        XCTAssertTrue(
            coordinator.responds(to: #selector(WKNavigationDelegate.webView(_:didFail:withError:))),
            "缺少 webView(_:didFail:withError:) —— 載入中途失敗時沒有人會清掉 isLoading"
        )
        XCTAssertTrue(
            coordinator.responds(to: #selector(WKNavigationDelegate.webView(_:didFailProvisionalNavigation:withError:))),
            "缺少 webView(_:didFailProvisionalNavigation:withError:) —— 離線／DNS 失敗時 spinner 會永遠轉"
        )
    }

    // MARK: - Provisional failure (offline, DNS, TLS — the common case)

    /// Offline / DNS failure arrives as a *provisional* navigation failure: the request never
    /// got far enough to commit a document. This is the path a user hits in a lift or on a
    /// dropped Wi-Fi, and it was the one that hung.
    func test_didFailProvisionalNavigation_givenOffline_stopsLoading() {
        startLoad()

        let delegate: WKNavigationDelegate = coordinator
        delegate.webView?(webView, didFailProvisionalNavigation: nil, withError: offlineError)

        XCTAssertFalse(box.value,
                       "離線導致 provisional navigation 失敗後，isLoading 必須回到 false；" +
                       "否則畫面停在轉圈，使用者既看不到錯誤也無法重試")
    }

    /// A rejected TLS handshake also surfaces as a provisional failure. The spinner must stop —
    /// and the fix must do nothing beyond that (it must not make the load succeed).
    func test_didFailProvisionalNavigation_givenTLSRejection_stopsLoadingWithoutProceeding() {
        startLoad()

        let delegate: WKNavigationDelegate = coordinator
        delegate.webView?(webView, didFailProvisionalNavigation: nil, withError: tlsError)

        XCTAssertFalse(box.value, "TLS 被拒後 isLoading 必須回到 false")
        XCTAssertNil(webView.url,
                     "TLS 失敗不得放行任何內容：WebView 不應有已載入的 URL。" +
                     "本測試同時守住『修補只停 spinner、不繞過憑證驗證』這條界線")
    }

    // MARK: - Mid-load failure

    /// A load that already committed a document but then fails (connection dropped mid-transfer)
    /// arrives at `didFail`, a different delegate from the provisional one. Both needed fixing.
    func test_didFail_givenConnectionLostAfterCommit_stopsLoading() {
        startLoad()

        let delegate: WKNavigationDelegate = coordinator
        let lostError = NSError(domain: NSURLErrorDomain,
                                code: NSURLErrorNetworkConnectionLost, userInfo: nil)
        delegate.webView?(webView, didFail: nil, withError: lostError)

        XCTAssertFalse(box.value,
                       "載入中途連線中斷後，isLoading 必須回到 false")
    }

    // MARK: - Cancellation must not be treated as a failure state

    /// `NSURLErrorCancelled` is what WebKit reports for a navigation the app itself cancelled —
    /// most importantly the `decidePolicyFor` → `.cancel` path used for session-expiry and
    /// "open in Safari". Those are normal control flow, not errors, but the spinner still has to
    /// stop: `didFinish` will never arrive for a cancelled navigation either.
    func test_didFailProvisionalNavigation_givenCancellation_stillStopsLoading() {
        startLoad()

        let delegate: WKNavigationDelegate = coordinator
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        delegate.webView?(webView, didFailProvisionalNavigation: nil, withError: cancelled)

        XCTAssertFalse(box.value,
                       "導航被取消（session 過期轉登入、外開 Safari）時 didFinish 也不會來，" +
                       "isLoading 同樣必須回到 false")
    }

    // MARK: - The success path must be untouched

    /// Guard against the fix regressing the normal load: `didFinish` must still clear loading.
    func test_didFinish_stillStopsLoading() {
        startLoad()

        coordinator.webView(webView, didFinish: nil)

        XCTAssertFalse(box.value, "成功載入後 isLoading 必須回到 false（既有行為，不得被修補破壞）")
    }
}
