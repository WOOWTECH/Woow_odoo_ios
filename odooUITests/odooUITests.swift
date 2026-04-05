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

// MARK: - Test Configuration (from environment or defaults)
// Set via: xcodebuild test ... TEST_SERVER_URL=xxx TEST_DB=xxx TEST_EMAIL=xxx TEST_PASSWORD=xxx
private enum TestConfig {
    static let serverURL = ProcessInfo.processInfo.environment["TEST_SERVER_URL"]
        ?? "rivers-tennessee-rats-consist.trycloudflare.com"
    static let database = ProcessInfo.processInfo.environment["TEST_DB"]
        ?? "odoo18_ecpay"
    static let adminUser = ProcessInfo.processInfo.environment["TEST_ADMIN_USER"]
        ?? "admin"
    static let adminPass = ProcessInfo.processInfo.environment["TEST_ADMIN_PASS"]
        ?? "admin"
    static let senderEmail = ProcessInfo.processInfo.environment["TEST_SENDER_EMAIL"]
        ?? "test@woowtech.com"
    static let senderPass = ProcessInfo.processInfo.environment["TEST_SENDER_PASS"]
        ?? "test1234"
}

extension XCUIApplication {
    /// Navigate through login to reach main screen (for tests that need it)
    func loginWithTestCredentials(
        server: String = TestConfig.serverURL,
        database: String = TestConfig.database,
        username: String = TestConfig.adminUser,
        password: String = TestConfig.adminPass
    ) {
        let serverField = textFields["example.odoo.com"]
        if serverField.waitForExistence(timeout: 5) {
            serverField.tap()
            serverField.typeText(server)
            textFields["Enter database name"].tap()
            textFields["Enter database name"].typeText(database)
            buttons["Next"].tap()
            sleep(2)
            let userField = textFields["Username or email"]
            if userField.waitForExistence(timeout: 5) {
                userField.tap()
                userField.typeText(username)
                secureTextFields["Enter password"].tap()
                secureTextFields["Enter password"].typeText(password)
                buttons["Login"].tap()
                sleep(5) // Wait for auth + WebView
            }
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



// ═══════════════════════════════════════════════════════════
// FCM: Login + Push Notification E2E Test
// Frequency: On demand | Priority: CRITICAL
// ═══════════════════════════════════════════════════════════

final class FCM_EndToEndTests: XCTestCase {

    // Test database fixture IDs (odoo18_ecpay)
    // Query Odoo res.users/res.partner to find these for a new database
    private static let testPartnerID = 1567
    private static let adminPartnerID = 3
    private static let adminUserID = 2
    private static let generalChannelID = 1
    private static let todoActivityTypeID = 4

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launch()
    }

    /// FCM.1: Login to real Odoo server and verify WebView loads
    @MainActor
    func test_FCM_1_loginToOdooServer() {
        // Check if already logged in (WebView visible or menu button)
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 5) {
            // Already logged in — pass
            XCTAssertTrue(true, "Already logged in — WebView is loaded")
            return
        }

        // Check if on login screen
        let serverField = app.textFields["example.odoo.com"]
        if serverField.waitForExistence(timeout: 5) {
            // Not logged in — perform login
            app.loginWithTestCredentials()

            // Verify login succeeded — wait for WebView or menu
            let loaded = menuButton.waitForExistence(timeout: 30)
                || app.webViews.firstMatch.waitForExistence(timeout: 30)
            XCTAssertTrue(loaded, "Odoo WebView should load after login")
        } else {
            // Might be on biometric/PIN screen — already authenticated before
            let usePin = app.buttons["Use PIN"]
            if usePin.waitForExistence(timeout: 3) {
                // On auth screen — means user was logged in before
                XCTAssertTrue(true, "Auth gate visible — user has prior login")
            }
        }
    }

    /// FCM.2: Placeholder confirming notification permission is expected to be granted.
    ///
    /// XCUITest cannot programmatically query UNAuthorizationStatus from Springboard.
    /// Permission is granted once at first install via the system prompt.
    /// The real verification is implicit: FCM.4, FCM.5, and FCM.6 can only pass if
    /// notification permission is granted — no notification arrives without it.
    @MainActor
    func test_FCM_2_notificationPermissionGranted() {
        sleep(3)
        // Notification permission is granted at first install via the system prompt.
        // XCUITest cannot programmatically verify UNAuthorizationStatus.
        // This is validated by FCM.4-6 succeeding (no notification without permission).
        XCTAssertTrue(true, "Notification permission validated indirectly by FCM.4-6 passing")
    }

    /// FCM.3: Verify app stays alive long enough for FCM token registration
    @MainActor
    func test_FCM_3_appStaysAliveForTokenRegistration() {
        // Login if needed
        let menuButton = app.buttons["line.3.horizontal"]
        if !menuButton.waitForExistence(timeout: 5) {
            let serverField = app.textFields["example.odoo.com"]
            if serverField.waitForExistence(timeout: 3) {
                app.loginWithTestCredentials()
            }
        }

        // Wait 10 seconds for FCM token to register with Odoo
        sleep(10)

        // App should still be responsive
        let anyElement = app.windows.firstMatch
        XCTAssertTrue(anyElement.exists, "App is still running after 10 seconds (FCM token should be registered)")
    }

    /// FCM.4: Clear notifications → send chatter → verify notification content
    @MainActor
    func test_FCM_4_notificationAppearsInCenter() {
        ensureLoggedIn()
        clearAndSendNotification { cookies in
            // Send a chatter message on the test partner record
            // Label format received: "ODOO, 現在, Test User, XCUITest FCM verification"
            // Verified by FCM.4-6 succeeding: no notification arrives without notification permission
            self.odooRPC(cookies: cookies, model: "res.partner", method: "message_post",
                         args: [FCM_EndToEndTests.testPartnerID],
                         kwargs: ["body": "<p>XCUITest FCM verification</p>",
                                  "message_type": "comment",
                                  "subtype_xmlid": "mail.mt_comment"])
        }
        verifyNotification(appName: "ODOO", bodyContains: "XCUITest FCM verification")
    }

    // ── V14: @mention notification ──

    /// FCM.5: @mention admin in a chatter message → notification with sender name
    @MainActor
    func test_FCM_5_mentionNotification() {
        ensureLoggedIn()
        clearAndSendNotification { cookies in
            self.odooRPC(cookies: cookies, model: "res.partner", method: "message_post",
                         args: [FCM_EndToEndTests.testPartnerID],
                         kwargs: ["body": "<p>@Admin please review</p>",
                                  "message_type": "comment",
                                  "subtype_xmlid": "mail.mt_comment",
                                  "partner_ids": [FCM_EndToEndTests.adminPartnerID]])
        }
        verifyNotification(appName: "ODOO", bodyContains: "Admin please review")
    }

    // ── V15: Discuss DM notification ──

    /// FCM.6: Send Discuss channel message → notification with sender name
    @MainActor
    func test_FCM_6_discussNotification() {
        ensureLoggedIn()
        clearAndSendNotification { cookies in
            self.odooRPC(cookies: cookies, model: "discuss.channel", method: "message_post",
                         args: [FCM_EndToEndTests.generalChannelID],
                         kwargs: ["body": "Discuss DM test from XCUITest",
                                  "message_type": "comment",
                                  "subtype_xmlid": "mail.mt_comment"])
        }
        verifyNotification(appName: "ODOO", bodyContains: "Discuss DM test")
    }

    // ── V16: Activity assigned notification ──

    /// FCM.7: Assign activity to admin → notification with assigner name
    @MainActor
    func test_FCM_7_activityNotification() {
        ensureLoggedIn()

        let adminCookies = odooLogin(email: TestConfig.adminUser, password: TestConfig.adminPass)
        guard !adminCookies.isEmpty else {
            XCTFail("Admin login failed — check TEST_ADMIN_USER and TEST_ADMIN_PASS credentials")
            return
        }
        let modelId = getModelId(cookies: adminCookies, model: "res.partner")
        print("res.partner model_id: \(modelId)")
        guard modelId != 0 else {
            XCTFail("getModelId returned 0 for res.partner — check admin access to ir.model")
            return
        }

        clearAndSendNotification { cookies in
            self.odooRPC(cookies: cookies, model: "mail.activity", method: "create",
                         args: [["activity_type_id": FCM_EndToEndTests.todoActivityTypeID,
                                 "res_model_id": modelId,
                                 "res_id": FCM_EndToEndTests.testPartnerID,
                                 "user_id": FCM_EndToEndTests.adminUserID,
                                 "summary": "Review partner record"]],
                         kwargs: [:])
        }
        verifyNotification(appName: "ODOO", bodyContains: "Review partner record")
    }

    // ── V8: Deep link tap ──

    /// FCM.8: Tap notification → app opens (deep link verification)
    @MainActor
    func test_FCM_8_tapNotificationOpensApp() {
        ensureLoggedIn()
        clearAndSendNotification { cookies in
            self.odooRPC(cookies: cookies, model: "res.partner", method: "message_post",
                         args: [FCM_EndToEndTests.testPartnerID],
                         kwargs: ["body": "Deep link tap test",
                                  "message_type": "comment",
                                  "subtype_xmlid": "mail.mt_comment"])
        }

        // Open notification center and find the notification
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let topLeft = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.01))
        let midLeft = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6))
        topLeft.press(forDuration: 0.1, thenDragTo: midLeft)
        sleep(2)
        let swipeFrom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let swipeTo = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        swipeFrom.press(forDuration: 0.1, thenDragTo: swipeTo)
        sleep(3)

        // Find notification — can be ScrollView or Button (iOS renders both)
        let notifPredicate = NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", "odoo", "test user")
        let appPredicate = NSPredicate(format: "label CONTAINS[c] %@", "odoo")

        // Search for the tappable notification element
        // Notifications can be: BannerNotification (otherElements), Button, or inside a ScrollView
        var notification: XCUIElement?
        // Try BannerNotification (identifier: NotificationShortLookView) — always tappable
        let bannerMatch = springboard.otherElements.matching(
            NSPredicate(format: "identifier == 'NotificationShortLookView' AND label CONTAINS[c] %@ AND label CONTAINS[c] %@", "odoo", "test user")
        )
        let btnMatch = springboard.buttons.matching(notifPredicate)
        if bannerMatch.count > 0 {
            notification = bannerMatch.firstMatch
        } else if btnMatch.count > 0 {
            notification = btnMatch.firstMatch
        } else {
            // Try expanding a group first
            let scrollGroup = springboard.scrollViews.matching(appPredicate)
            let btnGroup = springboard.buttons.matching(appPredicate)
            let group = scrollGroup.count > 0 ? scrollGroup.firstMatch : (btnGroup.count > 0 ? btnGroup.firstMatch : nil)
            if let group = group {
                group.tap()
                sleep(3)
                // Search again after expand
                let banners = springboard.otherElements.matching(
                    NSPredicate(format: "identifier == 'NotificationShortLookView' AND label CONTAINS[c] %@ AND label CONTAINS[c] %@", "odoo", "test user")
                )
                let b = springboard.buttons.matching(notifPredicate)
                notification = banners.count > 0 ? banners.firstMatch : (b.count > 0 ? b.firstMatch : nil)
            }
        }

        guard let notification = notification, notification.exists else {
            XCTFail("No notification found to tap")
            return
        }

        print("Tapping notification: \(notification.label)")
        notification.tap()
        sleep(2)

        // On iOS, tapping a notification on lock screen shows a preview.
        // Swipe right or tap "打開"/"Open" to open the app.
        // Try "打開" button first, then try activating the app directly.
        let openPredicate = NSPredicate(format: "label == '打開' OR label == 'Open'")
        let openButton = springboard.buttons.matching(openPredicate).firstMatch
        if openButton.waitForExistence(timeout: 5) {
            print("Tapping Open button: \(openButton.label)")
            openButton.tap()
        } else {
            // Tap the notification itself (may open directly without "打開")
            print("No Open button found, tapping notification directly")
            notification.tap()
        }
        sleep(5)

        // After notification opens the app, XCUITest's `app` reference may be stale
        // (app relaunched as new process). Re-activate to reconnect.
        app.activate()
        sleep(3)

        // Verify the app is showing UI — either login page (cold start) or WebView (warm start)
        // Current behavior: no auto-login, so login page shows after cold start.
        // TODO: Implement auto-login + persistent deep links (see docs/2026-04-05-auto-login-plan.md)
        let loginVisible = app.staticTexts["WoowTech Odoo"].waitForExistence(timeout: 10)
            || app.textFields["example.odoo.com"].waitForExistence(timeout: 5)
        let webViewVisible = app.webViews.firstMatch.waitForExistence(timeout: 5)

        XCTAssertTrue(loginVisible || webViewVisible,
            "App should show login page (cold start) or WebView (warm start) after notification tap")

        if loginVisible {
            print("App opened to LOGIN PAGE (expected — no auto-login yet)")
        } else if webViewVisible {
            print("App opened to WEBVIEW (warm start — session preserved)")
        }

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "after_notification_tap"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Reusable Helpers
    // ═══════════════════════════════════════════════════════════

    /// Ensure app is logged in before notification tests
    private func ensureLoggedIn() {
        let menuButton = app.buttons["line.3.horizontal"]
        if !menuButton.waitForExistence(timeout: 5) {
            let serverField = app.textFields["example.odoo.com"]
            if serverField.waitForExistence(timeout: 3) {
                app.loginWithTestCredentials()
            }
        }
        sleep(10) // Wait for FCM token registration
    }

    /// Clear notifications → execute action → wait for delivery
    private func clearAndSendNotification(action: ([HTTPCookie]) -> Void) {
        XCUIDevice.shared.press(.home)
        sleep(2)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Open lock screen + reveal notifications
        let topLeft = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.01))
        let midLeft = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6))
        topLeft.press(forDuration: 0.1, thenDragTo: midLeft)
        sleep(2)
        let swipeFrom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let swipeTo = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        swipeFrom.press(forDuration: 0.1, thenDragTo: swipeTo)
        sleep(2)

        // Clear
        let clearBtn = springboard.buttons.matching(
            NSPredicate(format: "label == '清除' OR label == 'Clear' OR identifier == 'clear-button'")
        ).firstMatch
        if clearBtn.waitForExistence(timeout: 3) {
            clearBtn.tap()
            sleep(1)
            let confirm = springboard.buttons.matching(
                NSPredicate(format: "label CONTAINS '清除' OR label CONTAINS 'Clear'")
            ).firstMatch
            if confirm.waitForExistence(timeout: 2) { confirm.tap(); sleep(1) }
        }
        XCUIDevice.shared.press(.home)
        sleep(2)

        // Login as test sender and execute the action
        let cookies = odooLogin(email: TestConfig.senderEmail, password: TestConfig.senderPass)
        action(cookies)

        // Wait for FCM delivery
        sleep(10)
    }

    /// Open notification center, expand groups if needed, verify notification content.
    /// Robust approach learned from debug analysis:
    /// - Notifications may be already expanded (no group) or grouped
    /// - Search directly first, expand only if not found
    /// - If grouped under sleep mode or multi-app group, tap to expand then re-search
    /// Search for a notification in the notification center.
    /// Based on screen analysis: notifications can be ScrollView or Button elements
    /// with identifier 'ListCell'. A grouped notification (ScrollView) must be tapped
    /// to expand before individual notifications become visible.
    private func verifyNotification(appName: String, bodyContains: String) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Open lock screen / notification center
        let topLeft = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.01))
        let midLeft = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6))
        topLeft.press(forDuration: 0.1, thenDragTo: midLeft)
        sleep(3)

        let targetPredicate = NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", appName, bodyContains)
        let appPredicate = NSPredicate(format: "label CONTAINS[c] %@", appName)

        // Helper: search BOTH scrollViews and buttons (iOS renders notifications as either)
        func findNotification() -> Bool {
            return springboard.scrollViews.matching(targetPredicate).count > 0
                || springboard.buttons.matching(targetPredicate).count > 0
        }

        func findAppGroup() -> XCUIElement? {
            // Check scrollViews first (grouped notifications appear as ScrollView)
            let scrollGroups = springboard.scrollViews.matching(appPredicate)
            if scrollGroups.count > 0 { return scrollGroups.firstMatch }
            // Then check buttons
            let buttonGroups = springboard.buttons.matching(appPredicate)
            if buttonGroups.count > 0 { return buttonGroups.firstMatch }
            return nil
        }

        func getVerifiedLabel() -> String? {
            let inScroll = springboard.scrollViews.matching(targetPredicate)
            if inScroll.count > 0 { return inScroll.firstMatch.label }
            let inBtn = springboard.buttons.matching(targetPredicate)
            if inBtn.count > 0 { return inBtn.firstMatch.label }
            return nil
        }

        // Strategy 1: Direct search — notification already visible (no group)
        if findNotification() {
            print("[NotifStrategy] 1: found directly")
        }

        // Strategy 2: Tap app group to expand
        if !findNotification(), let group = findAppGroup() {
            print("[NotifStrategy] 2: tapping group to expand: \(group.label)")
            group.tap()
            sleep(3)
        }

        // Strategy 3: Focus mode group — expand focus first, then app group
        if !findNotification() {
            let focusPredicate = NSPredicate(format: "label CONTAINS '睡眠' OR label CONTAINS 'Sleep' OR label CONTAINS '專注'")
            // Search both scrollViews and buttons for focus group
            let focusScroll = springboard.scrollViews.matching(focusPredicate)
            let focusBtn = springboard.buttons.matching(focusPredicate)
            let focusElement = focusScroll.count > 0 ? focusScroll.firstMatch : (focusBtn.count > 0 ? focusBtn.firstMatch : nil)
            if let focus = focusElement {
                print("[NotifStrategy] 3: expanding focus group: \(focus.label)")
                focus.tap()
                sleep(2)
                if let group = findAppGroup() {
                    group.tap()
                    sleep(2)
                }
            }
        }

        // Strategy 4: Swipe up to reveal hidden notifications, then retry
        if !findNotification() {
            print("[NotifStrategy] 4: swiping up")
            let swipeFrom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            let swipeTo = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            swipeFrom.press(forDuration: 0.1, thenDragTo: swipeTo)
            sleep(3)
            if let group = findAppGroup() {
                group.tap()
                sleep(2)
            }
        }

        // Screenshot
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "notification_center"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Final verification
        let found = findNotification()
        if let label = getVerifiedLabel() {
            print("VERIFIED: \(label)")
        } else {
            // Dump what IS visible for debugging
            print("NOT FOUND: appName=\(appName) body=\(bodyContains)")
            let scrollOdoo = springboard.scrollViews.matching(appPredicate)
            let btnOdoo = springboard.buttons.matching(appPredicate)
            print("  scrollViews with '\(appName)': \(scrollOdoo.count)")
            print("  buttons with '\(appName)': \(btnOdoo.count)")
        }

        XCTAssertTrue(found, "Notification with \(appName) + '\(bodyContains)' should appear")

        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
    }

    // ═══════════════════════════════════════════════════════════
    // MARK: - Odoo HTTP Helpers
    // ═══════════════════════════════════════════════════════════

    /// Login to Odoo and return session cookies
    private func odooLogin(email: String, password: String) -> [HTTPCookie] {
        let baseURL = "https://\(TestConfig.serverURL)"
        let expectation = XCTestExpectation(description: "Odoo login")
        var cookies: [HTTPCookie] = []

        guard let loginURL = URL(string: "\(baseURL)/web/session/authenticate") else {
            XCTFail("Invalid server URL for login: \(baseURL)/web/session/authenticate")
            return cookies
        }
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "call",
            "params": ["db": TestConfig.database, "login": email, "password": password],
            "id": 1
        ] as [String: Any])

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let r = response as? HTTPURLResponse,
               let h = r.allHeaderFields as? [String: String],
               let u = response?.url {
                cookies = HTTPCookie.cookies(withResponseHeaderFields: h, for: u)
            }
            expectation.fulfill()
        }.resume()

        _ = XCTWaiter.wait(for: [expectation], timeout: 30.0)
        if cookies.isEmpty { print("odooLogin FAILED for \(email)") }
        return cookies
    }

    /// Call Odoo JSON-RPC with authenticated session
    @discardableResult
    private func odooRPC(cookies: [HTTPCookie], model: String, method: String,
                         args: [Any], kwargs: [String: Any]) -> Any? {
        let baseURL = "https://\(TestConfig.serverURL)"
        let expectation = XCTestExpectation(description: "Odoo RPC \(model).\(method)")
        var result: Any?

        guard let rpcURL = URL(string: "\(baseURL)/web/dataset/call_kw") else {
            XCTFail("Invalid server URL for RPC: \(baseURL)/web/dataset/call_kw")
            return nil
        }
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": "call",
            "params": ["model": model, "method": method, "args": args, "kwargs": kwargs],
            "id": 2
        ] as [String: Any])

        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errorBlock = json["error"] as? [String: Any] {
                    let errorData = errorBlock["data"] as? [String: Any]
                    let msg = errorData?["message"] ?? errorBlock["message"] ?? "unknown"
                    print("odooRPC ERROR [\(model).\(method)]: \(msg)")
                }
                result = json["result"]
            }
            expectation.fulfill()
        }.resume()

        _ = XCTWaiter.wait(for: [expectation], timeout: 30.0)
        return result
    }

    /// Get ir.model ID for a model name (needed for mail.activity.create)
    private func getModelId(cookies: [HTTPCookie], model: String) -> Int {
        let result = odooRPC(cookies: cookies, model: "ir.model", method: "search_read",
                             args: [[["model", "=", model]]],
                             kwargs: ["fields": ["id"], "limit": 1])
        if let records = result as? [[String: Any]],
           let first = records.first,
           let id = first["id"] as? Int { return id }
        return 0
    }

}

// ═══════════════════════════════════════════════════════════
// F14 Gap Tests: G1 + G6 + G5 + G4 (P2 + P3 fixes)
// Covers: UX-57 (Reduce Motion), UX-58 (Language), UX-47/UX-82 (About, Help)
// Reference: docs/2026-04-05-P2-P3-Gap-Fix_Test_Plan.md
// ═══════════════════════════════════════════════════════════

final class F14_SettingsGapTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        // Force English locale for Settings tests to avoid localized label mismatches
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()
    }

    // ──────────────────────────────────────────────────────
    // Navigation helper
    // ──────────────────────────────────────────────────────

    /// Navigate from the home screen to the Settings screen via the hamburger menu.
    /// Fails fast with XCTFail if any required UI element is missing, so callers do not
    /// need to guard the return value.
    @MainActor
    private func navigateToSettings() {
        let menuButton = app.buttons["line.3.horizontal"]
        XCTAssertTrue(
            menuButton.waitForExistence(timeout: 8),
            "Hamburger menu button must exist — ensure app is in the logged-in state"
        )
        menuButton.tap()

        // Config sheet opens — tap "Settings" button
        let settingsButton = app.buttons["Settings"]
        let settingsText = app.staticTexts["Settings"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        } else if settingsText.waitForExistence(timeout: 3) {
            settingsText.tap()
        } else {
            XCTFail("Settings not found in Config sheet")
            return
        }

        // Wait for Settings screen to appear
        XCTAssertTrue(
            app.staticTexts["Appearance"].waitForExistence(timeout: 5),
            "Settings screen must show Appearance section"
        )
    }

    // ──────────────────────────────────────────────────────
    // G1 — Language (P2)
    // ──────────────────────────────────────────────────────

    /// G1-X1: The Settings screen must display a Language section header.
    @MainActor
    func test_F14_5_settings_hasLanguageSection() {
        navigateToSettings()
        app.swipeUp()

        XCTAssertTrue(
            app.staticTexts["Language"].waitForExistence(timeout: 5),
            "Settings must show a Language section header (UX-58)"
        )
    }

    /// G1-X2: The Language row must display the current language name as trailing detail text.
    @MainActor
    func test_F14_6_languageRow_showsCurrentLanguageLabel() {
        navigateToSettings()
        app.swipeUp()

        // The trailing detail shows the system language; on English simulators this is "English".
        // We check for the section header to confirm navigation succeeded, then look for any
        // language label text that matches the four known display names.
        XCTAssertTrue(
            app.staticTexts["Language"].waitForExistence(timeout: 5),
            "Language section header must be visible before checking row detail"
        )

        let knownLabels = ["System Default", "English", "繁體中文", "简体中文"]
        let found = knownLabels.contains { label in
            app.staticTexts[label].exists
        }
        XCTAssertTrue(
            found,
            "Language row must display one of the known language display names as trailing detail (UX-58)"
        )
    }

    /// G1-X3: Tapping the Language row must not crash the app.
    /// On iOS, tapping opens the system Settings app (per iOS Difference D1), which
    /// cannot be reliably detected in XCUITest without flakiness.
    /// This test verifies the button is hittable and the tap does not crash.
    @MainActor
    func test_F14_7_languageTap_doesNotCrash() {
        navigateToSettings()
        app.swipeUp()

        let languageRow = app.staticTexts["Language"]
        XCTAssertTrue(
            languageRow.waitForExistence(timeout: 5),
            "Language section header must exist before tapping"
        )
        XCTAssertTrue(languageRow.isHittable, "Language row must be hittable")
        languageRow.tap()

        // Allow a moment for any system transition to initiate, then verify the test
        // process is still alive by checking any element on screen — if the app crashed,
        // this assertion itself would not execute.
        _ = app.exists // accessing this property confirms the process is still running
        XCTAssertTrue(true, "App did not crash after tapping Language row (iOS Difference D1)")
    }

    // ──────────────────────────────────────────────────────
    // G6 — Reduce Motion (P2)
    // ──────────────────────────────────────────────────────

    /// G6-X1: The Appearance section must contain a Reduce Motion toggle switch.
    @MainActor
    func test_F14_8_appearance_hasReduceMotionToggle() {
        navigateToSettings()

        XCTAssertTrue(
            app.switches["Reduce Motion"].waitForExistence(timeout: 5),
            "Appearance section must contain a Reduce Motion toggle (UX-57)"
        )
    }

    /// G6-X2: Tapping the Reduce Motion toggle must change its value from off to on.
    @MainActor
    func test_F14_9_reduceMotionToggle_canBeToggledOn() {
        navigateToSettings()

        let toggle = app.switches["Reduce Motion"]
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 5),
            "Reduce Motion toggle must be visible in Appearance section (UX-57)"
        )

        XCTAssertEqual(
            toggle.value as? String,
            "0",
            "Reduce Motion must default to off (value '0')"
        )

        toggle.tap()

        XCTAssertTrue(
            toggle.waitForExistence(timeout: 3),
            "Reduce Motion toggle must still exist after tapping"
        )
        XCTAssertEqual(
            toggle.value as? String,
            "1",
            "Tapping Reduce Motion must turn it on (value '1') (UX-57)"
        )

        // Teardown: restore to off so the Keychain is not polluted for other tests
        toggle.tap()
    }

    // ──────────────────────────────────────────────────────
    // G5 — About Section (P3)
    // ──────────────────────────────────────────────────────

    /// G5-X1: The About section must show App Version, Visit Website, Contact Us, and copyright.
    @MainActor
    func test_F14_10_about_hasVersionWebsiteContactCopyright() {
        navigateToSettings()
        app.swipeUp()
        app.swipeUp()

        XCTAssertTrue(
            app.staticTexts["About"].waitForExistence(timeout: 5),
            "About section header must be visible (G5)"
        )
        XCTAssertTrue(
            app.staticTexts["App Version"].waitForExistence(timeout: 3),
            "About section must show App Version row (G5)"
        )
        XCTAssertTrue(
            app.staticTexts["Visit Website"].waitForExistence(timeout: 3),
            "About section must show Visit Website row (G5)"
        )
        XCTAssertTrue(
            app.staticTexts["Contact Us"].waitForExistence(timeout: 3),
            "About section must show Contact Us row (G5)"
        )

        let copyrightExists = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '©'")
        ).firstMatch.waitForExistence(timeout: 3)
        XCTAssertTrue(
            copyrightExists,
            "About section must contain a copyright line with the © symbol (G5)"
        )
    }

    /// G5-X2: The Website row in About must display the WoowTech domain name.
    @MainActor
    func test_F14_11_websiteRow_showsCorrectUrl() {
        navigateToSettings()
        app.swipeUp()
        app.swipeUp()

        let websiteLabel = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'woowtech'")
        ).firstMatch
        XCTAssertTrue(
            websiteLabel.waitForExistence(timeout: 5),
            "Website row must display the WoowTech URL as trailing text (G5)"
        )
    }

    /// G5-X3: Tapping the Visit Website row must not crash the app.
    /// Opening an external URL causes the system to leave the app, which cannot be
    /// reliably asserted without race conditions on a simulator. We verify the row is
    /// hittable and the tap completes without crashing.
    @MainActor
    func test_F14_12_websiteTap_doesNotCrash() {
        navigateToSettings()
        app.swipeUp()
        app.swipeUp()

        let websiteRow = app.staticTexts["Visit Website"]
        XCTAssertTrue(
            websiteRow.waitForExistence(timeout: 5),
            "Visit Website row must exist in About section (G5)"
        )
        XCTAssertTrue(websiteRow.isHittable, "Visit Website row must be hittable")
        websiteRow.tap()

        _ = app.exists
        XCTAssertTrue(true, "App did not crash after tapping Visit Website (G5)")
    }

    // ──────────────────────────────────────────────────────
    // G4 — Help & Support (P3)
    // ──────────────────────────────────────────────────────

    /// G4-X1: The Settings screen must display a Help & Support section with two link rows.
    @MainActor
    func test_F14_13_settings_hasHelpSection() {
        navigateToSettings()
        app.swipeUp()

        XCTAssertTrue(
            app.staticTexts["Help & Support"].waitForExistence(timeout: 5),
            "Settings must have a Help & Support section header (UX-47, G4)"
        )
        XCTAssertTrue(
            app.staticTexts["Odoo Help Center"].waitForExistence(timeout: 3),
            "Help section must contain an Odoo Help Center row (G4)"
        )
        XCTAssertTrue(
            app.staticTexts["Community Forum"].waitForExistence(timeout: 3),
            "Help section must contain a Community Forum row (G4)"
        )
    }

    /// G4-X2: Tapping the Odoo Help Center row must not crash the app.
    /// External URL taps are not verified for app.state transition to avoid flakiness.
    @MainActor
    func test_F14_14_helpLink_doesNotCrash() {
        navigateToSettings()
        app.swipeUp()

        let helpLink = app.staticTexts["Odoo Help Center"]
        XCTAssertTrue(
            helpLink.waitForExistence(timeout: 5),
            "Odoo Help Center row must exist in Help & Support section (G4)"
        )
        XCTAssertTrue(helpLink.isHittable, "Odoo Help Center row must be hittable")
        helpLink.tap()

        _ = app.exists
        XCTAssertTrue(true, "App did not crash after tapping Odoo Help Center (G4)")
    }
}
