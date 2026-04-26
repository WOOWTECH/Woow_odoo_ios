import CoreLocation
import SwiftUI
import WebKit

/// WKWebView wrapper for displaying Odoo web UI.
/// Ported from Android: MainScreen.kt OdooWebView composable.
/// UX-25 through UX-34.
struct OdooWebView: UIViewRepresentable {
    let serverUrl: String
    let database: String
    let sessionId: String?
    let deepLinkUrl: String?
    let onSessionExpired: () -> Void
    @Binding var isLoading: Bool

    func makeCoordinator() -> OdooWebViewCoordinator {
        OdooWebViewCoordinator(
            serverUrl: serverUrl,
            onSessionExpired: onSessionExpired,
            isLoading: $isLoading
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Install the geolocation shim as a WKUserScript so it runs before any
        // page JavaScript, overriding navigator.geolocation with the native bridge.
        if let shimURL = Bundle.main.url(forResource: "geolocation_shim", withExtension: "js"),
           let shimSource = try? String(contentsOf: shimURL, encoding: .utf8) {
            let userScript = WKUserScript(
                source: shimSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            config.userContentController.addUserScript(userScript)
        }

        // Register the location message handler proxy (avoids retain cycle).
        // The proxy holds coordinator weakly; the coordinator's activeAccountHost
        // closure always resolves the current serverUrl, not a snapshot.
        let locationCoordinator = context.coordinator.locationCoordinator
        let proxy = LocationMessageHandlerProxy(coordinator: locationCoordinator)
        config.userContentController.add(proxy, name: "requestLocation")

        #if DEBUG
        // Debug-only test bridge: lets XCUITests inject JS via "__woowTestEval" handler.
        let testProxy = JSBridgeMessageHandlerProxy()
        config.userContentController.add(testProxy, name: "__woowTestEval")
        #endif

        let webView = WKWebView(frame: .zero, configuration: config)
        // Give the test bridge a reference to the webView so it can evaluateJavaScript.
        #if DEBUG
        testProxy.webView = webView
        #endif

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Sync session cookie before loading
        if let sessionId {
            let cookie = HTTPCookie(properties: [
                .name: "session_id",
                .value: sessionId,
                .domain: URL(string: serverUrl)?.host ?? "",
                .path: "/",
                .secure: "TRUE",
            ])
            if let cookie {
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    self.loadInitialUrl(webView: webView)
                }
            } else {
                loadInitialUrl(webView: webView)
            }
        } else {
            loadInitialUrl(webView: webView)
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // No dynamic updates needed — WebView manages its own state
    }

    private func loadInitialUrl(webView: WKWebView) {
        let urlString: String
        if let deepLinkUrl, !deepLinkUrl.isEmpty,
           DeepLinkValidator.isValid(url: deepLinkUrl, serverHost: URL(string: serverUrl)?.host ?? "") {
            // Build safe URL from deep link
            if deepLinkUrl.hasPrefix("/") {
                urlString = "\(serverUrl)\(deepLinkUrl)"
            } else {
                urlString = deepLinkUrl
            }
        } else {
            urlString = "\(serverUrl)/web?db=\(database)"
        }

        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
    }
}

/// WKWebView delegate handling navigation policy, OWL fixes, and security.
final class OdooWebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let serverUrl: String
    let onSessionExpired: () -> Void
    @Binding var isLoading: Bool

    private let serverHost: String

    /// Owns the location coordinator for the lifetime of this WebView coordinator.
    /// Declared as a stored property so it is created once and reused across
    /// WKWebView updates (UIViewRepresentable lifecycle).
    let locationCoordinator: LocationCoordinator

    init(serverUrl: String, onSessionExpired: @escaping () -> Void, isLoading: Binding<Bool>) {
        self.serverUrl = serverUrl
        self.onSessionExpired = onSessionExpired
        self._isLoading = isLoading
        self.serverHost = URL(string: serverUrl)?.host ?? ""

        // The activeAccountHost closure captures serverUrl by VALUE here because
        // OdooWebViewCoordinator is recreated whenever serverUrl changes (SwiftUI
        // lifecycle). A new coordinator — and therefore a new closure — is created
        // for every account switch, so the value is always current.
        let host = URL(string: serverUrl)?.host
        let gate = LocationPermissionGate()
        self.locationCoordinator = LocationCoordinator(
            gate: gate,
            activeAccountHost: { host }
        )
    }

    // MARK: - Navigation Decision (extracted for testability)

    /// The result of evaluating a URL against the WebView navigation policy.
    /// Extracted from `decidePolicyFor` so the logic can be unit-tested without
    /// requiring a live WKWebView or UIApplication.
    enum NavigationDecision: Equatable {
        /// URL is allowed to load inside the WebView.
        case allow
        /// URL is blocked — session expiry detected, app should show login screen.
        case sessionExpired
        /// URL is blocked — external host, app should open it in Safari.
        case openInSafari(URL)
        /// URL is blocked — no URL provided.
        case cancel
    }

    /// Pure function that decides what to do with a navigation URL.
    /// Does NOT have side effects — caller is responsible for acting on the result.
    func decideNavigation(for url: URL?) -> NavigationDecision {
        guard let url else { return .cancel }

        // Session expiry detection
        if url.absoluteString.contains("/web/login") {
            return .sessionExpired
        }

        // Same-host: allow
        if let host = url.host, host.caseInsensitiveCompare(serverHost) == .orderedSame {
            return .allow
        }

        // Relative URLs (no host): allow
        if url.host == nil {
            return .allow
        }

        // Blob URLs: allow (OWL framework downloads)
        if url.scheme == "blob" {
            return .allow
        }

        // Everything else: open in Safari (UX-27)
        return .openInSafari(url)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        injectOWLLayoutFixes(webView: webView)
        #if DEBUG
        injectTestAutoTapIfRequested(webView: webView)
        #endif
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let decision = decideNavigation(for: navigationAction.request.url)

        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .sessionExpired:
            onSessionExpired()
            decisionHandler(.cancel)
        case .openInSafari(let url):
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Block popup windows (B0.7 equivalent)
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - Test Auto-Tap (DEBUG only)

    /// Performs a JS click on the element described by `WOOW_TEST_AUTOTAP` launch env var
    /// after each page load. Used by XCUITest when WKWebView accessibility queries are
    /// unreliable (OWL renders icon-only systray items that don't propagate aria-label to
    /// the AX tree). Compiled out of Release builds.
    ///
    /// The env var value is a selector tag that encodes what to click:
    /// - `"systray-attendance"` → clicks the first `[aria-label="Attendance"]` element.
    /// - `"clock-checkin"` → clicks the first button containing "Check in" text.
    /// - `"clock-checkout"` → clicks the first button containing "Check out" text.
    #if DEBUG
    private func injectTestAutoTapIfRequested(webView: WKWebView) {
        guard let selector = ProcessInfo.processInfo.environment["WOOW_TEST_AUTOTAP"],
              !selector.isEmpty else { return }

        // Delay slightly so OWL has time to render the systray after page load.
        let js: String
        switch selector {
        case "systray-attendance":
            js = """
            setTimeout(function() {
                var el = document.querySelector('[aria-label="Attendance"]')
                       || document.querySelector('[title="Attendance"]');
                if (!el) {
                    var items = document.querySelectorAll('.o_menu_systray .o_attendances_systray_item, .o_menu_systray [class*="attendance"]');
                    el = items[0];
                }
                if (el) { el.click(); console.log('[TestHook] Auto-tapped Attendance systray'); }
                else { console.warn('[TestHook] WOOW_TEST_AUTOTAP: Attendance systray not found'); }
            }, 2000);
            """
        case "clock-checkin":
            // Two-step: open the Attendance systray dropdown first, then click "Check in"
            // after the OWL popover has had time to render (~1000ms).
            js = """
            setTimeout(function() {
                function openAttendanceThen(callback) {
                    var el = document.querySelector('.o_menu_systray .o_attendances_systray_item')
                           || document.querySelector('.o_menu_systray [class*="attendance"]')
                           || document.querySelector('[aria-label="Attendance"]');
                    if (el) {
                        el.click();
                        console.log('[TestHook] Auto-opened Attendance systray for check-in');
                        setTimeout(callback, 1200);
                    } else {
                        console.warn('[TestHook] clock-checkin: Attendance systray not found');
                        setTimeout(callback, 0);
                    }
                }
                openAttendanceThen(function() {
                    var btns = Array.from(document.querySelectorAll('button, a[role="button"]'));
                    var btn = btns.find(function(b) {
                        return b.textContent.trim().toLowerCase() === 'check in'
                            || b.textContent.trim().match(/^check[\\s-]?in$/i);
                    });
                    if (btn) { btn.click(); console.log('[TestHook] Auto-tapped Check in'); }
                    else { console.warn('[TestHook] clock-checkin: Check in button not found after opening dropdown'); }
                });
            }, 2000);
            """
        case "clock-checkout":
            // Two-step: open the Attendance systray dropdown first, then click "Check out".
            js = """
            setTimeout(function() {
                function openAttendanceThen(callback) {
                    var el = document.querySelector('.o_menu_systray .o_attendances_systray_item')
                           || document.querySelector('.o_menu_systray [class*="attendance"]')
                           || document.querySelector('[aria-label="Attendance"]');
                    if (el) {
                        el.click();
                        console.log('[TestHook] Auto-opened Attendance systray for check-out');
                        setTimeout(callback, 1200);
                    } else {
                        console.warn('[TestHook] clock-checkout: Attendance systray not found');
                        setTimeout(callback, 0);
                    }
                }
                openAttendanceThen(function() {
                    var btns = Array.from(document.querySelectorAll('button, a[role="button"]'));
                    var btn = btns.find(function(b) {
                        return b.textContent.trim().toLowerCase() === 'check out'
                            || b.textContent.trim().match(/^check[\\s-]?out$/i);
                    });
                    if (btn) { btn.click(); console.log('[TestHook] Auto-tapped Check out'); }
                    else { console.warn('[TestHook] clock-checkout: Check out button not found after opening dropdown'); }
                });
            }, 2000);
            """
        default:
            return
        }

        webView.evaluateJavaScript(js) { _, error in
            if let error {
                print("[TestHook] WOOW_TEST_AUTOTAP eval error: \(error.localizedDescription)")
            }
        }
    }
    #endif

    // MARK: - OWL Layout Fixes (ported from Android)

    private func injectOWLLayoutFixes(webView: WKWebView) {
        let js = """
        (function() {
            document.body.style.minHeight = '100vh';
            document.body.style.height = '100%';
            document.documentElement.style.height = '100%';

            var am = document.querySelector('.o_action_manager');
            if (am) {
                am.style.minHeight = 'calc(100vh - 46px)';
                am.style.height = 'auto';
                am.style.overflow = 'auto';
            }

            window.dispatchEvent(new Event('resize'));
            setTimeout(function() { window.dispatchEvent(new Event('resize')); }, 100);
            setTimeout(function() { window.dispatchEvent(new Event('resize')); }, 500);
            setTimeout(function() { window.dispatchEvent(new Event('resize')); }, 1000);
        })();
        """
        webView.evaluateJavaScript(js) { _, error in
            #if DEBUG
            if let error {
                print("[OdooWebView] OWL layout fix failed: \(error.localizedDescription)")
            }
            #endif
        }
    }
}
