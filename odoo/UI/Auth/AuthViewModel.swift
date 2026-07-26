import Foundation

/// Auth lifecycle ViewModel — manages biometric/PIN state and bg→fg re-auth.
/// Ported from Android: AuthViewModel.kt
@MainActor
final class AuthViewModel: ObservableObject {

    @Published private(set) var isAuthenticated: Bool = false

    private let settingsRepository: SettingsRepositoryProtocol

    init(settingsRepository: SettingsRepositoryProtocol = SettingsRepository()) {
        self.settingsRepository = settingsRepository
    }

    var requiresAuth: Bool {
        settingsRepository.isAppLockEnabled()
    }

    func setAuthenticated(_ value: Bool) {
        isAuthenticated = value
    }

    /// Resets auth when app goes to background — only if lock is ON.
    /// Called from scenePhase .background handler.
    func onAppBackgrounded() {
        if requiresAuth {
            isAuthenticated = false
        }
    }

    func verifyPin(_ pin: String) -> Bool {
        settingsRepository.verifyPin(pin)
    }

    /// Appends a digit and evaluates the PIN ONLY once all `PinHasher.pinLength` (6) digits are
    /// entered. Entries shorter than 6 digits return `.needMoreDigits` WITHOUT verifying — the PIN is
    /// checked exactly once, at 6 digits.
    ///
    /// This fixes a false-lockout: `verifyPin` increments the failed-attempt counter on every wrong
    /// call, so verifying at lengths 4 and 5 (the old 4–6 behaviour) burned spurious failures and
    /// could trip the lockout one keystroke before the real length-6 check ran — causing a CORRECT
    /// PIN to be rejected. Verifying once per entry keeps the failure count correct: a wrong 6-digit
    /// entry is exactly one failed attempt.
    func enterPinDigit(_ digit: String, currentPin: inout String) -> PinEntryResult {
        currentPin += digit
        guard currentPin.count >= PinHasher.pinLength else { return .needMoreDigits }

        if verifyPin(currentPin) {
            setAuthenticated(true)
            return .success
        }

        // All 6 entered and wrong — verifyPin incremented the failed-attempt counter exactly once.
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
        guard let end = settingsRepository.getLockoutEndTime() else { return 0 }
        let remaining = end - ProcessInfo.processInfo.systemUptime
        return max(0, Int(remaining))
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
