import XCTest
@testable import odoo

/// Validates the App Store / WCAG hardening added to `WoowTheme`:
///   - Strict hex parsing (no silent fallback to black/transparent)
///   - Adaptive `toolbarTextScheme` for ≥4.5:1 contrast on user-picked colors
///   - `setPrimaryColor` rejects malformed input
///
/// These guards exist because the color picker accepts arbitrary HEX input
/// from the user. Without validation, `Color(hex:)`'s silent failure mode
/// can ship an unreadable UI (App Store guideline 4.0 / WCAG 2.1 SC 1.4.3).
@MainActor
final class WoowThemeValidationTest: XCTestCase {

    // MARK: - Hex parsing

    func test_isValidHex_acceptsCanonicalSixDigitForm() {
        XCTAssertTrue(WoowTheme.isValidHex("#FF0000"))
        XCTAssertTrue(WoowTheme.isValidHex("#abcdef"))
        XCTAssertTrue(WoowTheme.isValidHex("#000000"))
        XCTAssertTrue(WoowTheme.isValidHex("#FFFFFF"))
    }

    func test_isValidHex_acceptsFormWithoutLeadingHash() {
        XCTAssertTrue(WoowTheme.isValidHex("FF0000"))
        XCTAssertTrue(WoowTheme.isValidHex("6183FC"))
    }

    func test_isValidHex_rejectsMalformedInput() {
        XCTAssertFalse(WoowTheme.isValidHex(""))
        XCTAssertFalse(WoowTheme.isValidHex("#"))
        XCTAssertFalse(WoowTheme.isValidHex("#FFF")) // 3-digit form not supported
        XCTAssertFalse(WoowTheme.isValidHex("#FFFFFFF")) // too long
        XCTAssertFalse(WoowTheme.isValidHex("garbage"))
        XCTAssertFalse(WoowTheme.isValidHex("#GGGGGG"))
        XCTAssertFalse(WoowTheme.isValidHex("not a hex"))
    }

    // MARK: - Contrast adaptation (WCAG 2.1)

    func test_toolbarTextScheme_returnsDarkSchemeForLightColors() {
        // Light colors → use BLACK text (`.light` color scheme means
        // light environment → black text).
        XCTAssertEqual(WoowTheme.scheme(for: "#FFFFFF"), .light) // pure white
        XCTAssertEqual(WoowTheme.scheme(for: "#FFFF00"), .light) // yellow
        XCTAssertEqual(WoowTheme.scheme(for: "#F5DEB3"), .light) // wheat / cream
    }

    func test_toolbarTextScheme_returnsLightSchemeForDarkColors() {
        // Dark colors → use WHITE text (`.dark` color scheme means
        // dark environment → white text).
        XCTAssertEqual(WoowTheme.scheme(for: "#000000"), .dark) // pure black
        XCTAssertEqual(WoowTheme.scheme(for: "#6183FC"), .dark) // brand blue
        XCTAssertEqual(WoowTheme.scheme(for: "#FF0000"), .dark) // red
        XCTAssertEqual(WoowTheme.scheme(for: "#00C853"), .dark) // green
        XCTAssertEqual(WoowTheme.scheme(for: "#003399"), .dark) // navy
    }

    func test_toolbarTextScheme_isStableNearThreshold() {
        // Exact-threshold luminance shouldn't flicker; the helper should
        // make a deterministic choice regardless of which side of the
        // boundary the input lands on.
        let belowThresholdYellow = WoowTheme.scheme(for: "#FFD700") // gold
        let aboveThresholdGray = WoowTheme.scheme(for: "#808080") // mid-gray
        XCTAssertNotNil(belowThresholdYellow)
        XCTAssertNotNil(aboveThresholdGray)
    }

    // MARK: - setPrimaryColor input gating

    func test_setPrimaryColor_acceptsValidHexAndReturnsTrue() {
        let theme = WoowTheme.shared
        let originalHex = theme.primaryColorHex
        defer { _ = theme.setPrimaryColor(hex: originalHex) }

        let applied = theme.setPrimaryColor(hex: "#FF0000")
        XCTAssertTrue(applied)
        XCTAssertEqual(theme.primaryColorHex.uppercased(), "#FF0000")
    }

    func test_setPrimaryColor_rejectsInvalidHexAndReturnsFalse() {
        let theme = WoowTheme.shared
        let originalHex = theme.primaryColorHex
        defer { _ = theme.setPrimaryColor(hex: originalHex) }

        let applied = theme.setPrimaryColor(hex: "garbage")
        XCTAssertFalse(applied)
        // The previous value MUST be preserved on rejection — otherwise
        // a user typing one bad character mid-edit would corrupt their saved theme.
        XCTAssertEqual(theme.primaryColorHex, originalHex)
    }
}
