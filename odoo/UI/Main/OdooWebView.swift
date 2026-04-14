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

        let webView = WKWebView(frame: .zero, configuration: config)
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

    init(serverUrl: String, onSessionExpired: @escaping () -> Void, isLoading: Binding<Bool>) {
        self.serverUrl = serverUrl
        self.onSessionExpired = onSessionExpired
        self._isLoading = isLoading
        self.serverHost = URL(string: serverUrl)?.host ?? ""
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
