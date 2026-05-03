import XCTest
@testable import odoo

/// Validates the App Store 2.3.1 belt-and-suspenders gate for debug
/// test hooks. The gate must be:
///   1. False when run as a normal app launch (no `-WoowTestRunner`)
///   2. True only inside the XCUITest target which sets `-WoowTestRunner`
///
/// `#if DEBUG` is the build-time guard. The runtime arg gate is the
/// secondary defense if a misconfigured CI ships a Debug archive.
final class TestHookGateTest: XCTestCase {

    func test_marker_isStableSymbol() {
        // The launch-arg marker MUST NOT change without coordinated
        // updates to every XCUITest setUp. Pin the literal so a typo or
        // accidental rename trips this test.
        XCTAssertEqual(TestHookGate.launchArgumentMarker, "-WoowTestRunner")
    }

    func test_testHooksEnabled_isFalseInUnitTestProcess() {
        // Unit tests run under `xctest` which does NOT add the marker —
        // production-side code reading `testHooksEnabled` from a unit
        // test should see `false`. This test would fail if a future
        // refactor makes the gate "always true in DEBUG".
        XCTAssertFalse(TestHookGate.testHooksEnabled)
    }

    // MARK: - Per-hook inertness (H2/H3)

    /// `WOOW_SEED_ACCOUNT` (H2) — the env-var read sits inside
    /// `processTestLaunchArguments()`, which now begins with
    /// `guard TestHookGate.testHooksEnabled else { return }`. From a
    /// unit-test process the gate is false (no `-WoowTestRunner`), so
    /// even if `WOOW_SEED_ACCOUNT` were set in the environment the
    /// seeding code path would not execute.
    ///
    /// We assert the gate's value rather than calling the private
    /// AppDelegate method directly — the contract is the gate, not the
    /// implementation detail. If a future refactor moves the read
    /// outside the guarded block, the source-side audit
    /// (`scripts/audit_test_hook_naming.sh`) will still register the
    /// token and the binary-side audit will catch the leak.
    func test_seedAccountHook_isInertWithoutMarker() {
        XCTAssertFalse(
            TestHookGate.testHooksEnabled,
            "WOOW_SEED_ACCOUNT must not seed an account when the gate is false"
        )
    }

    /// `WOOW_TEST_AUTOTAP` (H3) — `OdooWebView.injectTestAutoTapIfRequested`
    /// now begins with `guard TestHookGate.testHooksEnabled, ... else { return }`.
    /// The hook used to be guarded only by `#if DEBUG`, which would let
    /// a misconfigured Debug archive accept arbitrary JS injection
    /// against any loaded page (App Store 2.3.1 ship-stopper).
    func test_autoTapHook_isInertWithoutMarker() {
        XCTAssertFalse(
            TestHookGate.testHooksEnabled,
            "WOOW_TEST_AUTOTAP must not inject JS when the gate is false"
        )
    }
}
