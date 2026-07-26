import Foundation

/// What the App Lock gate should render. Derived by `AuthViewModel` from the pure `resolveAuthAction`
/// plus runtime prompt state, so the Views are render-only (no `LAContext`/`scenePhase`/decisions).
enum AppLockUIState: Equatable {
    /// Not locked — show the main content.
    case unlocked
    /// Biometric screen. `prompting` while the Face/Touch sheet is in flight; `error` after a failure;
    /// `showUsePin` only in the biometric+PIN combination.
    case biometric(prompting: Bool, error: String?, kind: BiometryKind, showUsePin: Bool)
    /// PIN keypad. `showBack` is false when PIN is the only method (nothing to go back to).
    case pin(showBack: Bool)
    /// App Lock on but no usable method — fail-closed device-passcode screen. `prompting` while the
    /// device-owner-auth sheet is in flight.
    case setupRequired(prompting: Bool, error: String?)
}
