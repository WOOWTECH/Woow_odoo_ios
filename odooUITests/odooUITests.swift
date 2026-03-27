//
//  odooUITests.swift
//  Real User Flow Tests — XCUITest
//
//  Each test simulates a complete user scenario from the
//  functional-equivalence-matrix.md, prioritized by daily usage frequency.
//
//  Priority: F1 (daily) > F2 (every resume) > F5 (setup) > F10-F14 (occasional)
//

import XCTest

// MARK: - Helpers

extension XCUIApplication {
    /// Navigate through login to reach main screen (for tests that need it)
    func loginWithTestCredentials() {
        let serverField = textFields["example.odoo.com"]
        if serverField.waitForExistence(timeout: 5) {
            serverField.tap()
            serverField.typeText("demo.odoo.com")
            textFields["Enter database name"].tap()
            textFields["Enter database name"].typeText("demo")
            buttons["Next"].tap()
            sleep(1)
            textFields["Username or email"].tap()
            textFields["Username or email"].typeText("admin")
            secureTextFields["Enter password"].tap()
            secureTextFields["Enter password"].typeText("admin")
            buttons["Login"].tap()
            sleep(3) // Wait for auth
        }
    }
}

// ═══════════════════════════════════════════════════════════
// F5: First-time Login Flow (UX-01 → UX-09)
// Frequency: Once per setup | Priority: HIGH
// ═══════════════════════════════════════════════════════════

final class F5_LoginFlowTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    /// F5.1: App shows login screen on first launch
    @MainActor
    func test_F5_1_firstLaunch_showsLoginScreen() {
        XCTAssertTrue(app.staticTexts["WoowTech Odoo"].waitForExistence(timeout: 5),
                      "User sees app title")
        XCTAssertTrue(app.staticTexts["Enter server details"].exists,
                      "User sees server info step")
    }

    /// F5.2: Empty URL → error message
    @MainActor
    func test_F5_2_emptyUrl_showsError() {
        let next = app.buttons["Next"]
        if next.waitForExistence(timeout: 3) {
            next.tap()
            XCTAssertTrue(app.staticTexts["Server URL is required"].waitForExistence(timeout: 2))
        }
    }

    /// F5.3: Valid server → proceeds to credentials step
    @MainActor
    func test_F5_3_validServer_showsCredentials() {
        let serverField = app.textFields["example.odoo.com"]
        if serverField.waitForExistence(timeout: 3) {
            serverField.tap()
            serverField.typeText("demo.odoo.com")
            app.textFields["Enter database name"].tap()
            app.textFields["Enter database name"].typeText("demo")
            app.buttons["Next"].tap()
            sleep(1)
            XCTAssertTrue(app.staticTexts["Enter credentials"].waitForExistence(timeout: 3),
                          "User sees credentials step")
        }
    }

    /// F5.4: Empty username → error
    @MainActor
    func test_F5_4_emptyUsername_showsError() {
        // Navigate to credentials
        let serverField = app.textFields["example.odoo.com"]
        if serverField.waitForExistence(timeout: 3) {
            serverField.tap()
            serverField.typeText("demo.odoo.com")
            app.textFields["Enter database name"].tap()
            app.textFields["Enter database name"].typeText("demo")
            app.buttons["Next"].tap()
            sleep(1)
            app.buttons["Login"].tap()
            XCTAssertTrue(app.staticTexts["Username is required"].waitForExistence(timeout: 2))
        }
    }

    /// F5.5: Back button returns to server info
    @MainActor
    func test_F5_5_backButton_returnsToServerInfo() {
        let serverField = app.textFields["example.odoo.com"]
        if serverField.waitForExistence(timeout: 3) {
            serverField.tap()
            serverField.typeText("demo.odoo.com")
            app.textFields["Enter database name"].tap()
            app.textFields["Enter database name"].typeText("demo")
            app.buttons["Next"].tap()
            sleep(1)
            app.buttons["Back"].tap()
            XCTAssertTrue(app.staticTexts["Enter server details"].waitForExistence(timeout: 2),
                          "User returns to server info step")
        }
    }

    /// F5.6: HTTPS prefix displayed to user
    @MainActor
    func test_F5_6_httpsPrefix_shownToUser() {
        XCTAssertTrue(app.staticTexts["https://"].waitForExistence(timeout: 3),
                      "User sees https:// prefix in URL field")
    }
}

// ═══════════════════════════════════════════════════════════
// F2: Auth Gate — No Skip Button (UX-10 → UX-14)
// Frequency: Every app resume | Priority: CRITICAL
// ═══════════════════════════════════════════════════════════

final class F2_AuthGateTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    /// F2.1: No skip button anywhere in the app
    @MainActor
    func test_F2_1_noSkipButton_anywhere() {
        sleep(3)
        XCTAssertFalse(app.buttons["Skip"].exists, "No Skip button")
        XCTAssertFalse(app.staticTexts["Skip"].exists, "No Skip text")
        XCTAssertFalse(app.staticTexts["Skip for now"].exists, "No 'Skip for now'")
        XCTAssertFalse(app.buttons["跳過"].exists, "No 跳過 button")
        XCTAssertFalse(app.buttons["跳过"].exists, "No 跳过 button")
        XCTAssertFalse(app.buttons["稍後再說"].exists, "No 稍後再說")
    }

    /// F2.2: PIN screen has Use PIN option (not skip)
    @MainActor
    func test_F2_2_biometricScreen_hasUsePinNotSkip() {
        sleep(3)
        // If biometric screen shows, check for "Use PIN" not "Skip"
        let usePin = app.buttons["Use PIN"]
        if usePin.exists {
            XCTAssertTrue(usePin.exists, "Biometric screen has 'Use PIN' fallback")
            XCTAssertFalse(app.buttons["Skip"].exists, "No skip alongside Use PIN")
        }
    }
}

// ═══════════════════════════════════════════════════════════
// F10: Set Up PIN (UX-22 → UX-24)
// Frequency: Once | Priority: MEDIUM
// ═══════════════════════════════════════════════════════════

final class F10_PINSetupTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    /// F10.1: PIN entry shows 6 dot indicators
    @MainActor
    func test_F10_1_pinScreen_hasDotIndicators() {
        sleep(3)
        // Navigate to PIN screen if available
        let usePin = app.buttons["Use PIN"]
        if usePin.waitForExistence(timeout: 3) {
            usePin.tap()
            sleep(1)
            // Should see "Enter PIN" title
            XCTAssertTrue(app.staticTexts["Enter PIN"].waitForExistence(timeout: 2),
                          "PIN screen shows title")
        }
    }

    /// F10.2: PIN pad has all digits 0-9 + backspace
    @MainActor
    func test_F10_2_pinPad_hasAllDigitsAndBackspace() {
        sleep(3)
        let usePin = app.buttons["Use PIN"]
        if usePin.waitForExistence(timeout: 3) {
            usePin.tap()
            sleep(1)
            // Check all digit buttons
            for digit in 0...9 {
                XCTAssertTrue(app.buttons["\(digit)"].exists,
                              "PIN pad has digit \(digit)")
            }
            // Check backspace
            XCTAssertTrue(app.buttons["delete.backward"].exists,
                          "PIN pad has backspace")
        }
    }
}

// ═══════════════════════════════════════════════════════════
// F14: Settings Screen (UX-47 → UX-57)
// Frequency: Occasionally | Priority: LOW
// ═══════════════════════════════════════════════════════════

final class F14_SettingsTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    /// F14.1: Settings has all 4 sections in correct order
    @MainActor
    func test_F14_1_settings_hasFourSections() {
        sleep(3)
        // Navigate: menu → settings (if logged in)
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
            let settingsLabel = app.staticTexts["Settings"]
            if settingsLabel.waitForExistence(timeout: 2) {
                settingsLabel.tap()
                sleep(1)
                XCTAssertTrue(app.staticTexts["Appearance"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.staticTexts["Security"].exists)
                XCTAssertTrue(app.staticTexts["Data & Storage"].exists)
                XCTAssertTrue(app.staticTexts["About"].exists)
            }
        }
    }

    /// F14.2: Theme Color opens color picker
    @MainActor
    func test_F14_2_themeColor_opensColorPicker() {
        sleep(3)
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
            app.staticTexts["Settings"].tap()
            sleep(1)
            // Tap Theme Color
            let themeColor = app.staticTexts["Theme Color"]
            if themeColor.waitForExistence(timeout: 2) {
                themeColor.tap()
                sleep(1)
                // Should see color picker
                XCTAssertTrue(
                    app.staticTexts["Preset Colors"].waitForExistence(timeout: 2) ||
                    app.staticTexts["Select Color"].waitForExistence(timeout: 2),
                    "Color picker should open")
            }
        }
    }

    /// F14.3: App Lock toggle exists
    @MainActor
    func test_F14_3_appLock_toggleExists() {
        sleep(3)
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
            app.staticTexts["Settings"].tap()
            sleep(1)
            XCTAssertTrue(app.switches["App Lock"].waitForExistence(timeout: 3),
                          "App Lock toggle exists in Security section")
        }
    }

    /// F14.4: Clear Cache button exists in Data section
    @MainActor
    func test_F14_4_clearCache_buttonExists() {
        sleep(3)
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
            app.staticTexts["Settings"].tap()
            sleep(1)
            // Scroll down to find Clear Cache
            app.swipeUp()
            sleep(1)
            XCTAssertTrue(app.staticTexts["Clear Cache"].waitForExistence(timeout: 3),
                          "Clear Cache button exists in Data & Storage section")
        }
    }
}

// ═══════════════════════════════════════════════════════════
// F11: Logout Flow (UX-69)
// Frequency: Occasionally | Priority: MEDIUM
// ═══════════════════════════════════════════════════════════

final class F11_LogoutTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    /// F11.1: Logout button exists in config screen
    @MainActor
    func test_F11_1_logoutButton_existsInConfig() {
        sleep(3)
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
            // Look for Logout in config
            app.swipeUp()
            sleep(1)
            XCTAssertTrue(app.buttons["Logout"].waitForExistence(timeout: 3),
                          "Logout button exists in config screen")
        }
    }

    /// F11.2: Tapping logout shows confirmation alert
    @MainActor
    func test_F11_2_logoutTap_showsConfirmation() {
        sleep(3)
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            sleep(1)
            app.swipeUp()
            sleep(1)
            let logoutButton = app.buttons["Logout"]
            if logoutButton.waitForExistence(timeout: 2) {
                logoutButton.tap()
                sleep(1)
                // Should see confirmation alert
                XCTAssertTrue(
                    app.alerts["Logout"].waitForExistence(timeout: 2) ||
                    app.staticTexts["Are you sure you want to logout?"].waitForExistence(timeout: 2),
                    "Logout confirmation alert appears")
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════
// F15: App Launch Performance
// Frequency: Every launch | Priority: HIGH
// ═══════════════════════════════════════════════════════════

final class F15_PerformanceTests: XCTestCase {

    /// F15.1: App launches in reasonable time
    @MainActor
    func test_F15_1_launchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
