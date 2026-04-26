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

    func toggleAppLock(_ enabled: Bool) {
        settingsRepo.setAppLock(enabled)
        settings.appLockEnabled = enabled
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

    func removePin() {
        settingsRepo.removePin()
        settings = settingsRepo.getSettings()
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
