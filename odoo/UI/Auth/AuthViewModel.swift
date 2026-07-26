import Foundation

/// Owns the App Lock flow — biometric/PIN routing, the biometric prompt lifecycle, background
/// re-lock, and PIN verification/lockout. Publishes a single `uiState` the Views render; the Views
/// hold no `LAContext`/`scenePhase`/decision logic.
/// Ported from Android: AuthViewModel.kt
@MainActor
final class AuthViewModel: ObservableObject {

    /// Source of truth for locked/unlocked.
    @Published private(set) var isAuthenticated: Bool = false
    /// What the gate should render (derived from `resolveAuthAction` + runtime prompt state).
    @Published private(set) var uiState: AppLockUIState = .unlocked

    private let settingsRepository: SettingsRepositoryProtocol
    private let authenticator: BiometricAuthenticator

    // Auth-flow runtime state (all main-actor isolated).
    private var showPin = false
    private var isPrompting = false
    /// Loop guard (AC7): the biometric prompt auto-runs at most once per lock. The Face sheet drives
    /// the app `.inactive → .active`; without this, "prompt when active" would re-fire on every
    /// cancel. Reset only on a true re-lock, never on `.inactive`.
    private var promptedThisLock = false
    private var promptError: String?
    private var isSetupPrompting = false
    private var setupError: String?
    /// Stale-success guard (AC8): bumped on every re-lock. A biometric/passcode completion whose
    /// captured generation no longer matches is discarded, so a late success cannot unlock after
    /// the app has re-locked.
    private var lockGeneration = 0

    init(
        settingsRepository: SettingsRepositoryProtocol = SettingsRepository(),
        authenticator: BiometricAuthenticator = LABiometricAuthenticator()
    ) {
        self.settingsRepository = settingsRepository
        self.authenticator = authenticator
        recomputeUIState()
    }

    // MARK: - Derived routing

    var requiresAuth: Bool {
        settingsRepository.isAppLockEnabled()
    }

    /// Whether a PIN is configured.
    var pinEnabled: Bool {
        settingsRepository.getSettings().pinEnabled
    }

    /// Biometric enabled by the user AND currently usable on this device (routed through the
    /// authenticator so state selection is deterministic in tests).
    var canUseBiometric: Bool {
        settingsRepository.isBiometricEnabled() && authenticator.canEvaluate()
    }

    /// The pure routing decision. Fails closed: App Lock on with no usable method → `.setupRequired`.
    var authAction: AuthAction {
        resolveAuthAction(
            canUseBiometric: canUseBiometric,
            pinEnabled: pinEnabled,
            appLockEnabled: settingsRepository.isAppLockEnabled()
        )
    }

    private func recomputeUIState() {
        guard requiresAuth, !isAuthenticated else { uiState = .unlocked; return }
        switch authAction {
        case .none:
            uiState = .unlocked
        case .pinOnly:
            uiState = .pin(showBack: false)
        case .biometricOnly:
            uiState = .biometric(prompting: isPrompting, error: promptError, kind: authenticator.biometryKind, showUsePin: false)
        case .biometricAndPin:
            uiState = showPin
                ? .pin(showBack: true)
                : .biometric(prompting: isPrompting, error: promptError, kind: authenticator.biometryKind, showUsePin: true)
        case .setupRequired:
            uiState = .setupRequired(prompting: isSetupPrompting, error: setupError)
        }
    }

    // MARK: - Lifecycle events (forwarded by AppRootView; no scenePhase types leak in)

    /// App became active (foreground). Recompute and auto-run the biometric prompt at most once
    /// per lock (AC1 seamless unlock, AC7 loop guard).
    func appDidBecomeActive() {
        recomputeUIState()
        if case .biometric = uiState, !promptedThisLock {
            startBiometricPrompt()
        }
    }

    /// App entered TRUE background (NOT `.inactive`). Re-lock if App Lock is on.
    func appDidEnterBackground() {
        guard requiresAuth else { return }
        relock()
    }

    /// Force a re-lock — background, session expiry, or logout (AC9). Bumps the generation so an
    /// in-flight biometric/passcode success cannot unlock after the fact (AC8).
    func relock() {
        isAuthenticated = false
        showPin = false
        isPrompting = false
        isSetupPrompting = false
        promptError = nil
        setupError = nil
        promptedThisLock = false
        lockGeneration += 1
        recomputeUIState()
    }

    // MARK: - Biometric prompt

    private func startBiometricPrompt() {
        guard !isPrompting else { return }
        promptedThisLock = true
        isPrompting = true
        promptError = nil
        recomputeUIState()
        let generation = lockGeneration
        Task {
            let outcome = await authenticator.evaluateBiometrics(reason: String(localized: "biometric_reason"))
            applyBiometricOutcome(outcome, generation: generation)
        }
    }

    /// Applies a biometric outcome, discarding it if a re-lock happened since the prompt started
    /// (AC8). Internal so the stale-success guard is directly unit-testable.
    func applyBiometricOutcome(_ outcome: BiometricOutcome, generation: Int) {
        guard generation == lockGeneration else { return }
        isPrompting = false
        switch outcome {
        case .success:
            isAuthenticated = true
        case .userCancel:
            break
        case .userFallback:
            if pinEnabled { showPin = true }
        case .biometryLockout:
            promptError = String(localized: "error_biometric_lockout")
            if pinEnabled { showPin = true }
        case .unavailable:
            break
        case .failed(let message):
            promptError = message.isEmpty ? String(localized: "error_biometric_failed") : message
        }
        recomputeUIState()
    }

    /// Explicit user retry of the biometric prompt (the only path that shows a "confirm" button).
    func retryBiometric() {
        startBiometricPrompt()
    }

    /// User tapped "Use PIN" (only offered in the biometric+PIN combination).
    func usePin() {
        showPin = true
        recomputeUIState()
    }

    /// User tapped back on the PIN keypad (only reachable in biometric+PIN) — return to biometric.
    func backFromPin() {
        showPin = false
        recomputeUIState()
    }

    // MARK: - Device passcode (fail-closed setup-required)

    func unlockWithDevicePasscode() {
        guard !isSetupPrompting else { return }
        isSetupPrompting = true
        setupError = nil
        recomputeUIState()
        let generation = lockGeneration
        Task {
            let ok = await authenticator.evaluateDeviceOwnerAuth(reason: String(localized: "biometric_reason"))
            applyDevicePasscodeOutcome(success: ok, generation: generation)
        }
    }

    /// Internal so the stale-success guard is unit-testable.
    func applyDevicePasscodeOutcome(success: Bool, generation: Int) {
        guard generation == lockGeneration else { return }
        isSetupPrompting = false
        if success { isAuthenticated = true }
        recomputeUIState()
    }

    // MARK: - Auth state

    func setAuthenticated(_ value: Bool) {
        if value {
            isAuthenticated = true
            recomputeUIState()
        } else {
            // A reset is always a re-lock: clear guard + bump generation (external callers rely on it).
            relock()
        }
    }

    // MARK: - PIN

    func verifyPin(_ pin: String) -> Bool {
        settingsRepository.verifyPin(pin)
    }

    /// Appends a digit and evaluates the PIN ONLY once all `PinHasher.pinLength` (6) digits are
    /// entered. Verifying once per entry keeps the failure count correct (a wrong 6-digit entry is
    /// exactly one failed attempt). On success, transitions to unlocked via `setAuthenticated`.
    func enterPinDigit(_ digit: String, currentPin: inout String) -> PinEntryResult {
        currentPin += digit
        guard currentPin.count >= PinHasher.pinLength else { return .needMoreDigits }

        if verifyPin(currentPin) {
            setAuthenticated(true)
            return .success
        }

        let remaining = getRemainingAttempts()
        currentPin = ""
        if remaining > 0 {
            return .wrongPin(remainingAttempts: remaining)
        } else {
            return .lockedOut
        }
    }

    func getRemainingAttempts() -> Int {
        max(0, PinHasher.maxAttemptsPerTier - settingsRepository.getFailedAttempts())
    }

    func isLockedOut() -> Bool {
        settingsRepository.isLockedOut()
    }

    func getLockoutRemainingSeconds() -> Int {
        settingsRepository.getLockoutRemainingSeconds()
    }
}

/// Result of a PIN digit entry attempt.
enum PinEntryResult {
    /// More digits are needed to complete the PIN.
    case needMoreDigits
    /// PIN was verified successfully.
    case success
    /// PIN was incorrect. `remainingAttempts` indicates how many tries remain before lockout.
    case wrongPin(remainingAttempts: Int)
    /// Too many failed attempts — the user is locked out.
    case lockedOut
}
