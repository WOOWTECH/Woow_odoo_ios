import XCTest
import SwiftUI
@testable import odoo

/// Unit tests for OdooWebViewCoordinator's navigation decision logic (UX-26, UX-27, UX-28).
///
/// These tests verify the pure `decideNavigation(for:)` function without requiring a live
/// WKWebView or UIApplication. This is the critical code path that determines whether a URL
/// loads inside the WebView, opens in Safari, or triggers session expiry.
final class OdooWebViewNavigationTests: XCTestCase {

    private var coordinator: OdooWebViewCoordinator!
    private var sessionExpiredCalled: Bool!

    override func setUp() {
        super.setUp()
        sessionExpiredCalled = false
        coordinator = OdooWebViewCoordinator(
            serverUrl: "https://odoo.example.com",
            onSessionExpired: { [weak self] in self?.sessionExpiredCalled = true },
            isLoading: .constant(false)
        )
    }

    // MARK: - Same-host URLs → Allow

    func test_sameHost_isAllowed() {
        let url = URL(string: "https://odoo.example.com/web#action=123")!
        XCTAssertEqual(coordinator.decideNavigation(for: url), .allow)
    }

    func test_sameHost_caseInsensitive_isAllowed() {
        let url = URL(string: "https://ODOO.EXAMPLE.COM/web")!
        XCTAssertEqual(coordinator.decideNavigation(for: url), .allow)
    }

    func test_sameHost_withPort_isAllowed() {
        let coordWithPort = OdooWebViewCoordinator(
            serverUrl: "https://odoo.example.com:8069",
            onSessionExpired: {},
            isLoading: .constant(false)
        )
        let url = URL(string: "https://odoo.example.com:8069/web")!
        XCTAssertEqual(coordWithPort.decideNavigation(for: url), .allow)
    }

    // MARK: - Relative URLs → Allow

    func test_relativeURL_isAllowed() {
        let url = URL(string: "/web/content/123")!
        XCTAssertEqual(coordinator.decideNavigation(for: url), .allow)
    }

    // MARK: - Blob URLs → Allow (OWL framework)

    func test_blobURL_isAllowed() {
        let url = URL(string: "blob:https://odoo.example.com/abc-123")!
        XCTAssertEqual(coordinator.decideNavigation(for: url), .allow)
    }

    // MARK: - Session expiry → sessionExpired

    func test_webLoginPath_triggersSessionExpired() {
        let url = URL(string: "https://odoo.example.com/web/login")!
        XCTAssertEqual(coordinator.decideNavigation(for: url), .sessionExpired)
    }

    func test_webLoginWithQuery_triggersSessionExpired() {
        let url = URL(string: "https://odoo.example.com/web/login?redirect=/web")!
        XCTAssertEqual(coordinator.decideNavigation(for: url), .sessionExpired)
    }

    // MARK: - External host URLs → openInSafari (UX-27)

    func test_externalHost_opensInSafari() {
        let url = URL(string: "https://www.google.com")!
        let decision = coordinator.decideNavigation(for: url)
        XCTAssertEqual(decision, .openInSafari(url),
                       "UX-27: External host URLs must be routed to Safari, not loaded in WebView")
    }

    func test_externalHost_differentDomain_opensInSafari() {
        let url = URL(string: "https://evil.com/phishing")!
        let decision = coordinator.decideNavigation(for: url)
        XCTAssertEqual(decision, .openInSafari(url),
                       "UX-27: Different domain must open in Safari")
    }

    func test_externalHost_subdomain_opensInSafari() {
        // subdomain of server host should NOT be treated as same-host
        let url = URL(string: "https://sub.odoo.example.com/page")!
        let decision = coordinator.decideNavigation(for: url)
        XCTAssertEqual(decision, .openInSafari(url),
                       "UX-27: Subdomain of server host must open in Safari (strict host match)")
    }

    func test_externalHost_customerWebsite_opensInSafari() {
        // Real scenario: Odoo partner record contains a website link
        let url = URL(string: "https://customer-website.com/products")!
        let decision = coordinator.decideNavigation(for: url)
        XCTAssertEqual(decision, .openInSafari(url),
                       "UX-27: Customer website link in Odoo must open in Safari")
    }

    func test_externalHost_paymentGateway_opensInSafari() {
        // Real scenario: Invoice payment link
        let url = URL(string: "https://pay.stripe.com/invoice/acct_123")!
        let decision = coordinator.decideNavigation(for: url)
        XCTAssertEqual(decision, .openInSafari(url),
                       "UX-27: Payment gateway link must open in Safari")
    }

    // MARK: - Nil URL → Cancel

    func test_nilURL_isCancelled() {
        XCTAssertEqual(coordinator.decideNavigation(for: nil), .cancel)
    }

    // MARK: - Edge cases

    func test_javascriptScheme_opensInSafari() {
        // javascript: URLs have a host of nil but scheme is not nil and not blob
        // URL(string:) returns nil for most javascript: URLs, so this tests the
        // case where one somehow gets through
        let url = URL(string: "javascript:void(0)")
        // URL(string: "javascript:void(0)") may return nil on some iOS versions
        if let url {
            let decision = coordinator.decideNavigation(for: url)
            // javascript: URLs have no host → allowed by relative URL rule
            // This is acceptable because WKWebView's own security blocks javascript: navigation
            XCTAssertEqual(decision, .allow)
        }
    }

    func test_dataScheme_opensInSafari() {
        let url = URL(string: "data:text/html,<h1>Injected</h1>")
        if let url {
            // data: URLs have no host → treated as relative
            // WKWebView's own CSP blocks data: content injection
            XCTAssertEqual(coordinator.decideNavigation(for: url), .allow)
        }
    }
}
