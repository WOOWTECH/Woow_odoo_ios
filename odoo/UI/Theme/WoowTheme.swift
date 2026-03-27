import SwiftUI

/// Observable theme manager — persists primary color via SettingsRepository.
/// Ported from Android: ThemeManager + Theme.kt
final class WoowTheme: ObservableObject {

    static let shared = WoowTheme()

    @Published var primaryColor: Color = WoowColors.primaryBlue
    @Published var themeMode: ThemeMode = .system

    private let settingsRepo = SettingsRepository()

    init() {
        let settings = settingsRepo.getSettings()
        primaryColor = Color(hex: settings.themeColor)
        themeMode = settings.themeMode
    }

    func setPrimaryColor(hex: String) {
        primaryColor = Color(hex: hex)
        var settings = settingsRepo.getSettings()
        settings.themeColor = hex
        SecureStorage.shared.saveSettings(settings)
    }

    func setThemeMode(_ mode: ThemeMode) {
        themeMode = mode
        var settings = settingsRepo.getSettings()
        settings.themeMode = mode
        SecureStorage.shared.saveSettings(settings)
    }
}
