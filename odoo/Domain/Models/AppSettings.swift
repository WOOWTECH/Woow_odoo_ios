import Foundation

/// App-wide settings stored in UserDefaults/Keychain.
/// Ported from Android: AppSettings.kt
struct AppSettings: Codable, Equatable {
    /// Brand-default theme color (`#6183FC`). Surfaced as a static so tests
    /// and `WoowTheme` can refer to "the production default" without
    /// drifting if the value ever needs to change.
    static let defaultThemeColor: String = "#6183FC"

    var themeColor: String = AppSettings.defaultThemeColor
    var themeMode: ThemeMode = .system
    var reduceMotion: Bool = false
    var appLockEnabled: Bool = false
    var biometricEnabled: Bool = false
    var pinEnabled: Bool = false
    var pinHash: String? = nil
    var language: AppLanguage = .system
    var failedPinAttempts: Int = 0
    var pinLockoutUntil: TimeInterval? = nil
    /// Controls whether the app attaches GPS coordinates to clock-in/out events via the JS shim.
    /// Defaults to `true` (opt-in by default, per v2 spec).
    var locationEnabled: Bool = true
}

enum ThemeMode: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

enum AppLanguage: String, Codable, CaseIterable {
    case system
    case english = "en"
    case chineseTW = "zh-Hant"
    case chineseCN = "zh-Hans"

    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .english: return "English"
        case .chineseTW: return "繁體中文"
        case .chineseCN: return "简体中文"
        }
    }
}
