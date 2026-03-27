import Foundation

/// Settings screen ViewModel.
/// Ported from Android: SettingsViewModel.kt
@MainActor
final class SettingsViewModel: ObservableObject {

    @Published var settings: AppSettings
    @Published var cacheSizeText: String = "0 B"

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
        self.settings = settingsRepo.getSettings()
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
