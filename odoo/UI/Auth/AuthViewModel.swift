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

    func getRemainingAttempts() -> Int {
        max(0, 5 - settingsRepository.getFailedAttempts())
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
