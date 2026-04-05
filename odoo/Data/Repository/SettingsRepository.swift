import Foundation

/// Manages app settings — auth locks, PIN, theme, language.
/// Ported from Android: SettingsRepository.kt
protocol SettingsRepositoryProtocol {
    func getSettings() -> AppSettings
    func isAppLockEnabled() -> Bool
    func isBiometricEnabled() -> Bool
    func setAppLock(_ enabled: Bool)
    func setBiometric(_ enabled: Bool)
    func setReduceMotion(_ enabled: Bool)
    func setPin(_ pin: String) -> Bool
    func verifyPin(_ pin: String) -> Bool
    func removePin()
    func getFailedAttempts() -> Int
    func incrementFailedAttempts() -> Int
    func resetFailedAttempts()
    func isLockedOut() -> Bool
    func getLockoutEndTime() -> TimeInterval?
    func setLockout(until: TimeInterval)
}

final class SettingsRepository: SettingsRepositoryProtocol {

    private let secureStorage: SecureStorage

    init(secureStorage: SecureStorage = .shared) {
        self.secureStorage = secureStorage
    }

    func getSettings() -> AppSettings {
        secureStorage.getSettings()
    }

    func isAppLockEnabled() -> Bool {
        secureStorage.getSettings().appLockEnabled
    }

    func isBiometricEnabled() -> Bool {
        secureStorage.getSettings().biometricEnabled
    }

    func setAppLock(_ enabled: Bool) {
        var settings = secureStorage.getSettings()
        settings.appLockEnabled = enabled
        secureStorage.saveSettings(settings)
    }

    func setBiometric(_ enabled: Bool) {
        var settings = secureStorage.getSettings()
        settings.biometricEnabled = enabled
        secureStorage.saveSettings(settings)
    }

    func setReduceMotion(_ enabled: Bool) {
        var settings = secureStorage.getSettings()
        settings.reduceMotion = enabled
        secureStorage.saveSettings(settings)
    }

    func setPin(_ pin: String) -> Bool {
        guard PinHasher.isValidLength(pin) else { return false }
        guard let hash = PinHasher.hash(pin: pin) else { return false }
        var settings = secureStorage.getSettings()
        settings.pinEnabled = true
        settings.pinHash = hash
        secureStorage.saveSettings(settings)
        return true
    }

    func verifyPin(_ pin: String) -> Bool {
        let settings = secureStorage.getSettings()
        guard let storedHash = settings.pinHash else { return false }

        // Check lockout
        if isLockedOut() { return false }

        if PinHasher.verify(pin: pin, against: storedHash) {
            resetFailedAttempts()
            return true
        } else {
            let attempts = incrementFailedAttempts()
            if attempts >= 5 {
                let duration = PinHasher.lockoutDuration(failedAttempts: attempts)
                let lockoutEnd = ProcessInfo.processInfo.systemUptime + duration
                setLockout(until: lockoutEnd)
            }
            return false
        }
    }

    func removePin() {
        var settings = secureStorage.getSettings()
        settings.pinEnabled = false
        settings.pinHash = nil
        secureStorage.saveSettings(settings)
    }

    func getFailedAttempts() -> Int {
        secureStorage.getSettings().failedPinAttempts
    }

    func incrementFailedAttempts() -> Int {
        var settings = secureStorage.getSettings()
        settings.failedPinAttempts += 1
        secureStorage.saveSettings(settings)
        return settings.failedPinAttempts
    }

    func resetFailedAttempts() {
        var settings = secureStorage.getSettings()
        settings.failedPinAttempts = 0
        settings.pinLockoutUntil = nil
        secureStorage.saveSettings(settings)
    }

    func isLockedOut() -> Bool {
        guard let lockoutEnd = secureStorage.getSettings().pinLockoutUntil else { return false }
        return ProcessInfo.processInfo.systemUptime < lockoutEnd
    }

    func getLockoutEndTime() -> TimeInterval? {
        secureStorage.getSettings().pinLockoutUntil
    }

    func setLockout(until: TimeInterval) {
        var settings = secureStorage.getSettings()
        settings.pinLockoutUntil = until
        secureStorage.saveSettings(settings)
    }
}
