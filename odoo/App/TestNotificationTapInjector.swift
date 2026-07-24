#if DEBUG

import Foundation
import UIKit

/// Test-only holder that defers a synthetic notification tap until the app's WebView has
/// loaded the ACTIVE (seeded) account, then fires it exactly once through the SAME production
/// path a real tap uses (`AppDelegate.handleNotificationTap`).
///
/// Why deferred instead of fired at launch: the cross-account bug was "account A already
/// showing, tap account B's notification, WebView stayed on A". Firing at launch — before A
/// ever loads — would prove the router in isolation but NOT the switch away from a *loaded* A.
/// So the injector arms at launch from `WOOW_TEST_NOTIFICATION_TAP` and fires on the first
/// `didFinish` (account A's page), reproducing the warm cross-account tap end to end.
///
/// The payload is delivered verbatim as the notification `userInfo`, so the XCUITest controls
/// the exact shape the Odoo plugin would send, e.g.
/// `{"odoo_tenant_id":"demo666","odoo_action_url":"/web#action=mail.action_discuss"}`.
///
/// Compiled out of Release (`#if DEBUG`); the arm site is additionally gated by `TestHookGate`.
final class TestNotificationTapInjector: NSObject {

    static let shared = TestNotificationTapInjector()
    private override init() { super.init() }

    private var armedPayload: [AnyHashable: Any]?
    private var hasFired = false
    /// When true (env `WOOW_TEST_NOTIFICATION_TAP_MODE=button`), the payload is NOT auto-fired on
    /// page load; it fires only when the XCUITest taps the hidden `e2e-fire-tap` button — so the
    /// tap happens AFTER the test has logged in and selected the active account, with reliable
    /// timing (a real springboard notification tap is flaky and, when it opens the app via the
    /// folded group summary, never invokes `handleNotificationTap` at all).
    private var manualFireOnly = false
    private weak var fireButton: UIButton?
    /// Direct reference to the app delegate, captured at arm time. On this SwiftUI app,
    /// `UIApplication.shared.delegate as? AppDelegate` returns nil on device (the adaptor exposes
    /// the delegate only as the `UIApplicationDelegate` existential), so the injection must call
    /// the delegate we were handed rather than re-resolving it through the shared application.
    private weak var appDelegate: AppDelegate?

    /// Arms the injector from the `WOOW_TEST_NOTIFICATION_TAP` environment variable (a JSON
    /// object). No-op when unset or invalid, so non-deep-link tests are unaffected. `delegate` is
    /// the live `AppDelegate` (the caller), used to invoke the production tap handler reliably.
    func armFromEnvironment(delegate: AppDelegate) {
        appDelegate = delegate
        armFromEnvironment()
    }

    /// Arms the injector from the `WOOW_TEST_NOTIFICATION_TAP` environment variable (a JSON
    /// object). No-op when unset or invalid, so non-deep-link tests are unaffected.
    func armFromEnvironment() {
        guard let json = ProcessInfo.processInfo.environment["WOOW_TEST_NOTIFICATION_TAP"],
              !json.isEmpty,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        armedPayload = obj
        manualFireOnly = ProcessInfo.processInfo.environment["WOOW_TEST_NOTIFICATION_TAP_MODE"] == "button"
        print("[TestHook] WOOW_TEST_NOTIFICATION_TAP armed with keys: \(obj.keys.sorted()) manualFireOnly=\(manualFireOnly)")
    }

    /// Fires the armed payload once, on the main actor, through the production tap handler.
    /// Called from `OdooWebView`'s `didCommit`/`didFinish` after the active account's first page
    /// load. No-op in button mode (the test fires it explicitly) and after the first fire.
    func fireOnceAfterActiveLoad() {
        guard !manualFireOnly, let payload = armedPayload, !hasFired else { return }
        hasFired = true
        let delegate = appDelegate
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                (delegate ?? UIApplication.shared.delegate as? AppDelegate)?.handleNotificationTap(userInfo: payload)
                print("[TestHook] WOOW_TEST_NOTIFICATION_TAP fired through handleNotificationTap")
            }
        }
    }

    /// Fires the armed payload immediately through the production tap handler. Invoked by the
    /// hidden `e2e-fire-tap` button so the test controls WHEN the cross-account tap arrives.
    @MainActor
    func fireNow() {
        let target = appDelegate ?? (UIApplication.shared.delegate as? AppDelegate)
        E2EWebViewProbe.shared.publish(
            id: "e2e-fire-btn",
            value: "fireNow armed=\(armedPayload != nil) haveDelegate=\(target != nil)")
        guard let payload = armedPayload, let target else { return }
        target.handleNotificationTap(userInfo: payload)
        print("[TestHook] e2e-fire-tap fired through handleNotificationTap")
    }

    /// Installs a near-invisible key-window button (`e2e-fire-tap`) the XCUITest taps to trigger
    /// the armed payload on demand. Only in button mode with a payload armed; idempotent.
    @MainActor
    func installFireButtonIfNeeded() {
        guard manualFireOnly, armedPayload != nil, TestHookGate.testHooksEnabled else { return }
        guard let window = Self.keyWindow() else { return }
        if let existing = fireButton, existing.window === window {
            window.bringSubviewToFront(existing)
            return
        }
        fireButton?.removeFromSuperview()
        let button = UIButton(type: .custom)
        button.frame = CGRect(x: 0, y: 120, width: 220, height: 30)
        button.accessibilityIdentifier = "e2e-fire-tap"
        button.isAccessibilityElement = true
        button.alpha = 0.02 // present in the a11y tree, invisible to the user
        button.setTitle("e2e-fire-tap", for: .normal)
        button.addTarget(self, action: #selector(fireButtonTapped), for: .touchUpInside)
        window.addSubview(button)
        window.bringSubviewToFront(button)
        fireButton = button
        startTenantProbeRepublishing()
    }

    private var tenantProbeTimer: Timer?

    /// Keeps the `e2e-account-tenants` probe fresh (every second) so a test can wait for the app to
    /// persist an account's tenantId via async FCM registration before firing the cross-account tap.
    @MainActor
    private func startTenantProbeRepublishing() {
        guard tenantProbeTimer == nil else { return }
        tenantProbeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let tenants = AccountRepository().getAllAccounts()
                    .map { $0.tenantId ?? "nil" }
                    .joined(separator: ",")
                E2EWebViewProbe.shared.publish(id: "e2e-account-tenants", value: tenants)
            }
        }
    }

    @objc private func fireButtonTapped() {
        MainActor.assumeIsolated { fireNow() }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

#endif
