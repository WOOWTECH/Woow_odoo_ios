import Foundation
import os

/// Centralized logging surface for production code paths.
///
/// Built on `os.Logger` (iOS 14+). Two reasons this exists rather than
/// bare `print()`:
///
///   1. **PII redaction by default in Release.** Interpolated values are
///      redacted in archived/system logs unless explicitly marked
///      `privacy: .public`. This is the project's enforcement for
///      Critical Rule T1.3 (never log secrets) — an accidental
///      `AppLogger.push.info("token: \(fcmToken)")` is automatically
///      redacted in Release whereas `print("token: \(fcmToken)")` would
///      leak.
///   2. **Subsystem + category routing** for `Console.app` and
///      `log stream` filtering on-device, which `print()` does not
///      provide.
///
/// **What does NOT use AppLogger:**
///   - Anything inside a `guard TestHookGate.testHooksEnabled else {}`
///     block — these are DEBUG-gated diagnostics meant for stdout
///     capture by XCUITest. They stay as `print("[TestHook] ...")`.
///   - XCUITest `[NotifStrategy]` logs in the test target.
///
/// **Privacy convention:**
///   - Default (no `privacy:` arg) → `.private` (redacted in Release).
///     Use this for tokens, keys, usernames, server URLs, anything
///     user-identifying.
///   - `privacy: .public` → visible in Release logs. Use for status
///     booleans, error messages from system frameworks, integer counts.
enum AppLogger {

    private static let subsystem = "io.woowtech.odoo"

    /// Authentication flows, session validation, login.
    static let auth = Logger(subsystem: subsystem, category: "auth")

    /// `URLSession`-level networking, JSON-RPC transport.
    static let network = Logger(subsystem: subsystem, category: "network")

    /// FCM, APNs, remote notifications, push token registration.
    static let push = Logger(subsystem: subsystem, category: "push")

    /// `WKWebView` lifecycle, navigation policy, OWL workarounds.
    static let webview = Logger(subsystem: subsystem, category: "webview")

    /// `AppSettings` reads/writes, settings repository.
    static let settings = Logger(subsystem: subsystem, category: "settings")

    /// Theme validation, color palette parsing.
    static let theme = Logger(subsystem: subsystem, category: "theme")

    /// AppDelegate lifecycle, scene phase, app launch.
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    /// `CLLocationManager` flows, permission gate, JS bridge.
    static let location = Logger(subsystem: subsystem, category: "location")

    /// Core Data, Keychain, on-disk persistence.
    static let data = Logger(subsystem: subsystem, category: "data")
}
