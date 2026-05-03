//
//  E2E_ThemeAcrossAllViews.swift
//  odooUITests
//
//  Visual proof that every one of the 6 user-visible iOS views observes
//  the theme color. Walks through the app under a GREEN theme override
//  (`WOOW_TEST_THEME_COLOR=#00C853`) and captures one screenshot per view.
//
//  Coverage:
//    1. LoginView          — captured at app launch
//    2. MainView toolbar    — captured after successful login
//    3. ConfigView          — opened via hamburger menu
//    4. SettingsView        — Config → Settings row
//    5. BiometricView       — see TestPlan note (preview-rendered)
//    6. PinView             — see TestPlan note (preview-rendered)
//
//  Each screenshot is attached to the test report so a reviewer can
//  visually confirm the green theme is being honored.

import XCTest

final class E2E_ThemeAcrossAllViews: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Wipe state that the test hooks write to SecureStorage so each test
    /// in this class starts from a clean slate. Without this, the
    /// alphabetically-first test (`test_themeApplied_toBiometricView`)
    /// leaves `appLockEnabled=true` in the simulator's keychain, and the
    /// next test (`test_themeApplied_toEveryUserVisibleView`) routes to
    /// BiometricView instead of LoginView at launch — making the login
    /// walkthrough impossible.
    /// CLAUDE.md "Test Independence" rule.
    @MainActor
    override func tearDown() async throws {
        // Launch a one-shot session that wipes state. We use the existing
        // `-ResetAppState` launch arg supported by `AppDelegate`.
        let cleanup = XCUIApplication()
        cleanup.launchArguments = ["-ResetAppState"]
        cleanup.launch()
        cleanup.terminate()
        try await super.tearDown()
    }

    @MainActor
    func test_themeApplied_toEveryUserVisibleView() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WOOW_TEST_THEME_COLOR"] = "#00C853"
        app.launchArguments += ["-AppleLanguages", "(en)", "-WoowTestRunner"]
        app.launch()

        // ── 1. LoginView (logo, Next button) ──
        attach("1_LoginView_serverInfoStep", app: app)

        // Drive login against live tunnel so we exit the LoginView and
        // reach MainView with WebView loaded.
        app.loginWithTestCredentials()

        // ── 2. MainView toolbar (header) ──
        let header = app.staticTexts["WoowTech Odoo"]
        XCTAssertTrue(
            header.waitForExistence(timeout: 30),
            "Main screen header did not appear within 30s — login may have failed",
        )
        sleep(3) // let WebView settle so screenshot is clean
        attach("2_MainView_toolbarHeader", app: app)

        // ── 3. ConfigView (profile bubble background) ──
        // Tap the hamburger (menu) button in the trailing toolbar slot.
        let menuButton = app.buttons["line.3.horizontal"]
        XCTAssertTrue(
            menuButton.waitForExistence(timeout: 5),
            "Menu (hamburger) button not found — cannot open ConfigView",
        )
        menuButton.tap()
        sleep(2)
        attach("3_ConfigView_profileBubble", app: app)

        // ── 4. SettingsView (PIN code label color) ──
        // Tap the Settings row inside the Config sheet.
        let settingsRow = app.buttons["Settings"]
        if settingsRow.waitForExistence(timeout: 5) {
            settingsRow.tap()
            sleep(2)
            attach("4_SettingsView_pinCodeLabel", app: app)

            // Bonus: scroll down to also show the SettingsView footer
            // / Reduce Motion toggle if it's themed.
            app.swipeUp()
            sleep(1)
            attach("4b_SettingsView_scrolled", app: app)
        } else {
            XCTFail("Settings row not found in Config sheet")
        }

    }

    /// 5. BiometricView — the icon + "Unlock" button tint should be GREEN.
    ///
    /// Pre-condition: app lock + biometric must be ON at launch. We use the
    /// `WOOW_TEST_FORCE_BIOMETRIC` test hook (DEBUG-only, see
    /// `AppDelegate.swift`) which seeds `appLockEnabled=true` +
    /// `biometricEnabled=true` BEFORE `AppRootView` reads them, so the
    /// auth-required branch routes to BiometricView at launch.
    @MainActor
    func test_themeApplied_toBiometricView() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WOOW_TEST_THEME_COLOR"] = "#00C853"
        app.launchEnvironment["WOOW_TEST_FORCE_BIOMETRIC"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-WoowTestRunner"]
        app.launch()

        // The fingerprint icon + Unlock button identify BiometricView.
        // The simulator has no biometric hardware so the icon falls back
        // to "touchid" and the button label may be "Unlock with Touch ID".
        // Either way, the screen is reached.
        sleep(3) // let the auth flow render and any LAContext probe settle

        attach("5_BiometricView_iconAndButton", app: app)
    }

    /// 6. PinView — the PIN dots + stroke should be GREEN.
    ///
    /// Pre-condition: app lock + PIN configured. The `WOOW_TEST_FORCE_PIN`
    /// hook sets both. The launch lands on BiometricView; tapping
    /// "Use PIN" routes to PinView (per `AppRootView` `showPin` toggle).
    @MainActor
    func test_themeApplied_toPinView() throws {
        let app = XCUIApplication()
        app.launchEnvironment["WOOW_TEST_THEME_COLOR"] = "#00C853"
        app.launchEnvironment["WOOW_TEST_FORCE_PIN"] = "1234"
        app.launchArguments += ["-AppleLanguages", "(en)", "-WoowTestRunner"]
        app.launch()

        sleep(2)
        // Tap the "Use PIN" fallback button on BiometricView to reach
        // PinView. Match the localized label.
        let usePin = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'PIN'")).firstMatch
        if usePin.waitForExistence(timeout: 5) {
            usePin.tap()
        }
        sleep(2)

        // Tap a PIN digit so at least one of the dots is filled — that's
        // the dot whose `theme.primaryColor` fill should be GREEN.
        let one = app.buttons["1"]
        if one.waitForExistence(timeout: 5) {
            one.tap()
            sleep(1)
        }

        attach("6_PinView_filledDot", app: app)
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let screenshot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
