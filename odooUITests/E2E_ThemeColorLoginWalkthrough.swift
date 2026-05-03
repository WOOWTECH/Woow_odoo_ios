//
//  E2E_ThemeColorLoginWalkthrough.swift
//  odooUITests
//
//  One-shot real-server walkthrough so a human reviewer can SEE that the
//  theme color persists through the actual login flow against the live
//  Odoo (via the cloudflared tunnel configured in TestConfig.plist).
//
//  WHY THIS COMPLEMENTS E2E_ThemeColorTests
//  ----------------------------------------
//  `E2E_ThemeColorTests` only screenshots the launch state — it doesn't
//  verify the color survives across the login → main-screen transition.
//  This walkthrough drives the actual login UI with real credentials,
//  waits for the WebView to load, and screenshots the post-login header.
//  The screenshot is the visual evidence.

import XCTest

final class E2E_ThemeColorLoginWalkthrough: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func test_themeColorSurvivesLoginAgainstLiveServer() throws {
        let app = XCUIApplication()
        // Override the theme to a clearly-distinct GREEN so the user can
        // visually confirm the picker color is what's actually showing
        // (vs. the default blue or any cached Odoo color).
        app.launchEnvironment["WOOW_TEST_THEME_COLOR"] = "#00C853"
        app.launchArguments += ["-AppleLanguages", "(en)", "-WoowTestRunner"]
        app.launch()

        // Screenshot 1: login screen with green theme accent
        attachScreenshot(named: "1_login_screen_green_theme", app: app)

        // Drive the real login walk against the live tunnel. Credentials
        // come from TestConfig.plist (single source of truth).
        app.loginWithTestCredentials()

        // Wait up to 30s for the WebView to load Odoo content. The header
        // text must appear regardless of WebView readiness.
        let header = app.staticTexts["WoowTech Odoo"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 30),
            "Main screen header did not appear within 30s after login — Odoo tunnel may be unreachable",
        )

        // Give the WebView an extra moment to render so the screenshot
        // captures the post-login state cleanly.
        sleep(3)

        // Screenshot 2: main screen post-login. Header should be GREEN
        // (theme override) — this is the visual proof the color survives
        // the login transition.
        attachScreenshot(named: "2_main_screen_green_theme", app: app)
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
