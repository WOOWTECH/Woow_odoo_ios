import Foundation

/// Settings screen ViewModel.
/// Ported from Android: SettingsViewModel.kt
@MainActor
final class SettingsViewModel: ObservableObject {

    @Published var settings: AppSettings
    @Published var cacheSizeText: String = "0 B"

    /// Mirrors `settings.locationEnabled`. Uses a `didSet` observer to persist the
    /// change through the repository without requiring callers to manipulate `settings`
    /// directly — mirrors the pattern used by toggleBiometric / toggleReduceMotion.
    @Published var locationEnabled: Bool = true {
        didSet {
            settingsRepo.updateLocationEnabled(locationEnabled)
            settings.locationEnabled = locationEnabled
        }
    }

    private let settingsRepo: SettingsRepositoryProtocol
    private let cacheService: CacheService
    private let theme: WoowTheme

    init(
        settingsRepo: SettingsRepositoryProtocol = SettingsRepository(),
        cacheService: CacheService = CacheService(),
        theme: WoowTheme = .shared
    ) {
        self.settingsRepo = settingsRepo
        self.cacheService = cacheService
        self.theme = theme
        let loaded = settingsRepo.getSettings()
        self.settings = loaded
        self.locationEnabled = loaded.locationEnabled
        updateCacheSize()
    }

    func updateThemeColor(_ hex: String) {
        settings.themeColor = hex
        SecureStorage.shared.saveSettings(settings)
        theme.setPrimaryColor(hex: hex)
    }

    func updateThemeMode(_ mode: ThemeMode) {
        settings.themeMode = mode
        SecureStorage.shared.saveSettings(settings)
        theme.setThemeMode(mode)
    }

    /// Turns App Lock on, or off when no PIN is set. Turning it off while a PIN is set is refused
    /// (returns `false`, the switch stays on) and must go through `disableAppLock(verifyingCurrentPin:)`
    /// — an unlocked phone handed to someone must not let them switch the lock off with one tap
    /// (Android f9a0207 parity). Only the legacy PIN-less state can still be switched off here.
    @discardableResult
    func toggleAppLock(_ enabled: Bool) -> Bool {
        if !enabled && settingsRepo.getSettings().pinEnabled {
            AppLogger.settings.warning("App Lock can only be turned off after verifying the current PIN")
            return false
        }
        settingsRepo.setAppLock(enabled)
        settings.appLockEnabled = enabled
        return true
    }

    /// Turns App Lock off only after `pin` verifies as the current PIN, through the same check,
    /// failed-attempt counter and lockout as the unlock screen (`verifyCurrentPin(_:)`).
    func disableAppLock(verifyingCurrentPin pin: String) -> CurrentPinOutcome {
        let outcome = verifyCurrentPin(pin)
        if outcome == .accepted {
            settingsRepo.setAppLock(false)
            settings.appLockEnabled = false
        }
        return outcome
    }

    func toggleBiometric(_ enabled: Bool) {
        settingsRepo.setBiometric(enabled)
        settings.biometricEnabled = enabled
    }

    // G6: Reduce Motion
    func toggleReduceMotion(_ enabled: Bool) {
        settingsRepo.setReduceMotion(enabled)
        settings.reduceMotion = enabled
    }

    // G1: Current language display name (from system per-app language setting)
    var currentLanguageDisplayName: String {
        guard let code = Bundle.main.preferredLocalizations.first else { return "System" }
        switch code {
        case "zh-Hant": return "繁體中文"
        case "zh-Hans": return "简体中文"
        case "en": return "English"
        default: return Locale.current.localizedString(forLanguageCode: code) ?? code
        }
    }

    // G5: App version from bundle
    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func verifyPin(_ pin: String) -> Bool {
        settingsRepo.verifyPin(pin)
    }

    func setPin(_ pin: String) -> Bool {
        let result = settingsRepo.setPin(pin)
        if result { settings = settingsRepo.getSettings() }
        return result
    }

    /// Removes the PIN only after `pin` verifies as the CURRENT PIN (LIVE-0927-4: removal used to
    /// be one unverified tap). Verification goes through `SettingsRepository.verifyPin`, the unlock
    /// path, so wrong entries count toward the same lockout and a lockout refuses even a correct PIN.
    /// There is deliberately no unverified removal entry point on the ViewModel.
    func removePin(verifyingCurrentPin pin: String) -> CurrentPinOutcome {
        let outcome = verifyCurrentPin(pin)
        if outcome == .accepted {
            settingsRepo.removePin()
            settings = settingsRepo.getSettings()
        }
        return outcome
    }

    /// The one "is this the current PIN?" check behind every PIN-gated Settings action. It goes
    /// through `SettingsRepository.verifyPin` — the unlock path — so wrong entries count toward the
    /// same failed-attempt counter and lockout, and a lockout refuses even a correct PIN.
    private func verifyCurrentPin(_ pin: String) -> CurrentPinOutcome {
        if settingsRepo.isLockedOut() {
            return .lockedOut(remainingSeconds: settingsRepo.getLockoutRemainingSeconds())
        }
        guard settingsRepo.verifyPin(pin) else {
            // This failure may have been the one that started a lockout.
            if settingsRepo.isLockedOut() {
                return .lockedOut(remainingSeconds: settingsRepo.getLockoutRemainingSeconds())
            }
            return .incorrectPin
        }
        return .accepted
    }

    func clearCache() {
        Task {
            cacheService.clearAppCache()
            await cacheService.clearWebViewCache()
            updateCacheSize()
        }
    }

    private func updateCacheSize() {
        let bytes = cacheService.calculateCacheSize()
        cacheSizeText = CacheService.formatSize(bytes)
    }
}

// MARK: - CurrentPinOutcome

/// Result of checking the current PIN before a PIN-gated Settings action (remove PIN, turn App
/// Lock off).
enum CurrentPinOutcome: Equatable {
    case accepted
    case incorrectPin
    case lockedOut(remainingSeconds: Int)

    /// The message shown under the PIN dots, or `nil` on success. Reuses the unlock screen's
    /// strings so every language already has them.
    func errorMessage(bundle: Bundle = .main) -> String? {
        switch self {
        case .accepted:
            return nil
        case .incorrectPin:
            return String(localized: "incorrect_pin", bundle: bundle)
        case .lockedOut(let seconds):
            return String(format: String(localized: "lockout_timer_%lld", bundle: bundle), seconds)
        }
    }
}
