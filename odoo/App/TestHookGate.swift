import Foundation

/// Belt-and-suspenders gate for test-only debug hooks
/// (`WOOW_TEST_THEME_COLOR`, `WOOW_TEST_FORCE_BIOMETRIC`,
/// `WOOW_TEST_FORCE_PIN`, etc.).
///
/// Why both `#if DEBUG` AND a runtime gate?
///
///   - `#if DEBUG` is a compile-time strip. It works correctly for the
///     standard Debug/Release scheme split.
///   - However, App Store Review Guideline **2.3.1** prohibits hidden,
///     dormant, or undocumented features in shipping binaries. A
///     misconfigured CI matrix that archives a `Debug` configuration
///     (or a Release-with-debug-symbols variant) would otherwise leak
///     auth-bypass capabilities into a TestFlight or App Store build.
///   - The runtime gate adds a second independent check. Even if a
///     binary slips through with `DEBUG=1`, the hooks are inert unless
///     the test target's launch arguments also include `-WoowTestRunner`.
///     The XCUITest target adds this automatically; production launches
///     never include it.
///
/// To enable hooks in a real run (CI / local dev), the test target adds
/// `-WoowTestRunner` to `XCUIApplication.launchArguments`.
///
/// Reference: docs/2026-04-28-theme-color-not-applied-plan.md §
/// "App Store Compliance Hardening".
enum TestHookGate {

    /// Launch-argument marker that the XCUITest target sets to opt-in to
    /// debug test hooks. NOT documented to end users; not part of any
    /// public API surface.
    static let launchArgumentMarker = "-WoowTestRunner"

    /// True only when the binary is a DEBUG build AND was launched with
    /// `-WoowTestRunner`. Either condition alone is insufficient.
    static var testHooksEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(launchArgumentMarker)
        #else
        return false
        #endif
    }
}
