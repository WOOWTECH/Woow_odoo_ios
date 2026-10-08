//
//  SettingsGapTests.swift
//  odooTests
//
//  P2 + P3 Gap Fix unit tests.
//  Covers: G1 (Language), G6 (Reduce Motion), G5 (About), G4 (Help & Support)
//  Reference: docs/2026-04-05-P2-P3-Gap-Fix_Test_Plan.md
//

import XCTest
@testable import odoo

// MARK: - P2+P3 Gap Fix: Settings Unit Tests

@MainActor
final class SettingsGapTests: XCTestCase {

    // ──────────────────────────────────────────────
    // G1 — Language (P2)
    // ──────────────────────────────────────────────

    /// G1-U1: currentLanguageDisplayName returns a non-empty string for the current locale.
    /// The simulator always has at least one preferred localization, so the computed property
    /// must return either a language name or the "System" fallback — never an empty string.
    func test_currentLanguageDisplayName_givenEnglishLocale_returnsNonEmptyString() {
        let vm = SettingsViewModel()
        XCTAssertFalse(
            vm.currentLanguageDisplayName.isEmpty,
            "currentLanguageDisplayName must return a non-empty string regardless of system locale (G1 fix)"
        )
    }

    // ──────────────────────────────────────────────
    // G6 — Reduce Motion (P2)
    // ──────────────────────────────────────────────

    /// G6-U3: A freshly created SettingsViewModel must have reduceMotion == false by default.
    func test_reduceMotion_defaultIsFalse() {
        let vm = SettingsViewModel()
        XCTAssertFalse(
            vm.settings.reduceMotion,
            "Reduce Motion must default to false before any user interaction (UX-57)"
        )
    }

    /// G6-U1: Calling toggleReduceMotion(true) must set settings.reduceMotion to true in memory.
    func test_toggleReduceMotion_givenTrue_updatesSettings() {
        let vm = SettingsViewModel()
        XCTAssertFalse(vm.settings.reduceMotion, "Pre-condition: default must be false")

        vm.toggleReduceMotion(true)

        XCTAssertTrue(
            vm.settings.reduceMotion,
            "toggleReduceMotion(true) must set settings.reduceMotion to true (UX-57)"
        )

        // Teardown: restore default so subsequent tests start clean
        vm.toggleReduceMotion(false)
    }

    /// G6-U2: Calling toggleReduceMotion(false) must set settings.reduceMotion to false in memory.
    func test_toggleReduceMotion_givenFalse_updatesSettings() {
        let vm = SettingsViewModel()
        vm.toggleReduceMotion(true) // set to true first

        vm.toggleReduceMotion(false)

        XCTAssertFalse(
            vm.settings.reduceMotion,
            "toggleReduceMotion(false) must set settings.reduceMotion to false (UX-57)"
        )
    }

    // ──────────────────────────────────────────────
    // G5 — About Section (P3)
    // ──────────────────────────────────────────────

    /// G5-U1: appVersion must be a non-empty string containing at least one dot,
    /// indicating at least a major.minor component (e.g. "1.0" or "1.0.0").
    func test_appVersion_returnsNonEmptyString() {
        let vm = SettingsViewModel()

        XCTAssertFalse(
            vm.appVersion.isEmpty,
            "SettingsViewModel must expose a non-empty appVersion string (G5 fix)"
        )

        let components = vm.appVersion.split(separator: ".")
        XCTAssertGreaterThanOrEqual(
            components.count,
            2,
            "appVersion must contain at least major.minor components, got: '\(vm.appVersion)'"
        )
    }

    /// G5-U3 (W2-4 L3): the About row shows the build number too — "1.0 (3)" — taken from the
    /// running bundle, for both brands (each scheme runs this against its own app host).
    func test_appVersion_givenBundle_returnsShortVersionWithBuildNumber() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let short = try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(info["CFBundleVersion"] as? String)
        XCTAssertFalse(build.isEmpty, "CFBundleVersion must be set by CURRENT_PROJECT_VERSION")

        XCTAssertEqual(SettingsViewModel().appVersion, "\(short) (\(build))")
    }

    func test_displayVersion_givenShortAndBuild_returnsBothWithBuildInParentheses() {
        XCTAssertEqual(SettingsViewModel.displayVersion(shortVersion: "1.0", build: "3"), "1.0 (3)")
        XCTAssertEqual(SettingsViewModel.displayVersion(shortVersion: " 1.2.1 ", build: " 17 "), "1.2.1 (17)")
    }

    func test_displayVersion_givenMissingOrBlankBuild_returnsShortVersionOnly() {
        XCTAssertEqual(SettingsViewModel.displayVersion(shortVersion: "1.0", build: nil), "1.0")
        XCTAssertEqual(SettingsViewModel.displayVersion(shortVersion: "1.0", build: "  "), "1.0")
    }

    func test_displayVersion_givenMissingShortVersion_returnsDefaultWithBuild() {
        XCTAssertEqual(SettingsViewModel.displayVersion(shortVersion: nil, build: "3"), "1.0 (3)")
        XCTAssertEqual(SettingsViewModel.displayVersion(shortVersion: "", build: nil), "1.0")
    }

    /// G5-U2: SettingsConstants must declare valid HTTPS URLs for the website and every
    /// Help & Support page, in both language variants.
    func test_settingsConstants_urlsAreValid() {
        var candidates: [(name: String, raw: String)] = [("websiteURL", SettingsConstants.websiteURL)]
        for lang in ["en", "zh-Hant"] {
            candidates.append(("supportURL(\(lang))", SettingsConstants.supportURL(forLanguage: lang)))
            candidates.append(("privacyPolicyURL(\(lang))", SettingsConstants.privacyPolicyURL(forLanguage: lang)))
            candidates.append(("accountDeletionURL(\(lang))", SettingsConstants.accountDeletionURL(forLanguage: lang)))
        }

        for candidate in candidates {
            guard let url = URL(string: candidate.raw) else {
                XCTFail("SettingsConstants.\(candidate.name) '\(candidate.raw)' is not a valid URL (G5 fix)")
                continue
            }
            XCTAssertEqual(
                url.scheme,
                "https",
                "SettingsConstants.\(candidate.name) must use HTTPS, got scheme '\(url.scheme ?? "nil")'"
            )
            XCTAssertFalse(
                url.host?.isEmpty ?? true,
                "SettingsConstants.\(candidate.name) must have a non-empty host"
            )
        }
    }

    // ──────────────────────────────────────────────
    // G4 — Help & Support (P3)
    // ──────────────────────────────────────────────

    /// G4-U1: Chinese (and any non-English) UI opens the non-suffixed WOOW pages.
    func test_helpLinks_nonEnglishUseDefaultPages() {
        for lang in ["zh-Hant", "zh-Hans", nil] as [String?] {
            let base = AppBrand.current.code == .apporo ? "https://www.apporo.ai" : "https://aiot.woowtech.io"
            let suffix = AppBrand.current.code == .apporo && lang == nil ? "-en" : ""
            XCTAssertEqual(SettingsConstants.supportURL(forLanguage: lang), base + "/odoo-support" + suffix)
            XCTAssertEqual(SettingsConstants.privacyPolicyURL(forLanguage: lang), base + "/odoo-privacy" + suffix)
            XCTAssertEqual(SettingsConstants.accountDeletionURL(forLanguage: lang), base + "/odoo-account-deletion" + suffix)
        }
    }

    /// G4-U2: English UI opens the "-en" WOOW pages.
    func test_helpLinks_englishUsesEnPages() {
        for lang in ["en", "en-US", "en-GB"] {
            let base = AppBrand.current.code == .apporo ? "https://www.apporo.ai" : "https://aiot.woowtech.io"
            XCTAssertEqual(SettingsConstants.supportURL(forLanguage: lang), base + "/odoo-support-en")
            XCTAssertEqual(SettingsConstants.privacyPolicyURL(forLanguage: lang), base + "/odoo-privacy-en")
            XCTAssertEqual(SettingsConstants.accountDeletionURL(forLanguage: lang), base + "/odoo-account-deletion-en")
        }
    }

    /// G4-U3: No Help & Support link may point at odoo.com (implies affiliation with Odoo S.A.).
    func test_helpLinks_neverPointAtOdooCom() {
        for lang in ["en", "zh-Hant", "zh-Hans"] {
            for raw in [SettingsConstants.supportURL(forLanguage: lang),
                        SettingsConstants.privacyPolicyURL(forLanguage: lang),
                        SettingsConstants.accountDeletionURL(forLanguage: lang)] {
                XCTAssertEqual(URL(string: raw)?.host, AppBrand.current.code == .apporo ? "www.apporo.ai" : "aiot.woowtech.io", raw)
            }
        }
    }
}
