import XCTest
@testable import odoo

/// Tests for `resolveAuthAction` — the App Lock auth-gate routing, with emphasis on the
/// security-critical fail-closed case (App Lock on but no usable method must NOT unlock).
final class AuthActionTests: XCTestCase {

    // MARK: - App Lock off → never locked

    func test_appLockOff_returnsNone_regardlessOfMethods() {
        XCTAssertEqual(resolveAuthAction(canUseBiometric: true,  pinEnabled: true,  appLockEnabled: false), .none)
        XCTAssertEqual(resolveAuthAction(canUseBiometric: false, pinEnabled: false, appLockEnabled: false), .none)
        XCTAssertEqual(resolveAuthAction(canUseBiometric: true,  pinEnabled: false, appLockEnabled: false), .none)
        XCTAssertEqual(resolveAuthAction(canUseBiometric: false, pinEnabled: true,  appLockEnabled: false), .none)
    }

    // MARK: - The four routing combinations (App Lock on)

    func test_biometricAndPin() {
        XCTAssertEqual(resolveAuthAction(canUseBiometric: true, pinEnabled: true, appLockEnabled: true), .biometricAndPin)
    }

    func test_biometricOnly() {
        XCTAssertEqual(resolveAuthAction(canUseBiometric: true, pinEnabled: false, appLockEnabled: true), .biometricOnly)
    }

    func test_pinOnly_whenBiometricUnavailable() {
        // Face ✗ (disabled OR enabled-but-unavailable) / PIN ✓ → straight to PIN, never the biometric page.
        XCTAssertEqual(resolveAuthAction(canUseBiometric: false, pinEnabled: true, appLockEnabled: true), .pinOnly)
    }

    // MARK: - Fail-closed security case

    func test_appLockOn_noUsableMethod_failsClosed_notNone() {
        // App Lock on, biometric not usable (revoked/locked-out), no PIN → MUST block, never .none.
        let action = resolveAuthAction(canUseBiometric: false, pinEnabled: false, appLockEnabled: true)
        XCTAssertEqual(action, .setupRequired)
        XCTAssertNotEqual(action, .none, "App Lock on with no usable method must never resolve to .none (would open the app unlocked)")
    }

    func test_none_isProducedOnlyWhenAppLockOff() {
        // Exhaustive: .none appears iff appLockEnabled == false.
        for canUseBiometric in [true, false] {
            for pinEnabled in [true, false] {
                let onAction = resolveAuthAction(canUseBiometric: canUseBiometric, pinEnabled: pinEnabled, appLockEnabled: true)
                XCTAssertNotEqual(onAction, .none, "App Lock ON must never resolve to .none (bio=\(canUseBiometric), pin=\(pinEnabled))")
                let offAction = resolveAuthAction(canUseBiometric: canUseBiometric, pinEnabled: pinEnabled, appLockEnabled: false)
                XCTAssertEqual(offAction, .none)
            }
        }
    }
}
