import Foundation
import SwiftUI

/// Observable theme manager — persists primary color via SettingsRepository.
/// Ported from Android: ThemeManager + Theme.kt
///
/// Thread affinity: marked `@MainActor` because `@Published` mutations from a
/// background thread trigger SwiftUI's "Publishing changes from background
/// threads is not allowed" runtime warning on iOS 16+, and because every
/// reader is a SwiftUI view (which runs on the main actor).
@MainActor
final class WoowTheme: ObservableObject {

    static let shared = WoowTheme()

    @Published private(set) var primaryColor: Color = WoowColors.primaryBlue
    @Published var themeMode: ThemeMode = .system

    /// The hex string the color was last set from. Stored separately because
    /// `Color` does not round-trip its underlying components reliably.
    private(set) var primaryColorHex: String = AppSettings.defaultThemeColor

    /// H5: Maps themeMode to SwiftUI's ColorScheme for `.preferredColorScheme()`.
    /// Returns nil for .system (follows device setting), .light or .dark otherwise.
    var colorSchemeOverride: ColorScheme? {
        switch themeMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Computes the toolbar text/icon scheme to use against `primaryColor`.
    ///
    /// Apple HIG and WCAG 2.1 SC 1.4.3 require a 4.5:1 contrast ratio for
    /// normal text on a background. Hardcoding `.dark` (white text) breaks
    /// when the user picks a light color (e.g. yellow, cream) — title and
    /// hamburger icon become invisible. This computed property samples the
    /// chosen color's relative luminance and flips the toolbar text scheme
    /// to maintain readable contrast.
    var toolbarTextScheme: ColorScheme {
        Self.scheme(for: primaryColorHex)
    }

    /// Pure helper used by `toolbarTextScheme` and validated by unit tests.
    /// Threshold of 0.55 chosen empirically: matches Material's
    /// `colorContrastRatio` heuristic and gives `.dark` (white text) for
    /// brand blue (#6183FC luminance ≈ 0.31) while flipping to `.light`
    /// (black text) for yellows / pastels.
    static func scheme(for hex: String) -> ColorScheme {
        let lum = relativeLuminance(of: hex)
        return lum > 0.55 ? .light : .dark
    }

    /// WCAG 2.1 relative luminance formula. Returns 0.0 (black) – 1.0 (white).
    /// Returns 0.5 (assume mid-gray) on parse failure so we don't bias
    /// toward any particular text color when input is malformed.
    private static func relativeLuminance(of hex: String) -> Double {
        guard let rgb = parseRGB(hex: hex) else { return 0.5 }
        let r = channelLuminance(rgb.0)
        let g = channelLuminance(rgb.1)
        let b = channelLuminance(rgb.2)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func channelLuminance(_ component: Double) -> Double {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    /// Strict hex parser — rejects malformed input rather than silently
    /// returning black. Accepts `#RRGGBB` and `RRGGBB`. Lowercase or
    /// uppercase. Returns RGB triple in 0.0–1.0 range or nil on failure.
    static func parseRGB(hex: String) -> (Double, Double, Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 else { return nil }
        guard let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return (r, g, b)
    }

    /// Returns true if the given hex is a syntactically valid `#RRGGBB`
    /// or `RRGGBB` form. Used by the color picker to gate the Apply button.
    static func isValidHex(_ hex: String) -> Bool {
        parseRGB(hex: hex) != nil
    }

    private let settingsRepo = SettingsRepository()

    init() {
        let settings = settingsRepo.getSettings()
        let savedHex = WoowTheme.isValidHex(settings.themeColor)
            ? settings.themeColor
            : AppSettings.defaultThemeColor
        primaryColor = Color(hex: savedHex)
        primaryColorHex = savedHex
        themeMode = settings.themeMode

        // Test override: launch with env `WOOW_TEST_THEME_COLOR=<hex>` to
        // force the theme at startup for visual verification. Belt-and-
        // suspenders gating: the `#if DEBUG` strips the env-var string
        // from Release binaries entirely (so the audit script finds no
        // trace), and `TestHookGate.testHooksEnabled` adds a runtime
        // second factor inside Debug builds.
        #if DEBUG
        if TestHookGate.testHooksEnabled,
           let hex = ProcessInfo.processInfo.environment["WOOW_TEST_THEME_COLOR"],
           WoowTheme.isValidHex(hex) {
            // Print a loud warning so a developer who left this env var in
            // their Xcode scheme doesn't waste time debugging "why isn't my
            // saved color showing" — App Store guideline 4.0 quality.
            print("⚠️ [TestHook] WOOW_TEST_THEME_COLOR=\(hex) is overriding the user's saved theme. " +
                  "Unset the env var in your scheme to use the persisted color.")
            primaryColor = Color(hex: hex)
            primaryColorHex = hex
        }
        #endif
    }

    /// Sets the primary color. Rejects malformed hex strings to prevent
    /// `Color(hex:)`'s silent fallback (transparent or black) from
    /// shipping. Returns the value that was actually applied so callers
    /// can decide how to surface a rejected input.
    @discardableResult
    func setPrimaryColor(hex: String) -> Bool {
        guard WoowTheme.isValidHex(hex) else {
            print("⚠️ [WoowTheme] rejected invalid hex \(hex)")
            return false
        }
        primaryColor = Color(hex: hex)
        primaryColorHex = hex
        var settings = settingsRepo.getSettings()
        settings.themeColor = hex
        SecureStorage.shared.saveSettings(settings)
        return true
    }

    func setThemeMode(_ mode: ThemeMode) {
        themeMode = mode
        var settings = settingsRepo.getSettings()
        settings.themeMode = mode
        SecureStorage.shared.saveSettings(settings)
    }
}
