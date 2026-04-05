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

    /// G5-U2: SettingsConstants must declare valid HTTPS URLs for websiteURL, helpURL, and forumURL.
    func test_settingsConstants_urlsAreValid() {
        let candidates: [(name: String, raw: String)] = [
            ("websiteURL", SettingsConstants.websiteURL),
            ("helpURL", SettingsConstants.helpURL),
            ("forumURL", SettingsConstants.forumURL),
        ]

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

    /// G4-U1: helpURL and forumURL must both start with "https".
    /// This guards against accidentally switching to HTTP or committing a placeholder value.
    func test_settingsConstants_helpURLStartsWithHttps() {
        for (name, raw) in [("helpURL", SettingsConstants.helpURL), ("forumURL", SettingsConstants.forumURL)] {
            guard let url = URL(string: raw) else {
                XCTFail("SettingsConstants.\(name) '\(raw)' could not be parsed as a URL (G4 fix)")
                continue
            }
            XCTAssertEqual(
                url.scheme,
                "https",
                "SettingsConstants.\(name) must use HTTPS scheme (G4 fix)"
            )
        }
    }
}
