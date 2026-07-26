import Foundation

/// The auth-gate action for the App Lock screen, decided purely from the enabled methods.
///
/// Ported from the Android `AuthOptions` model so the biometric-vs-PIN routing is a small,
/// unit-testable function instead of ad-hoc SwiftUI `@State`. The critical property is that it
/// **fails closed**: when App Lock is on but no method is usable, it returns `.setupRequired`
/// (a blocking screen), never `.none` — so a revoked Face ID permission or an OS biometry-lockout
/// on a biometric-only device can never drop the user into the app unlocked.
enum AuthAction: Equatable {
    /// Biometric first, with a "Use PIN" escape button.
    case biometricAndPin
    /// PIN keypad directly — no biometric page.
    case pinOnly
    /// Biometric only — no PIN escape anywhere.
    case biometricOnly
    /// App Lock is ON but no method is usable → force method setup / device passcode. FAIL CLOSED.
    case setupRequired
    /// App Lock is OFF → no lock screen.
    case none
}

/// Resolves which auth-gate action to show.
///
/// - Parameters:
///   - canUseBiometric: biometric is enabled AND currently available (`LAContext.canEvaluatePolicy`).
///     This already subsumes "biometric enabled", so a separate `biometricEnabled` flag is not passed.
///   - pinEnabled: a PIN is configured.
///   - appLockEnabled: the App Lock master switch is on.
/// - Returns: the action to render. `.none` is returned **only** when `appLockEnabled == false`.
func resolveAuthAction(canUseBiometric: Bool, pinEnabled: Bool, appLockEnabled: Bool) -> AuthAction {
    // .none ONLY when App Lock is off — otherwise the gate must resolve to a real screen.
    guard appLockEnabled else { return .none }
    switch (canUseBiometric, pinEnabled) {
    case (true, true):   return .biometricAndPin
    case (true, false):  return .biometricOnly
    case (false, true):  return .pinOnly
    // App Lock on, no usable method: fail CLOSED — block, never open the app.
    case (false, false): return .setupRequired
    }
}
