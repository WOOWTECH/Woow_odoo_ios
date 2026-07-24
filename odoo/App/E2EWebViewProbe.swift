#if DEBUG

import UIKit

/// A single, persistent accessibility element that mirrors the WebView's currently-loaded URL
/// so an out-of-process XCUITest can read where the app landed.
///
/// Why a key-window singleton instead of a label inside `OdooWebView`'s container: an account
/// switch REBUILDS the WebView (and can recreate the SwiftUI representable's container), which
/// would destroy a container-scoped probe exactly during the cross-account transition we most
/// need to observe. Hosting one label on the key window keeps the probe alive across every
/// rebuild, so the test always finds `e2e-webview-url`.
///
/// Gated by `TestHookGate`; the label is near-transparent and never interferes with the user.
final class E2EWebViewProbe {

    static let shared = E2EWebViewProbe()
    private init() {}

    /// One persistent label per accessibility identifier, so several diagnostics (the WebView URL
    /// AND, e.g., the notification-tap routing decision) can coexist without clobbering each other.
    private var labels: [String: UILabel] = [:]
    /// Vertical slot assignment so multiple probe labels don't overlap in the a11y tree.
    private var nextY: CGFloat = 60

    /// Publishes `urlString` to the `e2e-webview-url` accessibility element.
    func update(_ urlString: String) {
        publish(id: "e2e-webview-url", value: urlString)
    }

    /// Publishes `value` to the accessibility element identified by `id`, creating it on first use.
    /// Safe to call from the main thread. Used to expose out-of-process-readable diagnostics to an
    /// XCUITest (e.g. the routing decision a notification tap produced).
    func publish(id: String, value: String) {
        guard TestHookGate.testHooksEnabled else { return }
        guard let window = Self.keyWindow() else { return }

        let element: UILabel
        if let existing = labels[id], existing.window === window {
            element = existing
        } else {
            labels[id]?.removeFromSuperview()
            // NON-ZERO frame: XCUITest omits zero-size views from the accessibility tree.
            let newLabel = UILabel(frame: CGRect(x: 0, y: nextY, width: 300, height: 22))
            nextY += 24
            newLabel.isAccessibilityElement = true
            newLabel.accessibilityIdentifier = id
            newLabel.alpha = 0.02 // in the a11y tree, invisible to the user
            newLabel.backgroundColor = .clear
            window.addSubview(newLabel)
            labels[id] = newLabel
            element = newLabel
        }
        window.bringSubviewToFront(element)
        element.text = value
        element.accessibilityValue = value
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

#endif
