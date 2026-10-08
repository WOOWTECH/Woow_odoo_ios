import XCTest
import SwiftUI
@testable import odoo

final class AppBrandTests: XCTestCase {
    private func brand(_ code: String, _ bundleID: String, _ scheme: String) throws -> AppBrand {
        try XCTUnwrap(AppBrand(code: code, bundleID: bundleID, urlScheme: scheme))
    }

    func test_identity_givenUnknownMissingOrMixedConfiguration_returnsNil() {
        XCTAssertNil(AppBrand(code: nil, bundleID: nil, urlScheme: nil))
        XCTAssertNil(AppBrand(code: "unknown", bundleID: "io.woowtech.odoo", urlScheme: "woowodoo"))
        XCTAssertNil(AppBrand(code: "apporo", bundleID: "io.woowtech.odoo", urlScheme: "woowodoo"))
        XCTAssertNil(AppBrand(code: "apporo", bundleID: "com.apporo.odoo.dev", urlScheme: "apporoodoo"))
        XCTAssertNil(AppBrand(code: "apporo", bundleID: "com.apporo.odoo", urlScheme: "apporoodoo-dev"))
    }

    func test_identity_givenApporo_returnsApprovedBrandValues() throws {
        let apporo = try brand("apporo", "com.apporo.odoo", "apporoodoo")
        XCTAssertEqual(apporo.displayName(localization: "en"), "Apporo platform")
        XCTAssertEqual(apporo.signature, "APPORO UNION INC.")
        XCTAssertEqual(apporo.primaryColorHex, "#8B6B24")
        XCTAssertEqual(apporo.logoAsset, "ApporoLogo")
        XCTAssertEqual(apporo.websiteURL, "https://www.apporo.ai")
        XCTAssertEqual(apporo.contactEmail, "info@apporo.ai")
        XCTAssertEqual(apporo.keychainService, "com.apporo.odoo.keychain")
    }

    func test_identity_givenWoow_returnsUnchangedValues() throws {
        let woow = try brand("woowtech", "io.woowtech.odoo", "woowodoo")
        XCTAssertEqual(woow.displayName(localization: "en"), "woowtech platform")
        XCTAssertEqual(woow.signature, "\u{00A9} 2026 WoowTech")
        XCTAssertEqual(woow.primaryColorHex, "#6183FC")
        XCTAssertEqual(woow.logoAsset, "WoowLogo")
        XCTAssertEqual(woow.websiteURL, "https://aiot.woowtech.io")
        XCTAssertEqual(woow.contactEmail, "woowtech@designsmart.com.tw")
        XCTAssertEqual(woow.keychainService, "io.woowtech.odoo.keychain")
        XCTAssertEqual(woow.pageURL(.support, language: nil), "https://aiot.woowtech.io/odoo-support")
    }

    func test_displayName_givenWoowTraditionalChinese_returnsWoowPlatformChineseName() throws {
        let woow = try brand("woowtech", "io.woowtech.odoo", "woowodoo")
        XCTAssertEqual(woow.displayName(localization: "zh-Hant"), "渥屋平台")
        for lang in ["en", "zh-Hans", nil] as [String?] {
            XCTAssertEqual(woow.displayName(localization: lang), "woowtech platform")
        }
    }

    func test_displayName_givenApporoAnyLocalization_returnsApporoPlatform() throws {
        for (bundleID, scheme) in [("com.apporo.odoo", "apporoodoo"), ("com.apporo.odoo.dev", "apporoodoo-dev")] {
            let apporo = try brand("apporo", bundleID, scheme)
            for lang in ["en", "zh-Hans", "zh-Hant", nil] as [String?] {
                XCTAssertEqual(apporo.displayName(localization: lang), "Apporo platform")
            }
        }
    }

    func test_displayName_givenRunningApp_matchesSelectedInfoPlistDisplayName() {
        // The in-app title must agree with the home-screen name that the
        // brand-selected InfoPlist.strings gives the same localization.
        let bundleName = Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        XCTAssertEqual(AppBrand.current.displayName, bundleName)
    }

    /// Real shared template from the app bundle's `<lang>.lproj/Localizable.strings`.
    private func template(_ key: String, _ lang: String) throws -> String {
        let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path)).localizedString(forKey: key, value: nil, table: nil)
    }

    func test_localizedFill_givenWoow_matchesWoow101Copy() throws {
        // Expected values are the WOOW 1.0.1 engineering strings (acff782).
        let woow = try brand("woowtech", "io.woowtech.odoo", "woowodoo")
        let expected: [(key: String, lang: String, text: String)] = [
            ("biometric_reason", "zh-Hant", "解鎖渥屋平台"),
            ("Change language in iOS Settings", "zh-Hant", "前往 設定 > 渥屋平台 > 語言 變更語言"),
            ("biometric_reason", "zh-Hans", "解锁 woowtech platform"),
            ("biometric_reason", "en", "Unlock woowtech platform"),
        ]
        for item in expected {
            let text = AppBrand.fill(try template(item.key, item.lang), name: woow.displayName(localization: item.lang))
            XCTAssertEqual(text, item.text, "\(item.key) \(item.lang)")
        }
    }

    func test_localizedFill_givenApporo_keepsSpaceBeforeLatinName() throws {
        let apporo = try brand("apporo", "com.apporo.odoo", "apporoodoo")
        let expected: [(key: String, lang: String, text: String)] = [
            ("biometric_reason", "zh-Hant", "解鎖 Apporo platform"),
            ("biometric_reason", "zh-Hans", "解锁 Apporo platform"),
            ("biometric_reason", "en", "Unlock Apporo platform"),
            ("Change language in iOS Settings", "zh-Hant", "前往 設定 > Apporo platform > 語言 變更語言"),
        ]
        for item in expected {
            let text = AppBrand.fill(try template(item.key, item.lang), name: apporo.displayName(localization: item.lang))
            XCTAssertEqual(text, item.text, "\(item.key) \(item.lang)")
        }
    }

    func test_scheme_givenOtherBrandOrEnvironment_returnsFalse() throws {
        let prod = try brand("apporo", "com.apporo.odoo", "apporoodoo")
        let dev = try brand("apporo", "com.apporo.odoo.dev", "apporoodoo-dev")
        XCTAssertTrue(prod.acceptsScheme("apporoodoo"))
        XCTAssertTrue(dev.acceptsScheme("apporoodoo-dev"))
        XCTAssertFalse(prod.acceptsScheme("apporoodoo-dev"))
        XCTAssertFalse(dev.acceptsScheme("apporoodoo"))
        // Pure provider rejection: never ask the OS to open another brand.
        let woow = try brand("woowtech", "io.woowtech.odoo", "woowodoo")
        XCTAssertFalse(prod.acceptsScheme("woowodoo"))
        XCTAssertFalse(dev.acceptsScheme("woowodoo"))
        XCTAssertFalse(woow.acceptsScheme("apporoodoo"))
        XCTAssertFalse(woow.acceptsScheme("apporoodoo-dev"))
        XCTAssertFalse(dev.acceptsScheme(nil))
        XCTAssertEqual(dev.keychainService, "com.apporo.odoo.dev.keychain")
    }

    func test_links_givenApporoLocales_returnsSixApprovedLinksAndEnglishFallback() throws {
        let apporo = try brand("apporo", "com.apporo.odoo", "apporoodoo")
        for lang in ["zh-Hant", "zh-Hans", "zh-TW", "zh-CN"] {
            XCTAssertEqual(apporo.pageURL(.support, language: lang), "https://www.apporo.ai/odoo-support")
            XCTAssertEqual(apporo.pageURL(.privacy, language: lang), "https://www.apporo.ai/odoo-privacy")
            XCTAssertEqual(apporo.pageURL(.accountDeletion, language: lang), "https://www.apporo.ai/odoo-account-deletion")
        }
        for lang in ["en", "en-US", "fr", nil] as [String?] {
            XCTAssertEqual(apporo.pageURL(.support, language: lang), "https://www.apporo.ai/odoo-support-en")
            XCTAssertEqual(apporo.pageURL(.privacy, language: lang), "https://www.apporo.ai/odoo-privacy-en")
            XCTAssertEqual(apporo.pageURL(.accountDeletion, language: lang), "https://www.apporo.ai/odoo-account-deletion-en")
        }
    }

    @MainActor
    func test_theme_givenSelectedBuild_returnsBrandDefaultAndFixedColor() {
        let expected = AppBrand.current.code == .apporo ? "#8B6B24" : "#6183FC"
        XCTAssertEqual(AppSettings().themeColor, expected)
        XCTAssertEqual(WoowTheme.fixedBrandColor, Color(hex: expected))
        XCTAssertEqual(WoowColors.brandColors.first, expected)
        XCTAssertEqual(WoowTheme.scheme(for: "#8B6B24"), .dark)
    }

    // MARK: - Solid button fill contrast (2026-10-08)

    @MainActor
    func test_contrastRatio_givenKnownPairs_returnsWcagValues() throws {
        XCTAssertEqual(try XCTUnwrap(WoowTheme.contrastRatio("#FFFFFF", "#000000")), 21, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(WoowTheme.contrastRatio("#000000", "#FFFFFF")), 21, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(WoowTheme.contrastRatio("#777777", "#777777")), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(WoowTheme.contrastRatio("#6183FC", "#FFFFFF")), 3.41, accuracy: 0.01)
        XCTAssertNil(WoowTheme.contrastRatio("#12345", "#FFFFFF"))
        XCTAssertNil(WoowTheme.contrastRatio("#FFFFFF", "blue"))
    }

    @MainActor
    func test_buttonFillHex_givenWoow_returnsDarkerSameHueBlueMeetingAA() throws {
        let woow = try brand("woowtech", "io.woowtech.odoo", "woowodoo")
        XCTAssertEqual(woow.buttonFillHex, "#4069FB")
        XCTAssertEqual(woow.primaryColorHex, "#6183FC", "only the button-fill role changes")
        XCTAssertLessThan(try XCTUnwrap(WoowTheme.contrastRatio(woow.primaryColorHex, "#FFFFFF")), 4.5)
        let ratio = try XCTUnwrap(WoowTheme.contrastRatio(woow.buttonFillHex, "#FFFFFF"))
        XCTAssertGreaterThanOrEqual(ratio, 4.5)
        XCTAssertEqual(ratio, 4.53, accuracy: 0.01)
        // Same hue as the brand primary (within 0.5°), i.e. a darker step of the same blue.
        func hue(_ hex: String) throws -> Double {
            let (r, g, b) = try XCTUnwrap(WoowTheme.parseRGB(hex: hex))
            let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
            XCTAssertEqual(maxC, b, "blue-dominant")
            return 60 * (4 + (r - g) / d)
        }
        XCTAssertEqual(try hue(woow.buttonFillHex), try hue(woow.primaryColorHex), accuracy: 0.5)
    }

    @MainActor
    func test_buttonFillHex_givenApporo_returnsUnchangedPrimary() throws {
        for (bundleID, scheme) in [("com.apporo.odoo", "apporoodoo"), ("com.apporo.odoo.dev", "apporoodoo-dev")] {
            let apporo = try brand("apporo", bundleID, scheme)
            XCTAssertEqual(apporo.buttonFillHex, "#8B6B24")
            XCTAssertEqual(apporo.buttonFillHex, apporo.primaryColorHex)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(WoowTheme.contrastRatio(apporo.buttonFillHex, "#FFFFFF")), 4.5)
        }
    }

    @MainActor
    func test_fixedBrandButtonColor_givenSelectedBuild_returnsBrandButtonFill() {
        let expected = AppBrand.current.code == .apporo ? "#8B6B24" : "#4069FB"
        XCTAssertEqual(AppBrand.current.buttonFillHex, expected)
        XCTAssertEqual(WoowTheme.fixedBrandButtonColor, Color(hex: expected))
        // The theme default and the brand tint stay on the primary.
        XCTAssertEqual(WoowTheme.fixedBrandColor, Color(hex: AppBrand.current.primaryColorHex))
    }

    func test_settings_givenSavedCustomColor_preservesIt() throws {
        var saved = AppSettings()
        saved.themeColor = "#FF0000"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.themeColor, "#FF0000")
    }
}
