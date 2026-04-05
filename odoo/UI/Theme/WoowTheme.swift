import SwiftUI

/// Observable theme manager — persists primary color via SettingsRepository.
/// Ported from Android: ThemeManager + Theme.kt
final class WoowTheme: ObservableObject {

    static let shared = WoowTheme()

    @Published var primaryColor: Color = WoowColors.primaryBlue
    @Published var themeMode: ThemeMode = .system

    /// H5: Maps themeMode to SwiftUI's ColorScheme for .preferredColorScheme()
    /// Returns nil for .system (follows device setting), .light or .dark otherwise.
    var colorSchemeOverride: ColorScheme? {
        switch themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

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
