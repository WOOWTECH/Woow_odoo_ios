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

    /// Attempts to verify a PIN digit-by-digit. Called each time a digit is entered.
    /// Returns the result of the attempt once enough digits are entered.
    func enterPinDigit(_ digit: String, currentPin: inout String) -> PinEntryResult {
        currentPin += digit
        guard currentPin.count >= 4 else { return .needMoreDigits }

        if verifyPin(currentPin) {
            setAuthenticated(true)
            return .success
        } else {
            let remaining = getRemainingAttempts()
            currentPin = ""
            if remaining > 0 {
                return .wrongPin(remainingAttempts: remaining)
            } else {
                return .lockedOut
            }
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
