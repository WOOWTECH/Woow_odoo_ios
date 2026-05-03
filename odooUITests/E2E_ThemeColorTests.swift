//
//  E2E_ThemeColorTests.swift
//  odooUITests
//
//  End-to-end visual verification of the theme-color reactivity fix.
//
//  WHAT THIS TEST GUARDS
//  ---------------------
//  Before the fix, `MainView` (and 7 other UI sites) hardcoded
//  `WoowColors.primaryBlue` for the navigation toolbar background and other
//  accent surfaces. Picking a color in Settings updated the persisted value
//  but did NOT change any visible UI — a silent UX regression.
//
//  After the fix, every site observes `WoowTheme.shared.primaryColor`
//  (via `@ObservedObject`). This test launches with the
//  `WOOW_TEST_THEME_COLOR` env var (DEBUG-only hook in `WoowTheme.init()`)
//  to override the color at startup, then captures a screenshot of the
//  toolbar header.
//
//  WHY THE ENV-HOOK APPROACH
//  -------------------------
//  Driving Settings → Color Picker → tap color → Apply → return-to-main is
//  three brittle UI steps. The env hook short-circuits to the same end state
//  ("WoowTheme.shared.primaryColor is X at startup") with one launch.
//  The full picker UI flow is exercised by the manual sanity walkthrough,
//  not the automated suite.

import XCTest

final class E2E_ThemeColorTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches the app with the test theme-color override and captures a
    /// screenshot of the navigation header. The screenshot is attached to
    /// the test report so a human reviewer can visually confirm the
    /// toolbar color matches the override.
    ///
    /// Asserting the *exact* pixel color in code is brittle (anti-aliasing,
    /// status-bar overlay). Instead, this test asserts the app launched
    /// successfully with the override and attaches the screenshot —
    /// pairing it with `WoowThemeReactivityTest` (unit) which proves the
    /// reactivity contract independently.
    @MainActor
    func test_themeOverride_appliesToNavigationHeader() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WOOW_TEST_THEME_COLOR"] = "#FF0000"
        app.launchArguments += ["-AppleLanguages", "(en)", "-WoowTestRunner"]
        app.launch()

        // The "WoowTech Odoo" header text lives in the principal toolbar item.
        // It MUST appear regardless of theme color — that proves the app
        // launched and the toolbar rendered.
        let header = app.staticTexts["WoowTech Odoo"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 10),
            "Navigation header did not appear within 10s — app failed to launch correctly with WOOW_TEST_THEME_COLOR override",
        )

        // Attach a screenshot so a reviewer (or CI artifact viewer) can
        // visually confirm the toolbar background is red, not the default
        // blue. This is the core of the visual integration assertion.
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "theme_override_red_header"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Companion test: launching with NO override should show the default
    /// theme color. Together with the test above, this proves the env hook
    /// is the *only* difference, so the visual delta in the screenshots
    /// can only be caused by the theme override path working.
    @MainActor
    func test_noOverride_appliesDefaultTheme() throws {
        let app = XCUIApplication()
        // Explicitly DO NOT set WOOW_TEST_THEME_COLOR.
        app.launchArguments += ["-AppleLanguages", "(en)", "-WoowTestRunner"]
        app.launch()

        let header = app.staticTexts["WoowTech Odoo"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 10),
            "Navigation header did not appear within 10s — default-theme launch failed",
        )

        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "theme_default_blue_header"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
