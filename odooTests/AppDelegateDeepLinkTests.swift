//
//  AppDelegateDeepLinkTests.swift
//  odooTests
//
//  Unit tests for AppDelegate.handleNotificationTap — verifies the bridge between
//  FCM notification payloads and DeepLinkManager.setPending(), including the guard
//  clause that rejects non-Odoo or malformed URLs.
//
//  Because handleNotificationTap calls DeepLinkManager.shared, these tests verify
//  the side effect via DeepLinkManager.shared.pendingUrl after injecting a known
//  state. Each test resets DeepLinkManager.shared by consuming any leftover URL
//  in setUp() to prevent test pollution.
//
//  Coverage: ADT-01, ADT-02, EC-07
//

import XCTest
@testable import odoo

@MainActor
final class AppDelegateDeepLinkTests: XCTestCase {

    private var sut: AppDelegate!

    override func setUp() async throws {
        try await super.setUp()
        sut = AppDelegate()
        // Clear any pending URL left by a previous test to prevent pollution.
        _ = DeepLinkManager.shared.consume()
    }

    override func tearDown() async throws {
        _ = DeepLinkManager.shared.consume()
        sut = nil
        try await super.tearDown()
    }

    // MARK: - ADT-01

    /// ADT-01: Verifies the bridge from FCM notification payload to DeepLinkManager.setPending().
    /// If this wire-up breaks, the entire deep-link feature is silently dead — no crash, just no navigation.
    func test_handleNotificationTap_givenUserInfoWithOdooActionUrl_setsDeepLinkManagerPendingUrl() {
        let userInfo: [AnyHashable: Any] = ["odoo_action_url": "/web#id=7&model=sale.order"]

        sut.handleNotificationTap(userInfo: userInfo)

        XCTAssertEqual(DeepLinkManager.shared.pendingUrl, "/web#id=7&model=sale.order",
                       "handleNotificationTap must forward valid odoo_action_url to DeepLinkManager")
    }

    // MARK: - ADT-02

    /// ADT-02: Notifications without `odoo_action_url` (e.g., FCM test messages or
    /// non-Odoo pushes) must not set any pending deep link.
    func test_handleNotificationTap_givenUserInfoWithNoOdooActionUrl_doesNotSetPendingUrl() {
        let userInfo: [AnyHashable: Any] = ["aps": ["alert": "Hello"]]

        sut.handleNotificationTap(userInfo: userInfo)

        XCTAssertNil(DeepLinkManager.shared.pendingUrl,
                     "handleNotificationTap must not set pendingUrl when odoo_action_url key is absent")
    }

    // MARK: - EC-07

    /// EC-07: Malformed or dangerous `odoo_action_url` values must be rejected by the
    /// guard clause in handleNotificationTap. Tests empty string, literal "null",
    /// external URL, and a valid-looking path that does not start with /web.
    func test_handleNotificationTap_givenMalformedActionUrl_doesNotSetDeepLink_emptyString() {
        let userInfo: [AnyHashable: Any] = ["odoo_action_url": ""]

        sut.handleNotificationTap(userInfo: userInfo)

        XCTAssertNil(DeepLinkManager.shared.pendingUrl,
                     "An empty odoo_action_url must not produce a pending deep link")
    }

    func test_handleNotificationTap_givenMalformedActionUrl_doesNotSetDeepLink_literalNull() {
        let userInfo: [AnyHashable: Any] = ["odoo_action_url": "null"]

        sut.handleNotificationTap(userInfo: userInfo)

        XCTAssertNil(DeepLinkManager.shared.pendingUrl,
                     "The literal string 'null' as odoo_action_url must not produce a pending deep link")
    }

    func test_handleNotificationTap_givenMalformedActionUrl_doesNotSetDeepLink_externalUrl() {
        let userInfo: [AnyHashable: Any] = ["odoo_action_url": "https://evil.com/phish"]

        sut.handleNotificationTap(userInfo: userInfo)

        XCTAssertNil(DeepLinkManager.shared.pendingUrl,
                     "An external URL as odoo_action_url must be rejected and not set as pending deep link")
    }

    func test_handleNotificationTap_givenMalformedActionUrl_doesNotSetDeepLink_nonWebPath() {
        let userInfo: [AnyHashable: Any] = ["odoo_action_url": "/api/v2/data"]

        sut.handleNotificationTap(userInfo: userInfo)

        XCTAssertNil(DeepLinkManager.shared.pendingUrl,
                     "A path not starting with /web must be rejected as odoo_action_url")
    }
}
