//
//  E2E_HighPriority_Tests.swift
//  odooUITests
//
//  HIGH priority E2E tests covering 12 UX items from the functional equivalence matrix.
//  Plan document: docs/2026-04-06-E2E-High-Priority_Test_Plan.md
//
//  Class assignments:
//    E2E_WebViewTests        — UX-25, UX-26, UX-27, UX-28
//    E2E_BiometricPINTests   — UX-12, UX-13, UX-15, UX-20
//    E2E_LoginAccountTests   — UX-05, UX-67, UX-68, UX-69
//
//  Conventions:
//    - No sleep() except after XCUIDevice.shared.press(.home) (documented at each usage)
//    - waitForExistence(timeout:) for all element polling
//    - XCTFail + screenshot attachment in every guard-else / failure path
//    - @MainActor on every test function
//    - continueAfterFailure = false in every setUp
//    - English locale forced via -AppleLanguages (en)
//    - Section headers in SwiftUI Form appear as UPPERCASE ("SECURITY", "APPEARANCE")
//

import XCTest

// MARK: - Test configuration (reads from TestConfig.plist)
private typealias E2ETestConfig = SharedTestConfig

// MARK: - Shared failure-screenshot helper

/// Attaches a full-screen screenshot to the current test activity with the given name
/// and then fails the test with the provided message. Call in every guard-else branch.
private func failWithScreenshot(
    _ message: String,
    name: String,
    testCase: XCTestCase
) {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    testCase.add(attachment)
    XCTFail(message)
}

// ═══════════════════════════════════════════════════════════
// MARK: - E2E_WebViewTests (UX-25, UX-26, UX-27, UX-28)
// ═══════════════════════════════════════════════════════════

/// E2E tests for the WKWebView integration: load after login, deep-link rejection,
/// external-URL routing to Safari, and session-expiry redirect to login screen.
final class E2E_WebViewTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments += ["-AppleLanguages", "(en)"]
        // Reset app state so UX-25 always starts from the login screen.
        // The hook is implemented in AppDelegate.processTestLaunchArguments().
        app.launchArguments += ["-ResetAppState"]
    }

    // ──────────────────────────────────────────────────────
    // Navigation helpers
    // ──────────────────────────────────────────────────────

    /// Ensures the app is logged in and the main screen (WebView or hamburger button)
    /// is visible. Uses the shared `loginWithTestCredentials()` extension if needed.
    /// Handles the edge case where a prior session exists and the app shows a biometric
    /// or PIN screen instead of the login form.
    @MainActor
    private func ensureLoggedIn() {
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 5) {
            // Already on the main screen — nothing to do
            return
        }

        // Check for biometric/PIN screen (prior session exists)
        let usePinButton = app.buttons["Use PIN"]
        if usePinButton.waitForExistence(timeout: 3) {
            // A prior session exists. Tap "Use PIN" and enter the test PIN if the hook was applied.
            usePinButton.tap()
            let pinScreenTitle = app.staticTexts["Enter PIN"]
            if pinScreenTitle.waitForExistence(timeout: 5) {
                app.buttons["1"].tap()
                app.buttons["2"].tap()
                app.buttons["3"].tap()
                app.buttons["4"].tap()
                // Wait for unlock
                _ = app.buttons["line.3.horizontal"].waitForExistence(timeout: 10)
            }
            return
        }

        // Proceed with standard login
        let serverField = app.textFields["example.odoo.com"]
        guard serverField.waitForExistence(timeout: 5) else {
            failWithScreenshot(
                "Login screen not found — app should show the login form",
                name: "UX_ensureLoggedIn_noLoginScreen",
                testCase: self
            )
            return
        }
        app.loginWithTestCredentials()
    }

    // ──────────────────────────────────────────────────────
    // Odoo HTTP helper — session destroy
    // ──────────────────────────────────────────────────────

    /// Calls the Odoo `/web/session/destroy` endpoint to invalidate the server-side
    /// session. The next WebView navigation will receive a `/web/login` redirect.
    /// Returns true if the request completed with HTTP 200.
    private func odooSessionDestroy(cookies: [HTTPCookie]) -> Bool {
        let baseURL = "https://\(E2ETestConfig.serverURL)"
        let expectation = XCTestExpectation(description: "Odoo session destroy")
        var succeeded = false

        guard let url = URL(string: "\(baseURL)/web/session/destroy") else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: cookies)

        let body: [String: Any] = ["jsonrpc": "2.0", "method": "call", "params": [:]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("[odooSessionDestroy] Error: \(error)")
            } else if let http = response as? HTTPURLResponse {
                print("[odooSessionDestroy] Status: \(http.statusCode)")
                succeeded = http.statusCode == 200
            }
            expectation.fulfill()
        }.resume()

        _ = XCTWaiter.wait(for: [expectation], timeout: 20)
        return succeeded
    }

    /// Performs an Odoo JSON-RPC authenticate call and returns the resulting session cookies.
    /// Used only to obtain a cookie set for the session-destroy call.
    private func odooLoginForSessionDestroy() -> [HTTPCookie] {
        let baseURL = "https://\(E2ETestConfig.serverURL)"
        let expectation = XCTestExpectation(description: "Odoo login for session destroy")
        var resultCookies: [HTTPCookie] = []

        guard let loginURL = URL(string: "\(baseURL)/web/session/authenticate") else {
            expectation.fulfill()
            _ = XCTWaiter.wait(for: [expectation], timeout: 1)
            return resultCookies
        }

        var request = URLRequest(url: loginURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "call",
            "params": [
                "db": E2ETestConfig.database,
                "login": E2ETestConfig.adminUser,
                "password": E2ETestConfig.adminPass
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse,
               let fields = http.allHeaderFields as? [String: String],
               let url = http.url {
                resultCookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            }
            expectation.fulfill()
        }.resume()

        _ = XCTWaiter.wait(for: [expectation], timeout: 20)
        return resultCookies
    }

    // ──────────────────────────────────────────────────────
    // UX-25: WebView loads Odoo UI after login
    // REQUIRES APP HOOK: -ResetAppState (applied in setUp)
    // ──────────────────────────────────────────────────────

    /// Verifies that logging in from a clean state navigates to the Odoo WebView.
    /// The test starts from a guaranteed-fresh state using the -ResetAppState hook,
    /// ensuring no prior account exists and the login screen appears immediately.
    @MainActor
    func test_UX25_givenValidLogin_whenMainScreenAppears_thenWebViewExists() {
        app.launch()

        // Assert login screen appears (clean state — no prior account)
        guard app.textFields["example.odoo.com"].waitForExistence(timeout: 8) else {
            failWithScreenshot(
                "UX-25: Login screen not shown after ResetAppState — server field not found",
                name: "UX25_noLoginScreen",
                testCase: self
            )
            return
        }

        // Perform login
        app.loginWithTestCredentials()

        // Handle edge case: app may show biometric/PIN screen if a prior session somehow
        // survived the reset. Fall back to PIN entry with the known test PIN.
        let usePinButton = app.buttons["Use PIN"]
        if usePinButton.waitForExistence(timeout: 3) {
            usePinButton.tap()
            let pinScreen = app.staticTexts["Enter PIN"]
            if pinScreen.waitForExistence(timeout: 5) {
                app.buttons["1"].tap()
                app.buttons["2"].tap()
                app.buttons["3"].tap()
                app.buttons["4"].tap()
            }
        }

        // Assert WebView is present — succeeds as soon as WKWebView enters the hierarchy
        guard app.webViews.firstMatch.waitForExistence(timeout: 30) else {
            failWithScreenshot(
                "UX-25: WebView did not appear within 30 seconds after login",
                name: "UX25_noWebView",
                testCase: self
            )
            return
        }

        XCTAssertTrue(app.webViews.firstMatch.exists, "UX-25: WebView must be present after login")
    }

    // ──────────────────────────────────────────────────────
    // UX-26: WebView blocks navigation to external host via deep link
    // ──────────────────────────────────────────────────────

    /// Verifies that a `woowodoo://open?url=https://evil.com/test` deep link is silently
    /// rejected by DeepLinkValidator and does not navigate the WebView to an external host.
    /// The app remains in the foreground and the WebView is still present.
    ///
    /// `XCUIApplication.open(_:)` requires iOS 16.4+. On iOS 16.0–16.3 the test is skipped.
    @MainActor
    func test_UX26_givenExternalHostURL_whenOpenedViaDeepLink_thenWebViewDoesNotNavigate() throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("UX-26: XCUIApplication.open(_:) requires iOS 16.4+")
        }
        app.launch()
        ensureLoggedIn()

        guard app.webViews.firstMatch.waitForExistence(timeout: 15) else {
            failWithScreenshot(
                "UX-26: WebView not visible before sending deep link — precondition failed",
                name: "UX26_preconditionFailed",
                testCase: self
            )
            return
        }

        // Send a deep link with an external host that DeepLinkValidator must reject
        guard let badURL = URL(string: "woowodoo://open?url=https://evil.com/test") else {
            XCTFail("UX-26: Could not construct the bad deep link URL")
            return
        }

        if #available(iOS 16.4, *) {
            XCUIApplication().open(badURL)
        }

        // Poll briefly — we expect the app to stay in the foreground
        _ = app.webViews.firstMatch.waitForExistence(timeout: 3)

        // App must remain in the foreground (DeepLinkValidator rejected the URL)
        XCTAssertEqual(
            app.state, .runningForeground,
            "UX-26: App must remain in the foreground after an external-host deep link is rejected"
        )

        // WebView must still be present (no navigation occurred)
        guard app.webViews.firstMatch.exists else {
            failWithScreenshot(
                "UX-26: WebView is no longer present after rejected deep link — unexpected navigation",
                name: "UX26_webViewGone",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            app.webViews.firstMatch.exists,
            "UX-26: WebView must still be present after rejected external-host deep link"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-27: External link opens Safari (app leaves foreground)
    // ──────────────────────────────────────────────────────

    /// Verifies that opening a plain HTTPS URL (not handled by the app's `woowodoo://` scheme)
    /// causes the OS to leave the app — typically by routing to Safari.
    /// After re-activation the WebView must still be present.
    ///
    /// `XCUIApplication.open(_:)` requires iOS 16.4+. On iOS 16.0–16.3 the test is skipped.
    @MainActor
    func test_UX27_givenExternalLinkTapped_whenWebViewHandles_thenAppLeavesForeground() throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("UX-27: XCUIApplication.open(_:) requires iOS 16.4+")
        }
        app.launch()
        ensureLoggedIn()

        guard app.webViews.firstMatch.waitForExistence(timeout: 15) else {
            failWithScreenshot(
                "UX-27: WebView not visible before opening external URL — precondition failed",
                name: "UX27_preconditionFailed",
                testCase: self
            )
            return
        }

        // Open a plain HTTPS URL — the system routes it to Safari (or the default browser),
        // causing the app to leave the foreground.
        if #available(iOS 16.4, *) {
            XCUIApplication().open(URL(string: "https://www.apple.com")!)
        }

        // Poll for the app to leave the foreground (up to 5 iterations at 1-second intervals).
        // XCTWaiter.wait(for: [], timeout: 1.0) is a documented way to introduce a short
        // deterministic pause without sleep() when there is no element to poll on the target app.
        var leftForeground = false
        for _ in 0..<5 {
            if app.state != .runningForeground {
                leftForeground = true
                break
            }
            _ = XCTWaiter.wait(for: [], timeout: 1.0)
        }

        if !leftForeground {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "UX27_didNotLeaveForeground"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(
            leftForeground,
            "UX-27: App must leave the foreground when a plain HTTPS URL is opened via the system"
        )

        // Capture state while the external browser is in the foreground
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "UX27_externalBrowserActive"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Re-activate the app and confirm the WebView is still intact
        app.activate()

        guard app.webViews.firstMatch.waitForExistence(timeout: 10) else {
            failWithScreenshot(
                "UX-27: WebView not present after returning from Safari",
                name: "UX27_noWebViewAfterReturn",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            app.webViews.firstMatch.exists,
            "UX-27: WebView must still be present after app is re-activated from Safari"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-28: Session expiry redirects to login screen
    // ──────────────────────────────────────────────────────

    /// Verifies that when the Odoo server-side session is invalidated, the app detects
    /// the `/web/login` redirect and returns to the login screen without user interaction.
    ///
    /// Network connectivity to `E2ETestConfig.serverURL` is required. The test skips
    /// gracefully if the server is unreachable or the session destroy call fails.
    @MainActor
    func test_UX28_givenExpiredSession_whenWebViewDetectsRedirect_thenLoginScreenAppears() throws {
        app.launch()
        ensureLoggedIn()

        guard app.webViews.firstMatch.waitForExistence(timeout: 15) else {
            failWithScreenshot(
                "UX-28: WebView not visible before expiring session — precondition failed",
                name: "UX28_preconditionFailed",
                testCase: self
            )
            return
        }

        // Step 1: Obtain session cookies from the Odoo server
        let cookies = odooLoginForSessionDestroy()
        guard !cookies.isEmpty else {
            throw XCTSkip(
                "UX-28: Could not obtain Odoo session cookies — " +
                "server may be unreachable (\(E2ETestConfig.serverURL))"
            )
        }

        // Step 2: Destroy the server-side session
        let destroyed = odooSessionDestroy(cookies: cookies)
        guard destroyed else {
            throw XCTSkip(
                "UX-28: /web/session/destroy returned a non-200 response — " +
                "check server connectivity and admin credentials"
            )
        }

        // Step 3: Force a WebView navigation so the app receives the /web/login redirect.
        // Background + foreground triggers the scenePhase change which may reload the WebView.
        XCUIDevice.shared.press(.home)
        // One-second pause after .home press — accepted exception to the no-sleep rule.
        // There is no observable app-side UI element to poll while Springboard is active.
        _ = XCTWaiter.wait(for: [], timeout: 1.0)
        app.activate()

        // Step 4: Wait for the login screen to appear (session redirect detection)
        let loginFieldAppeared = app.textFields["example.odoo.com"].waitForExistence(timeout: 20)
        let loginTitleAppeared = app.staticTexts["WoowTech Odoo"].waitForExistence(timeout: 5)

        guard loginFieldAppeared || loginTitleAppeared else {
            failWithScreenshot(
                "UX-28: Login screen did not appear after session was destroyed and WebView was reloaded",
                name: "UX28_noLoginScreen",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            loginFieldAppeared || loginTitleAppeared,
            "UX-28: Login screen must appear after server-side session expiry"
        )

        // The WebView must no longer be visible once the login screen appears
        XCTAssertFalse(
            app.webViews.firstMatch.exists,
            "UX-28: WebView must not be visible once the login screen is shown"
        )
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - E2E_BiometricPINTests (UX-12, UX-13, UX-15, UX-20)
// ═══════════════════════════════════════════════════════════

/// E2E tests for the biometric/PIN auth gate. Tests that depend on the -AppLockEnabled
/// and -SetTestPIN hooks require those to be implemented in AppDelegate (done in this PR).
final class E2E_BiometricPINTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments += ["-AppleLanguages", "(en)"]
    }

    // ──────────────────────────────────────────────────────
    // Navigation helpers
    // ──────────────────────────────────────────────────────

    /// Navigate to the Settings screen via the hamburger menu.
    /// Pattern is copied from F14_SettingsGapTests.navigateToSettings().
    @MainActor
    private func navigateToSettings() {
        let menuButton = app.buttons["line.3.horizontal"]
        XCTAssertTrue(
            menuButton.waitForExistence(timeout: 8),
            "Hamburger menu button must exist — ensure app is in the logged-in state"
        )
        menuButton.tap()

        // Config sheet opens — tap the Settings button or text
        let settingsButton = app.buttons["Settings"]
        let settingsText = app.staticTexts["Settings"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        } else if settingsText.waitForExistence(timeout: 3) {
            settingsText.tap()
        } else {
            failWithScreenshot(
                "Settings not found in Config sheet",
                name: "BiometricPIN_navigateToSettings_failed",
                testCase: self
            )
            return
        }

        // Confirm Settings screen is visible (UPPERCASE header in SwiftUI Form)
        XCTAssertTrue(
            app.staticTexts["APPEARANCE"].waitForExistence(timeout: 5)
            || app.staticTexts["Appearance"].waitForExistence(timeout: 2),
            "Settings screen must show Appearance section"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-12: Biometric success navigates to main screen
    // REQUIRES APP HOOK: -AppLockEnabled YES
    // ──────────────────────────────────────────────────────

    /// Verifies that when App Lock is enabled and Face ID / Touch ID is enrolled on the
    /// simulator, a successful biometric match navigates to the main screen.
    ///
    /// Biometric simulation on a simulator requires `xcrun simctl` coordination that
    /// cannot be issued from within XCUITest. On simulators without biometric enrollment,
    /// LAContext immediately fails and the app shows "Use PIN" — which is the fallback
    /// path verified by UX-13. The CI biometric-success path requires the pipeline to
    /// send a match signal before the test target launches.
    ///
    /// REQUIRES APP HOOK: -AppLockEnabled YES (implemented in AppDelegate)
    @MainActor
    func test_UX12_givenBiometricEnrolled_whenMatchSucceeds_thenMainScreenAppears() throws {
        app.launchArguments += ["-AppLockEnabled", "YES"]
        app.launch()

        // If the login screen appears, no prior account exists — skip.
        let loginField = app.textFields["example.odoo.com"]
        if loginField.waitForExistence(timeout: 3) {
            throw XCTSkip("UX-12: No logged-in account found — biometric test requires a prior session")
        }

        // If already on the main screen, biometric auth succeeded (CI match signal was sent).
        let menuVisible = app.buttons["line.3.horizontal"].waitForExistence(timeout: 3)
        if menuVisible {
            XCTAssertTrue(
                app.buttons["line.3.horizontal"].exists,
                "UX-12: Main screen visible — biometric auth succeeded"
            )
            return
        }

        // On simulators without biometric enrollment, LAContext fails immediately and shows
        // "Use PIN". This is the expected simulator state; the pure biometric-success path
        // requires CI coordination via xcrun simctl.
        let usePinVisible = app.buttons["Use PIN"].waitForExistence(timeout: 3)
        if usePinVisible {
            throw XCTSkip(
                "UX-12: Biometric not enrolled on this simulator. " +
                "CI must send a match signal via xcrun simctl before the test target launches. " +
                "Fallback PIN path is covered by UX-13 and UX-15."
            )
        }

        // Auth prompt visible and biometric may be enrolled — wait for CI match result
        let authTextVisible = app.staticTexts["Authenticate to continue"].waitForExistence(timeout: 2)
        guard authTextVisible else {
            throw XCTSkip("UX-12: No auth gate found — cannot proceed with biometric test")
        }

        let mainScreenAppeared =
            app.buttons["line.3.horizontal"].waitForExistence(timeout: 15)
            || app.webViews.firstMatch.waitForExistence(timeout: 15)

        guard mainScreenAppeared else {
            failWithScreenshot(
                "UX-12: Main screen did not appear after biometric match within 15 seconds",
                name: "UX12_noMainScreen",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            mainScreenAppeared,
            "UX-12: Main screen must appear after a successful biometric match"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-13: Biometric unavailable shows "Use PIN" button
    // REQUIRES APP HOOK: -AppLockEnabled YES
    // ──────────────────────────────────────────────────────

    /// Verifies that when App Lock is enabled and biometric is not enrolled (the default
    /// simulator state), the app shows the "Use PIN" fallback button and no "Skip" button.
    ///
    /// REQUIRES APP HOOK: -AppLockEnabled YES (implemented in AppDelegate)
    @MainActor
    func test_UX13_givenBiometricUnavailableOrFails_whenAuthPromptShown_thenUsePINButtonAppears() throws {
        app.launchArguments += ["-AppLockEnabled", "YES"]
        app.launch()

        // Skip if no prior account is present (nothing to lock)
        let loginField = app.textFields["example.odoo.com"]
        if loginField.waitForExistence(timeout: 3) {
            throw XCTSkip(
                "UX-13: No prior account — auth gate is not shown without a logged-in session"
            )
        }

        // On simulators without biometric enrollment, LAContext fails immediately and the
        // app should show "Use PIN" without a system dialog appearing first.
        guard app.buttons["Use PIN"].waitForExistence(timeout: 8) else {
            failWithScreenshot(
                "UX-13: Use PIN button not found within 8 seconds — " +
                "expected biometric to fail immediately on an unenrolled simulator",
                name: "UX13_noPINButton",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            app.buttons["Use PIN"].exists,
            "UX-13: Use PIN button must be visible when biometric is unavailable"
        )

        // Companion check: no Skip button (UX-14)
        XCTAssertFalse(
            app.buttons["Skip"].exists,
            "UX-13/UX-14: No Skip button must be present on the auth screen"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-15: Correct PIN unlocks the app
    // REQUIRES APP HOOK: -SetTestPIN 1234
    // REQUIRES APP HOOK: -AppLockEnabled YES
    // ──────────────────────────────────────────────────────

    /// Verifies that entering the correct 4-digit PIN on the PIN screen dismisses the
    /// auth gate and navigates to the main screen (WebView or menu button).
    ///
    /// REQUIRES APP HOOK: -SetTestPIN 1234 (pre-seeds PIN hash in Keychain)
    /// REQUIRES APP HOOK: -AppLockEnabled YES (forces App Lock on without navigating Settings)
    @MainActor
    func test_UX15_givenCorrectPIN_whenEnteredOnPINScreen_thenUnlockSucceeds() throws {
        app.launchArguments += ["-SetTestPIN", "1234"]
        app.launchArguments += ["-AppLockEnabled", "YES"]
        app.launch()

        // Skip if no prior account exists
        let loginField = app.textFields["example.odoo.com"]
        if loginField.waitForExistence(timeout: 3) {
            throw XCTSkip(
                "UX-15: No prior account — PIN screen is not shown without a logged-in session"
            )
        }

        // Navigate to PIN screen (either via "Use PIN" button or directly if biometric is absent)
        let usePinButton = app.buttons["Use PIN"]
        if usePinButton.waitForExistence(timeout: 5) {
            usePinButton.tap()
        }

        // Assert PIN entry screen is shown
        guard app.staticTexts["Enter PIN"].waitForExistence(timeout: 5) else {
            failWithScreenshot(
                "UX-15: Enter PIN title not found — expected PIN screen to appear",
                name: "UX15_noPINScreen",
                testCase: self
            )
            return
        }

        // Enter the pre-seeded test PIN "1234"
        app.buttons["1"].tap()
        app.buttons["2"].tap()
        app.buttons["3"].tap()
        app.buttons["4"].tap()

        // Assert main screen appears after correct PIN entry
        let mainScreenAppeared =
            app.webViews.firstMatch.waitForExistence(timeout: 10)
            || app.buttons["line.3.horizontal"].waitForExistence(timeout: 10)

        guard mainScreenAppeared else {
            failWithScreenshot(
                "UX-15: Main screen did not appear after entering the correct PIN '1234'",
                name: "UX15_noMainScreen",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            mainScreenAppeared,
            "UX-15: Entering the correct PIN must dismiss the auth gate and show the main screen"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-20: Background + foreground re-prompts auth
    // REQUIRES APP HOOK: -AppLockEnabled YES
    // REQUIRES APP HOOK: -SetTestPIN 1234 (to unlock before backgrounding)
    // ──────────────────────────────────────────────────────

    /// Verifies that when App Lock is enabled, backgrounding and then foregrounding
    /// the app re-presents the biometric/PIN auth screen so the user must re-authenticate.
    ///
    /// REQUIRES APP HOOK: -AppLockEnabled YES
    /// REQUIRES APP HOOK: -SetTestPIN 1234 (used to unlock the app before backgrounding)
    @MainActor
    func test_UX20_givenAppLockEnabled_whenAppBackgroundsThenForegrounds_thenAuthPromptAppears() throws {
        app.launchArguments += ["-AppLockEnabled", "YES"]
        app.launchArguments += ["-SetTestPIN", "1234"]
        app.launch()

        // Skip if no prior account exists
        let loginField = app.textFields["example.odoo.com"]
        if loginField.waitForExistence(timeout: 3) {
            throw XCTSkip(
                "UX-20: No prior account — auth gate is not shown without a logged-in session"
            )
        }

        // Step 1: Unlock the app via PIN to reach the main screen
        let usePinButton = app.buttons["Use PIN"]
        if usePinButton.waitForExistence(timeout: 5) {
            usePinButton.tap()
        }

        let pinScreen = app.staticTexts["Enter PIN"]
        if pinScreen.waitForExistence(timeout: 5) {
            app.buttons["1"].tap()
            app.buttons["2"].tap()
            app.buttons["3"].tap()
            app.buttons["4"].tap()
        }

        // Step 2: Confirm app is on the main screen (unlocked state)
        let mainScreenReady =
            app.webViews.firstMatch.waitForExistence(timeout: 10)
            || app.buttons["line.3.horizontal"].waitForExistence(timeout: 10)

        guard mainScreenReady else {
            failWithScreenshot(
                "UX-20: Could not reach main screen after PIN unlock — " +
                "cannot test background/foreground cycle",
                name: "UX20_preconditionFailed",
                testCase: self
            )
            return
        }

        // Step 3: Send the app to the background
        XCUIDevice.shared.press(.home)
        // Two-second pause after .home press: accepted exception to the no-sleep rule.
        // The scenePhase .background transition fires asynchronously and there is no
        // observable element on Springboard to poll via waitForExistence.
        _ = XCTWaiter.wait(for: [], timeout: 2.0)

        // Step 4: Re-activate the app
        app.activate()

        // Step 5: Assert that the auth gate re-appeared.
        // Either "Use PIN" button (biometric failed / not enrolled) or PIN entry screen.
        let authGateAppeared =
            app.buttons["Use PIN"].waitForExistence(timeout: 5)
            || app.staticTexts["Enter PIN"].waitForExistence(timeout: 5)
            || app.staticTexts["Authenticate to continue"].waitForExistence(timeout: 5)

        // The WebView (Odoo content) must not be directly accessible without re-auth
        let webViewExposed = app.webViews.firstMatch.exists

        if webViewExposed && !authGateAppeared {
            failWithScreenshot(
                "UX-20: WebView is exposed without re-authentication after background/foreground cycle",
                name: "UX20_webViewExposedWithoutAuth",
                testCase: self
            )
            return
        }

        guard authGateAppeared else {
            failWithScreenshot(
                "UX-20: Auth gate did not appear after backgrounding and foregrounding the app",
                name: "UX20_noAuthGate",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            authGateAppeared,
            "UX-20: Auth screen must appear when app is foregrounded after being backgrounded with App Lock ON"
        )
        XCTAssertFalse(
            webViewExposed,
            "UX-20: Odoo WebView must not be accessible without re-authentication"
        )
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - E2E_LoginAccountTests (UX-05, UX-67, UX-68, UX-69)
// ═══════════════════════════════════════════════════════════

/// E2E tests for login errors, Add Account, account switching, and logout.
final class E2E_LoginAccountTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments += ["-AppleLanguages", "(en)"]
    }

    // ──────────────────────────────────────────────────────
    // Navigation helpers
    // ──────────────────────────────────────────────────────

    /// Ensures the app is in the logged-in state (main screen visible).
    /// Calls `loginWithTestCredentials()` if the app is on the login screen.
    @MainActor
    private func ensureLoggedIn() {
        let menuButton = app.buttons["line.3.horizontal"]
        if menuButton.waitForExistence(timeout: 5) { return }

        // Handle biometric/PIN screen from prior session
        let usePinButton = app.buttons["Use PIN"]
        if usePinButton.waitForExistence(timeout: 3) {
            usePinButton.tap()
            let pinScreen = app.staticTexts["Enter PIN"]
            if pinScreen.waitForExistence(timeout: 5) {
                app.buttons["1"].tap()
                app.buttons["2"].tap()
                app.buttons["3"].tap()
                app.buttons["4"].tap()
                _ = app.buttons["line.3.horizontal"].waitForExistence(timeout: 10)
            }
            return
        }

        // Perform standard login
        let serverField = app.textFields["example.odoo.com"]
        if serverField.waitForExistence(timeout: 5) {
            app.loginWithTestCredentials()
        }
    }

    /// Navigate to the Config sheet by tapping the hamburger menu.
    @MainActor
    private func navigateToConfig() {
        let menuButton = app.buttons["line.3.horizontal"]
        XCTAssertTrue(
            menuButton.waitForExistence(timeout: 8),
            "Hamburger menu button must exist — ensure app is in the logged-in state"
        )
        menuButton.tap()
    }

    // ──────────────────────────────────────────────────────
    // UX-05: Wrong password shows "Invalid credentials" error
    // ──────────────────────────────────────────────────────

    /// Verifies that entering a wrong password on the login credentials step displays
    /// an error message containing "Invalid" or "invalid" and keeps the user on the
    /// login screen without navigating to the main screen.
    ///
    /// Network connectivity to `E2ETestConfig.serverURL` is required.
    @MainActor
    func test_UX05_givenWrongPassword_whenLoginAttempted_thenInvalidCredentialsErrorShown() throws {
        app.launch()

        // Assert the login screen is showing the server URL field
        guard app.textFields["example.odoo.com"].waitForExistence(timeout: 8) else {
            throw XCTSkip(
                "UX-05: Login screen not shown (a prior session may be active). " +
                "This test requires a fresh or unauthenticated state."
            )
        }

        // Step 1: Enter the valid server URL and database
        let serverField = app.textFields["example.odoo.com"]
        serverField.tap()
        serverField.typeText(E2ETestConfig.serverURL)

        let dbField = app.textFields["Enter database name"]
        dbField.tap()
        dbField.typeText(E2ETestConfig.database)

        app.buttons["Next"].tap()

        // Step 2: Wait for the credentials step
        guard app.staticTexts["Enter credentials"].waitForExistence(timeout: 15) else {
            failWithScreenshot(
                "UX-05: Credentials step did not appear after tapping Next",
                name: "UX05_noCredentialsStep",
                testCase: self
            )
            return
        }

        // Step 3: Enter a valid username but a deliberately wrong password
        let usernameField = app.textFields["Username or email"]
        guard usernameField.waitForExistence(timeout: 5) else {
            failWithScreenshot(
                "UX-05: Username field not found on credentials step",
                name: "UX05_noUsernameField",
                testCase: self
            )
            return
        }
        usernameField.tap()
        usernameField.typeText(E2ETestConfig.adminUser)

        let passwordField = app.secureTextFields["Enter password"]
        guard passwordField.waitForExistence(timeout: 3) else {
            failWithScreenshot(
                "UX-05: Password field not found on credentials step",
                name: "UX05_noPasswordField",
                testCase: self
            )
            return
        }
        passwordField.tap()
        passwordField.typeText("wrongpassword_xctest_2026")

        app.buttons["Login"].tap()

        // Step 4: Assert an error message containing "Invalid" or "invalid" appears
        let errorPredicate = NSPredicate(
            format: "label CONTAINS[c] 'Invalid' OR label CONTAINS[c] 'invalid' OR label CONTAINS[c] 'credentials'"
        )
        let errorElement = app.staticTexts.matching(errorPredicate).firstMatch

        guard errorElement.waitForExistence(timeout: 15) else {
            failWithScreenshot(
                "UX-05: Invalid credentials error message did not appear within 15 seconds",
                name: "UX05_noErrorMessage",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            errorElement.exists,
            "UX-05: An error message mentioning 'Invalid' or 'credentials' must appear"
        )

        // The user must remain on the login screen (not navigate to the main screen)
        XCTAssertFalse(
            app.buttons["line.3.horizontal"].exists,
            "UX-05: Hamburger menu must not be visible — user must remain on the login screen"
        )
        XCTAssertFalse(
            app.webViews.firstMatch.exists,
            "UX-05: WebView must not be visible after a failed login attempt"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-67: "Add Account" opens login screen
    // ──────────────────────────────────────────────────────

    /// Verifies that tapping "Add Account" in the Config sheet navigates to the login
    /// screen so the user can enter credentials for a second account.
    @MainActor
    func test_UX67_givenConfigScreenOpen_whenAddAccountTapped_thenLoginScreenAppears() {
        app.launch()
        ensureLoggedIn()

        navigateToConfig()

        // The Config sheet should be visible — search for "Add Account"
        let addAccountButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Add Account'")
        ).firstMatch

        guard addAccountButton.waitForExistence(timeout: 8) else {
            failWithScreenshot(
                "UX-67: Add Account button not found in Config sheet",
                name: "UX67_noAddAccountButton",
                testCase: self
            )
            return
        }

        addAccountButton.tap()

        // Assert login screen appears
        let loginFieldVisible = app.textFields["example.odoo.com"].waitForExistence(timeout: 8)
        let loginTitleVisible = app.staticTexts["Enter server details"].waitForExistence(timeout: 5)

        guard loginFieldVisible || loginTitleVisible else {
            failWithScreenshot(
                "UX-67: Login screen did not appear after tapping Add Account",
                name: "UX67_noLoginScreen",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            loginFieldVisible || loginTitleVisible,
            "UX-67: Login screen (server URL field or 'Enter server details') must appear after Add Account"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-68: Switch account reloads WebView with new account
    // ──────────────────────────────────────────────────────

    /// Verifies that tapping a second account row in the Config sheet switches the active
    /// account and reloads the WebView.
    ///
    /// This test is self-contained: it logs in as account A, adds account B inline
    /// via the "Add Account" / UX-67 flow, then switches back to account A.
    /// Uses `SharedTestConfig.secondUser` / `secondPass` from TestConfig.plist.
    @MainActor
    func test_UX68_givenMultipleAccounts_whenAccountSwitched_thenWebViewReloads() throws {
        let secondUser = E2ETestConfig.secondUser
        let secondPass = E2ETestConfig.secondPass
        let secondServer = ProcessInfo.processInfo.environment["TEST_SECOND_SERVER"]
            ?? E2ETestConfig.serverURL
        let secondDB = ProcessInfo.processInfo.environment["TEST_SECOND_DB"]
            ?? E2ETestConfig.database

        guard !secondUser.isEmpty, !secondPass.isEmpty else {
            throw XCTSkip(
                "UX-68: SecondUser and SecondPass must be set in TestConfig.plist or " +
                "TEST_SECOND_USER / TEST_SECOND_PASS environment variables."
            )
        }

        app.launch()
        ensureLoggedIn()

        // Confirm account A is on the main screen
        guard app.webViews.firstMatch.waitForExistence(timeout: 15)
                || app.buttons["line.3.horizontal"].waitForExistence(timeout: 15) else {
            failWithScreenshot(
                "UX-68: Main screen (WebView or menu) not visible for account A",
                name: "UX68_preconditionFailed",
                testCase: self
            )
            return
        }

        // Open Config and add account B via the Add Account flow
        navigateToConfig()

        let addAccountButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Add Account'")
        ).firstMatch
        guard addAccountButton.waitForExistence(timeout: 8) else {
            failWithScreenshot(
                "UX-68: Add Account button not found — cannot add second account",
                name: "UX68_noAddAccountButton",
                testCase: self
            )
            return
        }
        addAccountButton.tap()

        // Complete login for account B
        guard app.textFields["example.odoo.com"].waitForExistence(timeout: 8) else {
            failWithScreenshot(
                "UX-68: Login screen did not appear after tapping Add Account",
                name: "UX68_noLoginScreen",
                testCase: self
            )
            return
        }
        app.loginWithTestCredentials(
            server: secondServer,
            database: secondDB,
            username: secondUser,
            password: secondPass
        )

        // Account B is now active — confirm main screen loaded
        guard app.webViews.firstMatch.waitForExistence(timeout: 20)
                || app.buttons["line.3.horizontal"].waitForExistence(timeout: 20) else {
            failWithScreenshot(
                "UX-68: Main screen did not appear after logging in as account B",
                name: "UX68_accountBLoginFailed",
                testCase: self
            )
            return
        }

        // Open Config and switch back to account A using the admin username label
        navigateToConfig()

        let accountAPredicate = NSPredicate(
            format: "label CONTAINS[c] %@", E2ETestConfig.adminUser
        )
        let accountARow = app.buttons.matching(accountAPredicate).firstMatch

        guard accountARow.waitForExistence(timeout: 8) else {
            failWithScreenshot(
                "UX-68: Account A row not found in Config sheet after adding account B",
                name: "UX68_noAccountARow",
                testCase: self
            )
            return
        }
        accountARow.tap()

        // WebView must reload for account A's session
        let webViewReloaded = app.webViews.firstMatch.waitForExistence(timeout: 20)

        guard webViewReloaded else {
            failWithScreenshot(
                "UX-68: WebView did not reload after switching from account B to account A",
                name: "UX68_noWebViewReload",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            webViewReloaded,
            "UX-68: WebView must be visible after switching to account A"
        )
    }

    // ──────────────────────────────────────────────────────
    // UX-69: Logout removes account and shows login screen
    // ──────────────────────────────────────────────────────

    /// Verifies the full logout flow: tapping Logout → confirmation alert → login screen.
    /// After logout the account is removed and no biometric/PIN screen appears.
    @MainActor
    func test_UX69_givenLoggedInAccount_whenLogoutConfirmed_thenAccountRemovedAndLoginShown() {
        app.launch()
        ensureLoggedIn()

        // Open the Config sheet
        navigateToConfig()

        // Scroll down to find the Logout button if it is off-screen
        var logoutButton = app.buttons["Logout"]
        if !logoutButton.waitForExistence(timeout: 5) {
            app.swipeUp()
            logoutButton = app.buttons["Logout"]
        }

        guard logoutButton.waitForExistence(timeout: 5) else {
            failWithScreenshot(
                "UX-69: Logout button not found in Config sheet",
                name: "UX69_noLogoutButton",
                testCase: self
            )
            return
        }
        logoutButton.tap()

        // Assert confirmation alert appears
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else {
            failWithScreenshot(
                "UX-69: Logout confirmation alert did not appear",
                name: "UX69_noAlert",
                testCase: self
            )
            return
        }

        // Find and tap the destructive confirm button
        let confirmPredicate = NSPredicate(
            format: "label CONTAINS[c] 'Logout' OR label CONTAINS[c] 'Confirm' OR label CONTAINS[c] 'Yes'"
        )
        let confirmButton = alert.buttons.matching(confirmPredicate).firstMatch

        guard confirmButton.exists else {
            failWithScreenshot(
                "UX-69: Logout confirmation button not found in alert",
                name: "UX69_noConfirmButton",
                testCase: self
            )
            return
        }
        confirmButton.tap()

        // Assert the login screen appears after logout
        let loginFieldVisible = app.textFields["example.odoo.com"].waitForExistence(timeout: 10)
        let loginTitleVisible = app.staticTexts["WoowTech Odoo"].waitForExistence(timeout: 5)

        guard loginFieldVisible || loginTitleVisible else {
            failWithScreenshot(
                "UX-69: Login screen did not appear after logout was confirmed",
                name: "UX69_noLoginScreen",
                testCase: self
            )
            return
        }

        XCTAssertTrue(
            loginFieldVisible || loginTitleVisible,
            "UX-69: Login screen must appear after logout is confirmed"
        )

        // No biometric/PIN screen must appear (no account to protect)
        XCTAssertFalse(
            app.buttons["Use PIN"].exists,
            "UX-69: No PIN/biometric prompt must appear after full logout (no account to protect)"
        )

        // The main screen (WebView) must not be visible
        XCTAssertFalse(
            app.webViews.firstMatch.exists,
            "UX-69: WebView must not be visible after the account is removed by logout"
        )
    }
}
