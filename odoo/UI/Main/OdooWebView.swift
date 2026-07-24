import CoreLocation
import SwiftUI
import WebKit

/// WKWebView wrapper for displaying Odoo web UI.
/// Ported from Android: MainScreen.kt OdooWebView composable.
/// UX-25 through UX-34.
///
/// Single-view account switching (P0 cross-tenant fix): this representable is **never**
/// recreated on account change (no `.id(account)`). Instead `updateUIView` drives all
/// transitions through the coordinator, which hosts a per-account child `WKWebView` inside a
/// stable container. Switching accounts swaps the child WebView so each account gets its own
/// `WKWebsiteDataStore` (isolated cookies), while the SwiftUI identity — and the location
/// bridge — persists.
struct OdooWebView: UIViewRepresentable {
    let serverUrl: String
    let database: String
    /// The active account's id. Drives per-account data-store isolation and deep-link binding.
    let accountId: String
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

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        context.coordinator.attach(to: container)
        context.coordinator.apply(
            serverUrl: serverUrl,
            database: database,
            accountId: accountId,
            sessionId: sessionId,
            deepLink: deepLinkUrl
        )
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // The single mutation entry point: reload on account/server change, or drive a
        // warm same-account deep-link navigation. All logic lives in the coordinator.
        context.coordinator.apply(
            serverUrl: serverUrl,
            database: database,
            accountId: accountId,
            sessionId: sessionId,
            deepLink: deepLinkUrl
        )
    }
}

/// WKWebView delegate handling navigation policy, OWL fixes, security, and — new for the
/// multi-account fix — per-account WebView lifecycle and load-gated deep-link application.
final class OdooWebViewCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let onSessionExpired: () -> Void
    @Binding var isLoading: Bool

    /// Owns the location coordinator for the lifetime of this WebView coordinator.
    /// `lazy` so its `activeAccountHost` closure can capture `self` and always report the
    /// current account's host after a switch (avoids the Android stale-closure bug).
    private(set) lazy var locationCoordinator: LocationCoordinator = LocationCoordinator(
        gate: LocationPermissionGate(),
        activeAccountHost: { [weak self] in self?.currentServerHost }
    )

    /// Stable host container; the per-account child WebView is swapped inside it.
    private weak var container: UIView?
    /// The child WebView for the current account, or nil before the first `apply`.
    private var webView: WKWebView?

    // Current account state — mutated only in `apply` on the main thread.
    private var currentAccountId: String?
    private var currentServerUrl: String
    private(set) var currentServerHost: String
    private var currentDatabase: String = ""

    /// A deep link captured on account switch, applied once in `didFinish` when the loaded
    /// host matches the target (load-gated). Cleared on apply so it fires exactly once.
    private var pendingDeepLink: String?
    /// The last deep link seen, to detect a NEW warm same-account link.
    private var lastDeepLink: String?

    #if DEBUG
    private var testProxy: JSBridgeMessageHandlerProxy?
    /// Hidden accessibility element carrying the currently-loaded WebView URL, so an
    /// out-of-process XCUITest can assert which server/room the WebView landed on.
    private var e2eProbeLabel: UILabel?
    #endif

    init(serverUrl: String, onSessionExpired: @escaping () -> Void, isLoading: Binding<Bool>) {
        self.onSessionExpired = onSessionExpired
        self._isLoading = isLoading
        self.currentServerUrl = serverUrl
        self.currentServerHost = URL(string: serverUrl)?.host ?? ""
        super.init()
    }

    // MARK: - Container wiring

    /// Records the stable container view the child WebViews are hosted inside.
    func attach(to container: UIView) {
        self.container = container
    }

    // MARK: - Single mutation entry point

    /// Reconciles the WebView with the desired account state.
    ///
    /// - On account or server change (or first call): builds a fresh child WebView with the
    ///   target account's isolated data store, injects that account's session cookie, loads
    ///   the base page, and captures any deep link to apply once the load finishes.
    /// - On the same account with a NEW deep link (warm foreground tap): drives navigation
    ///   directly with a full `load()` of the `/web#…` URL. Odoo 18's path router ignores
    ///   `location.hash`, so a full load is required for the deep link to take effect (see
    ///   `deepLinkApplyPlan`).
    func apply(serverUrl: String, database: String, accountId: String, sessionId: String?, deepLink: String?) {
        let switched = webView == nil
            || accountId != currentAccountId
            || serverUrl != currentServerUrl

        if switched {
            currentAccountId = accountId
            currentServerUrl = serverUrl
            currentServerHost = URL(string: serverUrl)?.host ?? ""
            currentDatabase = database
            lastDeepLink = deepLink
            pendingDeepLink = (deepLink?.isEmpty == false) ? deepLink : nil
            rebuildWebView(accountId: accountId, serverUrl: serverUrl, database: database, sessionId: sessionId)
        } else if let deepLink, !deepLink.isEmpty, deepLink != lastDeepLink {
            lastDeepLink = deepLink
            applyDeepLink(deepLink)
            consumePending(for: accountId)
        }
    }

    // MARK: - Per-account WebView construction

    private func rebuildWebView(accountId: String, serverUrl: String, database: String, sessionId: String?) {
        let config = makeConfiguration(accountId: accountId)
        let newWebView = WKWebView(frame: .zero, configuration: config)
        newWebView.navigationDelegate = self
        newWebView.uiDelegate = self
        newWebView.allowsBackForwardNavigationGestures = true

        #if DEBUG
        testProxy?.webView = newWebView
        #endif

        // Swap the child WebView inside the stable container.
        webView?.removeFromSuperview()
        webView = newWebView
        if let container {
            newWebView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(newWebView)
            NSLayoutConstraint.activate([
                newWebView.topAnchor.constraint(equalTo: container.topAnchor),
                newWebView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                newWebView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                newWebView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        // Inject the target account's session cookie into ITS OWN data store before loading,
        // then load the base page. The deep link (if any) is applied load-gated in didFinish.
        let store = config.websiteDataStore
        if let sessionId,
           let host = URL(string: serverUrl)?.host,
           let cookie = HTTPCookie(properties: [
               .name: "session_id",
               .value: sessionId,
               .domain: host,
               .path: "/",
               .secure: "TRUE",
           ]) {
            store.httpCookieStore.setCookie(cookie) { [weak self] in
                self?.loadBase(into: newWebView, serverUrl: serverUrl, database: database)
            }
        } else {
            loadBase(into: newWebView, serverUrl: serverUrl, database: database)
        }
    }

    private func makeConfiguration(accountId: String) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // App Store hardening: do NOT let pages spawn popup windows via window.open()
        // without a user gesture. The WKUIDelegate below still routes legitimate
        // target="_blank" clicks back into the same WebView.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Per-account isolated cookie/data store — account A's cookies can never load under
        // account B (P0 cross-tenant isolation). iOS 17+ gets a durable per-identifier store;
        // older OSes and legacy/empty account ids fall back to the shared default store.
        config.websiteDataStore = Self.dataStore(forAccountId: accountId)

        // Install the geolocation shim so it runs before any page JavaScript.
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
        let proxy = LocationMessageHandlerProxy(coordinator: locationCoordinator)
        config.userContentController.add(proxy, name: "requestLocation")

        #if DEBUG
        // Debug-only test bridge: lets XCUITests inject JS via "__woowTestEval" handler.
        let testProxy = JSBridgeMessageHandlerProxy()
        config.userContentController.add(testProxy, name: "__woowTestEval")
        self.testProxy = testProxy
        #endif

        return config
    }

    private func loadBase(into webView: WKWebView, serverUrl: String, database: String) {
        guard let url = Self.baseURL(serverUrl: serverUrl, database: database) else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: - Deep-link application

    /// Applies `deepLink` to the current WebView via a full navigation to the resolved `/web#…`
    /// URL. There is no `location.hash` fast-path: Odoo 18's path router (`/odoo/...`) ignores
    /// `location.hash`/`hashchange`, so a full `load()` is the only reliable way to apply a deep
    /// link. Odoo migrates the legacy hash to the correct `/odoo/...` route at boot.
    private func applyDeepLink(_ deepLink: String) {
        guard let webView else { return }
        guard let plan = Self.deepLinkApplyPlan(
            currentURL: webView.url,
            targetServerUrl: currentServerUrl,
            deepLink: deepLink
        ) else { return }

        switch plan {
        case .load(let url):
            webView.load(URLRequest(url: url))
        }
    }

    /// Clears the pending link from the shared manager on the main actor (single-consume).
    private func consumePending(for accountId: String) {
        Task { @MainActor in
            _ = DeepLinkManager.shared.consume(for: accountId)
        }
    }

    // MARK: - Pure navigation helpers (unit-tested)

    /// The base Odoo web URL for an account.
    ///
    /// A single trailing `/` on `serverUrl` is trimmed before concatenation so a configured
    /// `https://host/` does not produce a double slash (`https://host//web?...`), matching
    /// Android's `fullLoadUrl` (`trimEnd('/')`).
    static func baseURL(serverUrl: String, database: String) -> URL? {
        let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        return URL(string: "\(base)/web?db=\(database)")
    }

    /// Resolves a deep-link path/URL against a server. Relative paths are joined to the server;
    /// absolute URLs are returned as-is (already validated by `DeepLinkValidator`).
    ///
    /// A single trailing `/` on `serverUrl` is trimmed before joining a leading-slash `deepLink`
    /// so `https://host/` + `/web#…` yields a single-slash `https://host/web#…` (not `//web`),
    /// matching Android's `fullLoadUrl` (`trimEnd('/')`).
    static func resolveDeepLinkURL(serverUrl: String, deepLink: String) -> URL? {
        if deepLink.hasPrefix("/") {
            let base = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
            return URL(string: base + deepLink)
        }
        return URL(string: deepLink)
    }

    /// How a validated deep link should be applied to a WebView.
    enum DeepLinkApplyPlan: Equatable {
        /// Perform a full navigation to this URL.
        case load(URL)
    }

    /// Decides how to apply `deepLink`, returning `nil` if it fails validation.
    ///
    /// Always resolves to a full `.load()` of the `/web#…` URL; there is no `location.hash` poke.
    /// Odoo 18's path router (`/odoo/discuss`, `/odoo/<model>/<id>`) IGNORES
    /// `location.hash`/`hashchange` entirely, so poking the hash does nothing and every tap would
    /// stay on the default `/odoo` (Discuss Inbox). A full cross-document load of `/web#action=…`
    /// is correct everywhere: the `/web`→`/odoo` redirect preserves the URL fragment, and Odoo
    /// parses the legacy `#action=…&active_id=discuss.channel_<id>` hash at boot (web router
    /// `parseHash`/`sanitizeHash`) and migrates it to the correct `/odoo/...` path route.
    static func deepLinkApplyPlan(currentURL: URL?, targetServerUrl: String, deepLink: String) -> DeepLinkApplyPlan? {
        let targetHost = URL(string: targetServerUrl)?.host ?? ""
        guard DeepLinkValidator.isValid(url: deepLink, serverHost: targetHost) else { return nil }
        guard let target = resolveDeepLinkURL(serverUrl: targetServerUrl, deepLink: deepLink) else { return nil }
        return .load(target)
    }

    /// The data store for an account. iOS 17+ real (UUID) account ids get an isolated
    /// per-identifier store; otherwise the shared default store is used.
    static func dataStore(forAccountId id: String) -> WKWebsiteDataStore {
        if #available(iOS 17.0, *), let uuid = UUID(uuidString: id) {
            return WKWebsiteDataStore(forIdentifier: uuid)
        }
        return .default()
    }

    // MARK: - Navigation Decision (extracted for testability)

    /// The result of evaluating a URL against the WebView navigation policy.
    enum NavigationDecision: Equatable {
        case allow
        case sessionExpired
        case openInSafari(URL)
        case cancel
    }

    /// Pure function that decides what to do with a navigation URL. No side effects.
    func decideNavigation(for url: URL?) -> NavigationDecision {
        guard let url else { return .cancel }

        // Session expiry detection
        if url.absoluteString.contains("/web/login") {
            return .sessionExpired
        }

        // Same-host: allow
        if let host = url.host, host.caseInsensitiveCompare(currentServerHost) == .orderedSame {
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The URL is committed here (before the page fully finishes). Publish it to the XCUITest
        // probe now so the test can read the landed host even if `didFinish` is delayed by
        // Odoo's long-lived bus/longpolling connection.
        #if DEBUG
        publishE2EWebViewProbe(url: webView.url)
        // Fire any armed synthetic notification tap here (not only in didFinish): Odoo's OWL SPA
        // holds a long-poll connection that can delay `didFinish` indefinitely, so relying on
        // didFinish meant the cross-account tap never fired. `fireOnceAfterActiveLoad` is guarded
        // to run exactly once (on the active account's first commit).
        TestNotificationTapInjector.shared.fireOnceAfterActiveLoad()
        // In button mode, expose the hidden `e2e-fire-tap` element so the test can trigger the
        // cross-account tap on demand once it has logged in + selected the active account.
        MainActor.assumeIsolated { TestNotificationTapInjector.shared.installFireButtonIfNeeded() }
        #endif
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        injectOWLLayoutFixes(webView: webView)
        #if DEBUG
        injectTestAutoTapIfRequested(webView: webView)
        // Expose the loaded URL to XCUITest, then (once) fire any armed synthetic notification
        // tap now that the active account's page is on screen. Order matters: publish A's URL
        // first so a test that asserts "was on A before the tap" can observe it.
        publishE2EWebViewProbe(url: webView.url)
        TestNotificationTapInjector.shared.fireOnceAfterActiveLoad()
        #endif

        // Load-gated deep-link apply: only when the finished page is on the TARGET host.
        // This closes the async race and guarantees a link never applies to account A.
        if let pending = pendingDeepLink,
           let host = webView.url?.host,
           host.caseInsensitiveCompare(currentServerHost) == .orderedSame {
            pendingDeepLink = nil
            applyDeepLink(pending)
            consumePending(for: currentAccountId ?? "")
        }
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

    /// Performs a JS click on the element described by `WOOW_TEST_AUTOTAP` after each page
    /// load. Used by XCUITest when WKWebView accessibility queries are unreliable. Compiled
    /// out of Release builds.
    #if DEBUG
    /// Publishes the currently-loaded WebView URL to a hidden accessibility element
    /// (`identifier == "e2e-webview-url"`) that an out-of-process XCUITest can read.
    ///
    /// This is the ONLY reliable way for XCUITest to assert which server/room the WebView
    /// actually landed on: WKWebView does not surface its URL through the accessibility tree,
    /// and the `__woowTestEval` bridge returns results into the *page's* JavaScript, not to the
    /// test process. Gated by `TestHookGate`; the label is invisible to real users.
    func publishE2EWebViewProbe(url: URL?) {
        // Delegate to a key-window-hosted singleton so the probe survives the WebView rebuild
        // that happens on an account switch (a container-scoped label would be destroyed exactly
        // during the cross-account transition we need to observe).
        E2EWebViewProbe.shared.update(url?.absoluteString ?? "")
        // Also expose each account's stored tenantId so a test can wait until FCM registration has
        // persisted it before firing a cross-account notification tap (the real-login → register →
        // tap path drops as `unresolvedTenant` if the tap arrives before registration completes).
        if TestHookGate.testHooksEnabled {
            let tenants = AccountRepository().getAllAccounts()
                .map { $0.tenantId ?? "nil" }
                .joined(separator: ",")
            E2EWebViewProbe.shared.publish(id: "e2e-account-tenants", value: tenants)
        }
    }

    private func injectTestAutoTapIfRequested(webView: WKWebView) {
        guard TestHookGate.testHooksEnabled,
              let selector = ProcessInfo.processInfo.environment["WOOW_TEST_AUTOTAP"],
              !selector.isEmpty else { return }

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
            if let error {
                AppLogger.webview.error("OWL layout fix failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
