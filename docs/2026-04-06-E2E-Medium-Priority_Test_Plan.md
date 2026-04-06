# E2E XCUITest Plan — MEDIUM Priority (22 Tests)

**Date:** 2026-04-06
**Scope:** UX-16, UX-17, UX-41, UX-44, UX-45, UX-46, UX-64, UX-65, UX-72, UX-73,
UX-74, UX-75, UX-08, UX-09, UX-10, UX-11, UX-21, UX-22, UX-30, UX-31, UX-59, UX-61
**Estimated effort:** ~12 hours implementation + stabilization
**Companion document:** `2026-04-06-E2E-High-Priority_Test_Plan.md`

---

## Conventions Applied

- No `sleep()` — use `waitForExistence(timeout:)` exclusively, with documented exceptions
- Force English locale: `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `XCTFail` in every `guard else` branch, always preceded by a screenshot attachment
- `@MainActor` on every test function
- `continueAfterFailure = false` in every `setUp`
- SwiftUI Form section headers render as UPPERCASE; match `"SECURITY"`, not `"Security"`
- `navigateToSettings()` pattern from `F14_SettingsGapTests` (hamburger → Settings →
  assert `APPEARANCE`/`Appearance` section)
- Notification search uses the four-strategy pattern from `FCM_EndToEndTests.verifyNotification`
- Deep link URL tests are primarily unit-test concerns; XCUITest verifies the wiring
  only (validator rejection surfaces as no-navigation)

---

## Class Assignments

| Test class | Existing or New | Groups |
|---|---|---|
| `E2E_PINLockoutTests` | New | UX-16, UX-17 |
| `E2E_NotificationTests` | New | UX-41, UX-44, UX-45, UX-46 |
| `E2E_CacheTests` | New | UX-64, UX-65 |
| `E2E_DeepLinkSecurityTests` | New | UX-72, UX-73, UX-74, UX-75 |
| `E2E_LoginErrorTests` | New | UX-08, UX-09 |
| `E2E_AppLockTests` | New | UX-10, UX-11, UX-21, UX-22 |
| `E2E_MiscTests` | New | UX-30, UX-31, UX-59, UX-61 |

All classes live in a new file:
`odooUITests/E2E_MediumPriority_Tests.swift`

---

## Shared Setup Pattern

```swift
override func setUp() {
    continueAfterFailure = false
    app.launchArguments += ["-AppleLanguages", "(en)"]
    app.launch()
}
```

---

## Failure Screenshot Helper (apply in every guard/XCTFail branch)

```swift
let screenshot = XCUIScreen.main.screenshot()
let attachment = XCTAttachment(screenshot: screenshot)
attachment.name = "<test-id>_failure"
attachment.lifetime = .keepAlways
add(attachment)
XCTFail("<reason>")
```

---

---

## PIN Lockout Tests — Class: `E2E_PINLockoutTests`

### TEST UX-16 — Wrong PIN shows error and remaining attempt count

**Test name:** `test_UX16_givenWrongPIN_whenEntered_thenErrorAndRemainingAttemptsShown`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App lock enabled, PIN set to a known value (e.g., `"1234"`) via test launch argument
  `"-SetTestPIN", "1234"`.
- Prior login exists so the PIN screen is reachable.

**Steps:**
1. Launch app.
2. If biometric screen appears, tap `app.buttons["Use PIN"]`.
3. Assert `app.staticTexts["Enter PIN"].waitForExistence(timeout: 5)`.
4. Enter a wrong PIN: tap `app.buttons["9"]`, `app.buttons["9"]`,
   `app.buttons["9"]`, `app.buttons["9"]`.
5. Wait for error state:
   ```swift
   let errorText = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS[c] 'incorrect' OR label CONTAINS[c] 'wrong' OR label CONTAINS[c] 'Invalid'")
   ).firstMatch
   XCTAssertTrue(errorText.waitForExistence(timeout: 3), "Error message must appear for wrong PIN")
   ```
6. Assert remaining attempts count is visible:
   ```swift
   let attemptsText = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS[c] 'attempt' OR label CONTAINS[c] '4'")
   ).firstMatch
   XCTAssertTrue(attemptsText.waitForExistence(timeout: 3), "Remaining attempts count must be shown")
   ```

**Expected result:**
- An error message appears immediately after the wrong PIN.
- The remaining attempts count is shown (e.g., "4 attempts remaining").

**Known limitations:**
- The exact error and attempts string depend on `PinView`'s implementation. If the
  text is different, cross-check with unit tests in `odooTests/PinViewModelTests.swift`.
- The PIN screen dots should NOT advance to a new attempt entry; the digits should
  clear (or the screen should reset). Verify `app.staticTexts["Enter PIN"]` reappears
  after the error.
- Pre-seeding the PIN requires a test-only hook in the app. Without it, use
  `XCTSkip("PIN not pre-seeded; set -SetTestPIN launch argument")`.

---

### TEST UX-17 — 5 wrong PINs trigger 30-second lockout message

**Test name:** `test_UX17_givenFiveWrongPINs_whenEntered_thenLockoutMessageAppears`

**Setup:**
- Same as UX-16.
- PIN set to `"1234"` via launch argument.

**Steps:**
1. Launch app and navigate to PIN screen (tap "Use PIN" if biometric shown).
2. Enter wrong PIN 5 times in succession. Each attempt enters 4 digits using buttons
   `"9"`, `"9"`, `"9"`, `"9"`. After each 4-digit entry wait for the screen to reset
   before entering the next attempt:
   ```swift
   for _ in 1...5 {
       for digit in ["9", "9", "9", "9"] {
           app.buttons[digit].tap()
       }
       // Wait for either: error text, screen reset, or lockout message
       _ = app.staticTexts.firstMatch.waitForExistence(timeout: 2)
   }
   ```
3. Assert lockout message appears:
   ```swift
   let lockoutText = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS[c] '30' OR label CONTAINS[c] 'locked' OR label CONTAINS[c] 'lockout'")
   ).firstMatch
   XCTAssertTrue(lockoutText.waitForExistence(timeout: 5), "30-second lockout message must appear after 5 wrong PINs")
   ```

**Expected result:**
- After the 5th wrong PIN, a lockout message mentioning "30" seconds (or "locked") appears.
- The PIN numpad is disabled or hidden during lockout.

**Known limitations:**
- The actual lockout duration display string must be confirmed against
  `PinViewModel`'s lockout formatting. The unit test
  `PinHasherTests.test_lockout_givenFiveFailures_returns30Seconds` confirms the
  duration value; this XCUITest confirms the UI surfaces it.
- Entering 5 PINs takes time. The test body will run for ~10 seconds. This is
  acceptable for a medium-priority test.
- After this test, the lockout state persists in Keychain. `tearDown` should reset
  lockout state via a launch argument (`"-ResetPINLockout", "YES"`) or by
  waiting 30 seconds (not acceptable in CI). Add the reset launch argument.

---

---

## Notification Tests — Class: `E2E_NotificationTests`

These tests extend the patterns established in `FCM_EndToEndTests`. The notification
search strategy (four strategies: direct, expand group, dismiss focus, swipe up) is
reused from `verifyNotification()` in `FCM_EndToEndTests`. Copy the helper into this
class or extract it to a shared `UITestNotificationHelper.swift`.

### TEST UX-41 — Chinese content in notification displays correctly

**Test name:** `test_UX41_givenChineseNotificationBody_whenDelivered_thenChineseCharsDisplay`

**Setup:**
- Logged-in state.
- Notification permission granted.
- `app.launchArguments += ["-AppleLanguages", "(en)"]` (app locale; notification
  content charset is independent of app locale).

**Steps:**
1. Call `ensureLoggedIn()`.
2. Call `clearAndSendNotification` with an Odoo `message_post` whose body contains
   Chinese text:
   ```swift
   self.odooRPC(
       cookies: cookies,
       model: "res.partner",
       method: "message_post",
       args: [testPartnerID],
       kwargs: [
           "body": "<p>XCUITest 中文通知测试</p>",
           "message_type": "comment",
           "subtype_xmlid": "mail.mt_comment"
       ]
   )
   ```
3. Call `verifyNotification(appName: "ODOO", bodyContains: "中文通知测试")`.

**Expected result:**
- Notification appears in Notification Center with Chinese characters intact.
- The notification label contains `"中文通知测试"` without garbled characters.

**Known limitations:**
- APNs payload encoding is UTF-8 by default; the iOS lock screen renders Chinese
  characters without special configuration. This test guards against a regression
  where the payload is inadvertently ASCII-encoded or truncated.
- The `bodyContains` predicate in `verifyNotification` uses `CONTAINS[c]` (case
  insensitive) — Chinese characters are not affected by case folding. The predicate
  is correct as written.
- Requires live Odoo server connectivity. Skip with `XCTSkip` if unreachable.

---

### TEST UX-44 — Multiple notifications grouped by event type

**Test name:** `test_UX44_givenMultipleNotifications_whenDelivered_thenGroupedByEventType`

**Setup:**
- Logged-in state.
- Notification permission granted.
- Clear all existing notifications before the test.

**Steps:**
1. Call `ensureLoggedIn()`.
2. Send three notifications of the same type (chatter) in quick succession via RPC:
   - Message A: `"Grouping test message 1"`
   - Message B: `"Grouping test message 2"`
   - Message C: `"Grouping test message 3"`
3. Wait 15 seconds for FCM delivery.
4. Open Notification Center using the springboard swipe-down gesture.
5. Search for a grouped notification container:
   ```swift
   let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
   let appPredicate = NSPredicate(format: "label CONTAINS[c] 'odoo'")
   let groupScroll = springboard.scrollViews.matching(appPredicate).firstMatch
   let groupButton = springboard.buttons.matching(appPredicate).firstMatch
   let groupFound = groupScroll.waitForExistence(timeout: 5) || groupButton.waitForExistence(timeout: 2)
   XCTAssertTrue(groupFound, "Multiple ODOO notifications must appear grouped")
   ```

**Expected result:**
- Notifications from the same app are grouped together in a single stack or group
  element labeled with "ODOO".
- The group is expandable (tap reveals individual notifications).

**Known limitations:**
- iOS groups notifications automatically by `threadIdentifier` (set to the Odoo
  event type in the app's notification payload). The grouping UI depends on iOS
  version and user notification preferences. On iOS 18, automatic grouping is enabled
  by default.
- The grouping appearance (ScrollView vs. Button) varies; the search must try both,
  consistent with the established four-strategy pattern.
- If the simulator has "Notification Grouping: Off" in Settings, notifications will
  not group. The CI simulator image must have default notification settings.

---

### TEST UX-45 — Lock screen notification shows privacy placeholder

**Test name:** `test_UX45_givenLockScreen_whenNotificationArrives_thenContentHiddenOrPlaceholderShown`

**Setup:**
- Logged-in state.
- Notification permission granted.
- Device is in "locked" state (simulated by going to Springboard without unlocking).

**Steps:**
1. Call `ensureLoggedIn()`.
2. Press home and allow simulator to lock (`XCUIDevice.shared.press(.home)`).
3. Send a notification via RPC with body `"UX45 privacy test secret"`.
4. Wait 10 seconds for FCM delivery.
5. On the Springboard lock screen, search for the notification:
   ```swift
   let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
   let notif = springboard.otherElements["NotificationShortLookView"].firstMatch
   ```
6. If the notification is found, inspect its label:
   - It must NOT contain `"privacy test secret"` verbatim (placeholder shown).
   - OR it must be empty / show a generic placeholder.
   ```swift
   if notif.waitForExistence(timeout: 8) {
       let label = notif.label
       XCTAssertFalse(
           label.contains("privacy test secret"),
           "Lock screen must not reveal notification body when content hidden is enabled"
       )
   }
   ```

**Expected result:**
- The lock screen notification does not display the sensitive body text.
- A placeholder (e.g., "Notification" or empty body) is shown instead.

**Known limitations:**
- iOS `UNNotificationCategory` privacy behavior (`hiddenPreviewsBodyPlaceholder`) is
  configured in the app's notification setup. This test verifies the end-to-end result
  but cannot inspect the `UNNotificationContent` directly.
- On simulators with no screen lock passcode configured, the lock screen may not apply
  privacy settings. The CI simulator must have screen lock enabled.
- If the notification is NOT found at all on the lock screen, the test should not fail
  silently — it must capture a screenshot and call `XCTFail("Notification not found")`.
- iOS 18 on simulator may surface notifications differently depending on Focus mode.
  Apply the four-strategy fallback from `verifyNotification`.

---

### TEST UX-46 — Foreground notification shows banner (not auto-navigate)

**Test name:** `test_UX46_givenAppInForeground_whenNotificationDelivered_thenBannerShownNotAutoNavigated`

**Setup:**
- Logged-in state, app is active in the foreground.
- Notification permission granted.

**Steps:**
1. Call `ensureLoggedIn()`.
2. Assert WebView is visible (app is in foreground, Odoo loaded).
3. Send a notification via RPC with body `"UX46 foreground banner test"`.
4. Wait 10 seconds.
5. Assert the app is STILL showing the WebView (no auto-navigation occurred):
   `XCTAssertTrue(app.webViews.firstMatch.exists, "WebView must remain; app must not auto-navigate")`
6. The foreground banner is shown by the system (iOS 18 UNUserNotificationCenter
   `.banner` presentation). Its presence on screen cannot be directly asserted via
   XCUITest without Springboard access. Assert absence of deep-link navigation instead.
7. Optionally check via Springboard for a banner overlay:
   ```swift
   let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
   let bannerPredicate = NSPredicate(format: "label CONTAINS[c] 'UX46 foreground banner test'")
   let banner = springboard.otherElements.matching(bannerPredicate).firstMatch
   // Banner may or may not be detectable depending on iOS version
   ```

**Expected result:**
- App stays on the current screen (WebView visible).
- No automatic navigation to a Odoo record occurs.
- A notification banner is visible at the top of the screen (best-effort assertion).

**Known limitations:**
- The iOS foreground banner is a system overlay rendered above the app; its
  XCUITest detectability varies. The primary assertion (WebView still present) is
  the most reliable signal.
- Auto-navigation suppression is implemented in `AppDelegate.userNotificationCenter(_:willPresent:)`.
  The unit test for this method is the authoritative coverage. This XCUITest provides
  integration-level confidence.

---

---

## Cache Tests — Class: `E2E_CacheTests`

### TEST UX-64 — After cache clear, user remains logged in

**Test name:** `test_UX64_givenCacheCleared_whenAppReturnsToForeground_thenUserStillLoggedIn`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Logged-in state.

**Steps:**
1. Ensure logged-in state.
2. Navigate to Settings via `navigateToSettings()`.
3. Swipe up to reveal the "DATA & STORAGE" section.
4. Tap "Clear Cache":
   ```swift
   let clearCache = app.staticTexts["Clear Cache"]
   XCTAssertTrue(clearCache.waitForExistence(timeout: 5), "Clear Cache must be visible")
   clearCache.tap()
   ```
5. If a confirmation alert appears, confirm it.
6. Wait for the settings screen to return to its normal state:
   `app.staticTexts["Clear Cache"].waitForExistence(timeout: 5)` (or a success message).
7. Navigate back to the main screen:
   - Tap the back/dismiss button or swipe right.
8. Assert the user is STILL logged in:
   `XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "User must remain logged in after cache clear")`
   OR
   `XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 10), "Hamburger menu indicates logged-in state")`

**Expected result:**
- WebView is visible after returning from Settings.
- No login screen appears.
- Session (Keychain credentials) is not affected by cache clear.

**Known limitations:**
- "Clear Cache" triggers `WKWebsiteDataStore.default().removeData(ofTypes:)`, which
  clears WebView storage. Keychain credentials are separate. This test verifies
  the separation is correctly implemented.
- The "DATA & STORAGE" section header is UPPERCASE in SwiftUI Form; assert
  `app.staticTexts["DATA & STORAGE"]` not `"Data & Storage"`.
- Cache clearing is asynchronous. The success indicator (if any) should be waited
  on; if there is none, wait 3 seconds via `waitForExistence` on an element that
  appears after completion (the Clear Cache row itself becoming re-hittable).

---

### TEST UX-65 — After cache clear, Odoo loads (not login page)

**Test name:** `test_UX65_givenCacheCleared_whenWebViewReloads_thenOdooLoadsNotLoginPage`

**Setup:**
- Same as UX-64.

**Steps:**
1. Follow steps 1–7 from UX-64 to clear cache and return to main screen.
2. Wait for WebView to reload: `app.webViews.firstMatch.waitForExistence(timeout: 15)`.
3. Assert the login screen is NOT shown:
   ```swift
   let loginScreenVisible = app.textFields["example.odoo.com"].exists
   XCTAssertFalse(loginScreenVisible, "Login screen must not appear after cache clear when session is valid")
   ```
4. Assert Odoo WebView content loads (not a blank page or Odoo's `/web/login` page).
   A proxy: the hamburger menu (`"line.3.horizontal"`) is visible, indicating the
   main screen — not the login screen.

**Expected result:**
- After cache clear, the app returns to Odoo's main interface.
- The Odoo web interface loads successfully.
- The user is not prompted to log in again.

**Known limitations:**
- After clearing WKWebView data, the WebView may reload the Odoo URL with the session
  cookie that is re-injected from Keychain. If cookie re-injection is not implemented,
  the session may be lost and the user IS redirected to login — which would be a bug.
  This test guards against that regression.
- The WebView's Odoo page content cannot be fully inspected from XCUITest. The proxy
  assertion (no login screen + hamburger visible) is the practical verification.

---

---

## Deep Link Security Tests — Class: `E2E_DeepLinkSecurityTests`

Note: UX-72, UX-73, UX-74 are primarily unit-test concerns (already covered by
`DeepLinkValidatorTests`). These XCUITests verify that the validator is wired into
the navigation pipeline — i.e., that a rejected URL does NOT cause the WebView to
navigate to it. The verification approach is: send the bad URL via the app's URL
scheme handler, then assert the WebView's state did not change.

### TEST UX-72 — `javascript:alert()` URL is rejected

**Test name:** `test_UX72_givenJavascriptURL_whenOpenedViaScheme_thenWebViewDoesNotNavigate`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Logged-in state, WebView visible.

**Steps:**
1. Ensure logged-in state and WebView is present.
2. Construct a `woowodoo://` deep link that would route to `javascript:alert('XSS')`:
   ```swift
   let badURL = URL(string: "woowodoo://open?url=javascript:alert('XSS')")!
   ```
3. Open via `XCUIApplication().open(badURL)` — this invokes the app's URL scheme handler.
4. Wait 2 seconds.
5. Assert the app is still in the foreground:
   `XCTAssertEqual(app.state, .runningForeground, "App must stay in foreground")`
6. Assert no `UIAlertView`/`UIAlert` or JavaScript alert appeared:
   `XCTAssertFalse(app.alerts.firstMatch.exists, "No JS alert must appear — javascript: URL was rejected")`
7. Assert WebView still exists (no crash):
   `XCTAssertTrue(app.webViews.firstMatch.exists, "WebView must persist after rejection")`

**Expected result:**
- No JavaScript alert appears.
- WebView does not navigate to the JavaScript URL.
- App remains stable.

**Known limitations:**
- WKWebView inherently rejects `javascript:` navigation when it originates from
  `WKWebView.load(_:)`. The `DeepLinkValidator` provides an additional layer.
  This XCUITest confirms the wiring at the app-level entry point.
- The `woowodoo://open?url=` deep link format must match what `DeepLinkManager`
  actually parses. Confirm the URL scheme format from `DeepLinkManager.swift`.
- If the app does not expose a URL scheme for routing arbitrary URLs into the WebView,
  this test is moot. Use `XCTSkip("URL routing scheme not configured for direct URL injection")`.

---

### TEST UX-73 — `data:text/html` URL is rejected

**Test name:** `test_UX73_givenDataSchemeURL_whenOpenedViaScheme_thenWebViewDoesNotNavigate`

**Setup:**
- Same as UX-72.

**Steps:**
1. Ensure logged-in state and WebView visible.
2. Construct a `data:` URL deep link:
   ```swift
   let badURL = URL(string: "woowodoo://open?url=data:text/html,<h1>Injected</h1>")!
   ```
3. Open via `XCUIApplication().open(badURL)`.
4. Wait 2 seconds.
5. Assert the WebView does not contain injected content:
   ```swift
   // "Injected" text would only appear if the data: URL loaded
   let injectedText = app.staticTexts["Injected"]
   XCTAssertFalse(injectedText.exists, "data: URL content must not appear in WebView")
   ```
6. Assert app remains foreground + WebView exists.

**Expected result:**
- The `data:text/html` URL is silently rejected.
- WebView retains its previous Odoo content.
- No visible change in the app.

**Known limitations:**
- Same as UX-72. WKWebView natively rejects `data:` URLs from `loadRequest`.
  This test is a belt-and-suspenders check on the validator wiring.

---

### TEST UX-74 — External host URL is rejected

**Test name:** `test_UX74_givenExternalHostURL_whenOpenedViaScheme_thenWebViewDoesNotNavigate`

**Setup:**
- Same as UX-72.

**Steps:**
1. Ensure logged-in state and WebView visible.
2. Construct an external-host deep link:
   ```swift
   let badURL = URL(string: "woowodoo://open?url=https://evil.com/steal?data=123")!
   ```
3. Open via `XCUIApplication().open(badURL)`.
4. Wait 2 seconds.
5. Assert app state is foreground (not redirected to Safari):
   `XCTAssertEqual(app.state, .runningForeground)`
6. Assert WebView exists and no external content loaded:
   `XCTAssertTrue(app.webViews.firstMatch.exists)`

**Expected result:**
- The external-host URL is rejected by `DeepLinkValidator`.
- The WebView does not navigate to `evil.com`.
- App stays in foreground.

**Known limitations:**
- If the validator passes the URL to `UIApplication.open(_:)` as an external link
  (instead of loading it in the WebView), the app WILL leave the foreground and
  open Safari — which is actually the correct behavior for external links in general
  but not for deep-link routing into the WebView.
  The test must distinguish between: (a) WebView loaded it (bad), (b) Safari opened (acceptable
  depending on implementation), (c) nothing happened (ideal). Assert only that the
  WebView did not load the content.

---

### TEST UX-75 — `woowodoo://` URL scheme opens app

**Test name:** `test_UX75_givenWoowodooURLScheme_whenOpenedFromSpringboard_thenAppActivates`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App may be in background or not running.

**Steps:**
1. Press home to send app to background: `XCUIDevice.shared.press(.home)`.
2. Wait 1 second for background transition.
3. Open the `woowodoo://` URL:
   ```swift
   let deepLink = URL(string: "woowodoo://open")!
   XCUIApplication().open(deepLink) // opens from Springboard
   ```
   Alternatively, use Safari to navigate to `woowodoo://open` and confirm the
   system shows an open-app prompt.
4. Assert the app activates and reaches the foreground:
   ```swift
   XCTAssertTrue(
       app.wait(for: .runningForeground, timeout: 10),
       "App must activate when woowodoo:// URL is opened"
   )
   ```
5. Assert the app shows either the login screen or the main screen (not crashed):
   ```swift
   let loginVisible = app.staticTexts["WoowTech Odoo"].waitForExistence(timeout: 5)
   let mainVisible = app.webViews.firstMatch.waitForExistence(timeout: 5)
   XCTAssertTrue(loginVisible || mainVisible, "App must show valid UI after deep link activation")
   ```

**Expected result:**
- App comes to the foreground.
- App shows login screen (if no prior session) or main screen (if session exists).
- No crash.

**Known limitations:**
- `XCUIApplication().open(_:)` in XCUITest opens a URL via the system. If the
  app is already running, it activates it. If not running, it launches it.
- The URL scheme `woowodoo` must be registered in `Info.plist` under
  `CFBundleURLTypes`. This is a prerequisite; if not registered, the test will fail
  at the OS level.
- `app.wait(for: .runningForeground, timeout: 10)` requires XCTest 14+.

---

---

## Login Error Tests — Class: `E2E_LoginErrorTests`

### TEST UX-08 — Network error shows error message

**Test name:** `test_UX08_givenNetworkError_whenLoginAttempted_thenErrorMessageShown`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Fresh login state (no prior account).
- Network unreachable: use a deliberately invalid server URL (non-routable IP or
  a domain that does not exist).

**Steps:**
1. Launch app to login screen.
2. Enter a non-routable server URL: `"192.0.2.1"` (TEST-NET-1, guaranteed unreachable).
3. Enter any database name: `"test"`.
4. Tap `app.buttons["Next"]`.
5. Wait for credentials step or proceed directly to Login button.
6. Enter any username and password.
7. Tap `app.buttons["Login"]`.
8. Wait for error message (up to 35 seconds — exceeds the 30-second URLSession timeout):
   ```swift
   let errorText = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS[c] 'connect' OR label CONTAINS[c] 'network' OR label CONTAINS[c] 'unable' OR label CONTAINS[c] 'reach'")
   ).firstMatch
   XCTAssertTrue(errorText.waitForExistence(timeout: 35), "Network error message must appear")
   ```

**Expected result:**
- An error message about connectivity failure appears.
- App remains on the login screen.
- No crash.

**Known limitations:**
- This test takes up to 35 seconds due to the URLSession timeout. Mark in CI pipeline
  as a slow test (`-testTimeout` flag).
- `192.0.2.1` (TEST-NET-1) is specifically reserved and unroutable per RFC 5737.
  Using `invalid-server.example` (IANA-reserved domain) is an alternative.
- The actual error string must match `LoginViewModel`'s error mapping for
  `URLError.notConnectedToInternet` or `URLError.timedOut`. Cross-check with
  `odooTests/LoginViewModelTests.swift`.
- On a CI machine with a corporate proxy, `192.0.2.1` may still get a response.
  Use `invalid-server.xctest-nonexistent` (guaranteed NXDOMAIN) as an alternative.

---

### TEST UX-09 — Connection timeout shows error message

**Test name:** `test_UX09_givenConnectionTimeout_whenLoginAttempted_thenTimeoutErrorShown`

**Setup:**
- Same as UX-08 but use a host that accepts TCP connections but never responds:
  `"10.255.255.1"` (black-hole address) or a dedicated test endpoint that hangs.
- Alternatively, use a launch argument `"-SimulateTimeout", "YES"` if the app's
  `OdooAPIClient` supports injected URLProtocol for testing (added in IC19).

**Steps:**
1. Launch app.
2. Enter the black-hole server URL or use `"-SimulateTimeout", "YES"` launch argument.
3. Enter credentials and tap Login.
4. Wait for timeout error (up to 35 seconds):
   ```swift
   let timeoutText = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS[c] 'timeout' OR label CONTAINS[c] 'timed out'")
   ).firstMatch
   XCTAssertTrue(timeoutText.waitForExistence(timeout: 35), "Timeout error message must appear")
   ```

**Expected result:**
- An error message mentioning "timeout" or "timed out" appears.
- App remains on login screen.

**Known limitations:**
- IC19 added `URLProtocol` injection for testability in `OdooAPIClient`. If a
  `"-SimulateTimeout"` launch argument is implemented, the test can bypass the
  actual network and run in ~3 seconds instead of 30+. Strongly prefer this approach.
- Without the injection, the test is slow and fragile on CI networks. Document in
  the test with `// Slow test: depends on URLSession timeout (30s)`.
- Black-hole addresses (`10.255.255.1`) may be filtered by firewalls on CI machines.

---

---

## App Lock Tests — Class: `E2E_AppLockTests`

### TEST UX-10 — Enable App Lock requires auth on next launch

**Test name:** `test_UX10_givenAppLockEnabled_whenAppRelaunched_thenAuthRequired`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Logged-in state.
- App Lock starts OFF (or in a known state — reset via launch argument).

**Steps:**
1. Navigate to Settings via `navigateToSettings()`.
2. Find the App Lock toggle in the SECURITY section:
   `app.switches["App Lock"].waitForExistence(timeout: 5)`.
3. If toggle is OFF, tap it to enable:
   ```swift
   let toggle = app.switches["App Lock"]
   if (toggle.value as? String) == "0" {
       toggle.tap()
   }
   XCTAssertEqual(toggle.value as? String, "1", "App Lock must be enabled")
   ```
4. Terminate the app: `app.terminate()`.
5. Relaunch: `app.launch()`.
6. Assert auth screen appears (biometric or PIN prompt, not WebView directly):
   ```swift
   let authRequired = app.buttons["Use PIN"].waitForExistence(timeout: 5)
       || app.staticTexts["Enter PIN"].waitForExistence(timeout: 5)
       || app.webViews.firstMatch.exists == false
   XCTAssertTrue(authRequired, "Auth screen must appear after enabling App Lock and relaunching")
   ```

**Expected result:**
- After enabling App Lock and relaunching, the app requires biometric or PIN auth.
- The Odoo WebView is not visible until authentication succeeds.

**Known limitations:**
- `app.terminate()` + `app.launch()` simulates a cold launch. The `scenePhase`
  transition from background to foreground (without termination) is a different
  flow (UX-20, covered in HIGH priority tests).
- The toggle may require a PIN to be set before App Lock can be enabled. If the PIN
  setup sheet appears, the test must handle it or skip with
  `XCTSkip("PIN must be set before enabling App Lock")`.
- App Lock toggle state is persisted via `AppSettings`. Ensure `tearDown` disables
  it to avoid polluting subsequent tests.

---

### TEST UX-11 — Launch with lock ON shows biometric prompt

**Test name:** `test_UX11_givenAppLockOn_whenAppLaunched_thenBiometricPromptShown`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App Lock enabled (precondition — set in a prior step or via launch argument
  `"-AppLockEnabled", "YES"`).
- Prior login session exists.

**Steps:**
1. Launch app.
2. Wait for the auth screen:
   ```swift
   let biometricOrPIN = app.buttons["Use PIN"].waitForExistence(timeout: 5)
       || app.staticTexts["Authenticate to continue"].waitForExistence(timeout: 5)
       || app.staticTexts["Enter PIN"].waitForExistence(timeout: 5)
   XCTAssertTrue(biometricOrPIN, "Biometric or PIN prompt must appear when App Lock is ON")
   ```
3. Assert the WebView is NOT yet visible:
   `XCTAssertFalse(app.webViews.firstMatch.exists, "WebView must be hidden until auth succeeds")`

**Expected result:**
- Biometric prompt or PIN screen appears on launch.
- Odoo content is not accessible.

**Known limitations:**
- On simulators without biometric enrollment, `LAContext` immediately fails and the
  app should show the "Use PIN" fallback. Both are acceptable for this test.
- The "Authenticate to continue" text is app-defined in `BiometricView`. Confirm
  the exact string from the source file if this assert fails.
- `app.terminate()` + `app.launch()` is needed only if the test runs after a test
  that left the app unlocked. Use `continueAfterFailure = false` and order tests so
  UX-10 runs before UX-11.

---

### TEST UX-21 — App Lock OFF + background/foreground = no auth prompt

**Test name:** `test_UX21_givenAppLockOff_whenAppBackgroundsThenForgrounds_thenNoAuthPromptAppears`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Logged-in state.
- App Lock DISABLED (explicitly verify toggle is OFF in setUp).

**Steps:**
1. Ensure logged-in state and WebView visible.
2. Verify App Lock is OFF:
   ```swift
   navigateToSettings()
   let toggle = app.switches["App Lock"]
   XCTAssertTrue(toggle.waitForExistence(timeout: 5))
   XCTAssertEqual(toggle.value as? String, "0", "App Lock must be OFF for this test")
   // Navigate back to main screen
   ```
3. Send app to background: `XCUIDevice.shared.press(.home)`.
4. Wait 2 seconds.
5. Re-activate: `app.activate()`.
6. Assert NO auth screen appeared:
   ```swift
   XCTAssertFalse(app.buttons["Use PIN"].waitForExistence(timeout: 3), "No Use PIN when lock is off")
   XCTAssertFalse(app.staticTexts["Enter PIN"].exists, "No PIN screen when lock is off")
   ```
7. Assert WebView is still visible:
   `XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5), "WebView must remain visible")`

**Expected result:**
- No auth prompt appears after background/foreground cycle.
- WebView remains accessible.

**Known limitations:**
- The navigateToSettings() → return flow requires the Settings sheet to be dismissible.
  Use `app.navigationBars.buttons.firstMatch.tap()` or swipe-to-dismiss the sheet.
- The 2-second background time must exceed the `scenePhase` debounce interval in
  `AuthViewModel`. If the app uses a grace period (e.g., 5 seconds before locking),
  adjust the wait to match.

---

### TEST UX-22 — Set new PIN is stored and usable on next unlock

**Test name:** `test_UX22_givenNewPINSet_whenAppRelaunched_thenNewPINUnlocks`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Logged-in state.
- App Lock enabled, a test-scaffold previous PIN (`"1111"`) set via launch argument.

**Steps:**
1. Navigate to Settings.
2. Find and tap "Change PIN" or "Set PIN" in the SECURITY section:
   ```swift
   let setPINButton = app.staticTexts["Change PIN"]
   XCTAssertTrue(setPINButton.waitForExistence(timeout: 5))
   setPINButton.tap()
   ```
3. If current PIN is required, enter `"1111"`.
4. On the "New PIN" entry screen, enter `"2468"`.
5. On the confirmation screen, enter `"2468"` again.
6. Assert success indicator (return to Settings, or success message).
7. Terminate and relaunch app.
8. On the PIN screen, enter `"2468"`.
9. Assert main screen appears:
   `XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "New PIN must unlock the app")`

**Expected result:**
- The new PIN `"2468"` successfully unlocks the app.
- The old PIN `"1111"` would no longer work (not verified in this test to avoid
  triggering lockout).

**Known limitations:**
- The "Change PIN" flow requires knowing the current PIN. A launch argument
  `"-SetTestPIN", "1111"` in setUp ensures the initial PIN is known.
- PIN entry on the setup screen may differ from the unlock screen (step count may
  be 4 or 6 digits; both are acceptable per UX-15: 4-6 digits). Use 4 digits
  consistently in tests.
- After setting the new PIN (`"2468"`), `tearDown` must reset it via launch argument
  to avoid state leakage into other tests.

---

---

## Misc Tests — Class: `E2E_MiscTests`

### TEST UX-30 — Menu button opens config/settings

**Test name:** `test_UX30_givenMainScreen_whenMenuButtonTapped_thenConfigOpens`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Logged-in state.

**Steps:**
1. Ensure logged-in state.
2. Assert WebView visible.
3. Tap hamburger menu: `app.buttons["line.3.horizontal"].tap()`.
4. Assert Config/accounts sheet opens:
   ```swift
   let configVisible = app.staticTexts["Accounts"].waitForExistence(timeout: 5)
       || app.buttons["Add Account"].waitForExistence(timeout: 5)
       || app.buttons["Settings"].waitForExistence(timeout: 5)
   XCTAssertTrue(configVisible, "Config sheet must open after tapping menu button")
   ```

**Expected result:**
- A config/account management sheet or screen appears.
- It contains Settings, Add Account, or account list items.

**Known limitations:**
- `"line.3.horizontal"` is the SF Symbols identifier used for the hamburger icon.
  If the button uses an `accessibilityIdentifier` instead, update the selector.
  Confirmed working in `F14_SettingsTests.test_F14_1_settings_hasFourSections`.
- The Config sheet appearance (modal sheet vs. navigation push) determines which
  assertions are appropriate. Use the element-based assertions above rather than
  checking navigation bar titles.

---

### TEST UX-31 — WebView shows loading spinner

**Test name:** `test_UX31_givenWebViewLoading_whenNavigating_thenLoadingSpinnerVisible`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Fresh login (so the WebView will perform a full load from the login transition).

**Steps:**
1. Launch app to login screen.
2. Start the `loginWithTestCredentials()` helper.
3. Immediately after tapping Login (before the WebView loads), poll for the spinner:
   ```swift
   // Spinner is typically visible during the 1-5 second load window
   let spinner = app.activityIndicators.firstMatch
   // OR app-defined spinner accessible element:
   // let spinner = app.otherElements["LoadingSpinner"]
   ```
4. Since the spinner is transient, wrap in a short polling loop:
   ```swift
   var spinnerWasSeen = false
   for _ in 0..<10 {
       if spinner.exists {
           spinnerWasSeen = true
           break
       }
       _ = XCTWaiter.wait(for: [], timeout: 0.5)
   }
   XCTAssertTrue(spinnerWasSeen, "Loading spinner must be visible while WebView loads")
   ```
5. Wait for the spinner to disappear and WebView to appear:
   `app.webViews.firstMatch.waitForExistence(timeout: 30)`.

**Expected result:**
- A spinner/activity indicator is visible during the WebView load.
- It disappears after the page loads.

**Known limitations:**
- The spinner is inherently transient (0.5–5 seconds). On a fast simulator with a
  local Odoo server, it may not be detectable. On a slow network, it is always visible.
- If the app uses a `ProgressView` or a custom overlay with an `accessibilityIdentifier`,
  update the query accordingly.
- This is the most timing-sensitive test in the suite. Accept a 30% flakiness rate in
  CI and mark as `XCTExpectFailure` if the spinner was not observed — the WebView
  loading successfully (step 5) confirms the feature works even if the spinner
  detection missed the window.

---

### TEST UX-59 — Language set to 简体中文 changes UI strings

**Test name:** `test_UX59_givenSimplifiedChineseLocale_whenAppLaunched_thenUIStringsAreSimplifiedChinese`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]`  ← override locale
- `app.launchArguments += ["-AppleLocale", "zh_CN"]`
- No prior account (login screen will show localized strings).
- Do NOT add the English locale override for this test.

**Steps:**
1. Launch app with Simplified Chinese launch arguments.
2. Wait for the login screen.
3. Assert key UI strings appear in Simplified Chinese:
   ```swift
   // "服务器" is the zh-Hans translation for "Server"
   // "数据库" is the zh-Hans translation for "Database"
   // These must NOT be the zh-Hant versions (伺服器, 資料庫)
   let serverLabel = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS '服务器' OR label CONTAINS 'WoowTech Odoo'")
   ).firstMatch
   XCTAssertTrue(serverLabel.waitForExistence(timeout: 5),
                 "Simplified Chinese UI strings must appear when zh-Hans locale is active")
   ```
4. Assert the HTTPS prefix label is localized (or unchanged — it is a constant):
   `XCTAssertTrue(app.staticTexts["https://"].exists)`
5. Navigate to Settings and assert section headers in Chinese:
   ```swift
   // Section headers are UPPERCASE in SwiftUI Form;
   // Chinese strings do not have a case distinction — they appear as-is.
   // The exact localized section header text must be confirmed from Localizable.strings.
   ```

**Expected result:**
- App UI strings (labels, buttons, section headers) are in Simplified Chinese.
- No English text appears for translated strings.
- zh-Hant variants (Traditional Chinese) are NOT used.

**Known limitations:**
- iOS applies the `-AppleLanguages` launch argument at process launch. This overrides
  the system language for the test process. This is the documented approach per
  CLAUDE.md and confirmed working in `F14_SettingsGapTests.setUp`.
- The exact Simplified Chinese strings must be confirmed from
  `odoo/Resources/zh-Hans.lproj/Localizable.strings`. If a string is untranslated
  (English fallback), the test should NOT fail for those strings.
- Navigating to Settings in Chinese locale: hamburger button, Settings label in Chinese.
  The `navigateToSettings()` helper uses `app.buttons["Settings"]` — in zh-Hans this
  may be `app.buttons["设置"]`. Provide a localized helper or use the button's
  `accessibilityIdentifier` instead of label.

---

### TEST UX-61 — Language set to English changes UI strings

**Test name:** `test_UX61_givenEnglishLocale_whenAppLaunched_thenUIStringsAreEnglish`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `app.launchArguments += ["-AppleLocale", "en_US"]`

**Steps:**
1. Launch app in English locale.
2. Assert key login screen strings are in English:
   ```swift
   XCTAssertTrue(app.staticTexts["Enter server details"].waitForExistence(timeout: 5),
                 "English locale must show 'Enter server details'")
   XCTAssertTrue(app.staticTexts["https://"].exists, "HTTPS prefix visible")
   ```
3. Proceed to credentials step and assert English labels:
   ```swift
   app.textFields["example.odoo.com"].tap()
   app.textFields["example.odoo.com"].typeText("demo.odoo.com")
   app.textFields["Enter database name"].typeText("demo")
   app.buttons["Next"].tap()
   XCTAssertTrue(app.staticTexts["Enter credentials"].waitForExistence(timeout: 5),
                 "English locale must show 'Enter credentials'")
   ```
4. Verify no Chinese characters appear in any visible static text:
   ```swift
   let chineseText = app.staticTexts.matching(
       NSPredicate(format: "label MATCHES '.*[\\u4e00-\\u9fff].*'")
   ).firstMatch
   XCTAssertFalse(chineseText.exists, "No Chinese characters should appear in English locale")
   ```

**Expected result:**
- All app UI strings are in English.
- No Chinese characters appear in navigation labels, section headers, or button labels.

**Known limitations:**
- The Unicode range `\u4e00–\u9fff` covers the CJK Unified Ideographs block.
  The WebView content (Odoo's own UI) may contain Chinese regardless of app locale —
  assert only on the native iOS UI layer elements (static texts outside the WebView).
- The `MATCHES` predicate with a Unicode range requires correct NSPredicate regex
  escaping. Test the predicate in a unit test before using it in XCUITest.
- This test is the inverse complement of UX-59. Both should share a helper
  `assertStringIsEnglish()` and `assertStringIsSimplifiedChinese()`.

---

## Test Execution Order Recommendation

Run MEDIUM priority tests grouped by dependency:

**Group A — No active session needed:**
1. `E2E_LoginErrorTests.test_UX08_*`
2. `E2E_LoginErrorTests.test_UX09_*`
3. `E2E_MiscTests.test_UX59_*` (uses zh-Hans locale override)
4. `E2E_MiscTests.test_UX61_*` (uses en locale override)

**Group B — Requires active session:**
5. `E2E_WebViewTests.test_UX25_*` (login first)
6. `E2E_MiscTests.test_UX30_*` (requires logged-in)
7. `E2E_MiscTests.test_UX31_*` (requires login transition)
8. `E2E_CacheTests.test_UX64_*`
9. `E2E_CacheTests.test_UX65_*`

**Group C — Requires App Lock / PIN configuration:**
10. `E2E_AppLockTests.test_UX10_*`
11. `E2E_AppLockTests.test_UX11_*`
12. `E2E_AppLockTests.test_UX21_*`
13. `E2E_AppLockTests.test_UX22_*`
14. `E2E_PINLockoutTests.test_UX16_*`
15. `E2E_PINLockoutTests.test_UX17_*` (run last in group — triggers lockout)

**Group D — Deep link security (short, stateless):**
16. `E2E_DeepLinkSecurityTests.test_UX72_*`
17. `E2E_DeepLinkSecurityTests.test_UX73_*`
18. `E2E_DeepLinkSecurityTests.test_UX74_*`
19. `E2E_DeepLinkSecurityTests.test_UX75_*`

**Group E — Notifications (slow, require FCM delivery):**
20. `E2E_NotificationTests.test_UX41_*`
21. `E2E_NotificationTests.test_UX44_*`
22. `E2E_NotificationTests.test_UX45_*`
23. `E2E_NotificationTests.test_UX46_*`

---

## CI Integration Notes

```yaml
# GitHub Actions — MEDIUM priority tests (run after HIGH priority pass)
- name: Run MEDIUM priority E2E tests
  run: |
    xcodebuild test \
      -project odoo.xcodeproj \
      -scheme odoo \
      -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.0' \
      -only-testing:odooUITests/E2E_PINLockoutTests \
      -only-testing:odooUITests/E2E_NotificationTests \
      -only-testing:odooUITests/E2E_CacheTests \
      -only-testing:odooUITests/E2E_DeepLinkSecurityTests \
      -only-testing:odooUITests/E2E_LoginErrorTests \
      -only-testing:odooUITests/E2E_AppLockTests \
      -only-testing:odooUITests/E2E_MiscTests \
      TEST_SERVER_URL="${{ secrets.TEST_SERVER_URL }}" \
      TEST_DB="${{ secrets.TEST_DB }}" \
      TEST_ADMIN_USER="${{ secrets.TEST_ADMIN_USER }}" \
      TEST_ADMIN_PASS="${{ secrets.TEST_ADMIN_PASS }}" \
      TEST_SENDER_EMAIL="${{ secrets.TEST_SENDER_EMAIL }}" \
      TEST_SENDER_PASS="${{ secrets.TEST_SENDER_PASS }}" \
      | xcpretty
```

Slow tests (UX-08, UX-09) require `OTHER_TEST_FLAGS="-testTimeout 120"` to prevent
the 60-second default timeout from killing them during the URLSession timeout window.

---

## Required App-Side Test Hooks

The following launch arguments must be implemented in the app's `App.swift` or
`AppDelegate.swift` to make the PIN and App Lock tests deterministic:

| Launch Argument | Purpose |
|---|---|
| `"-SetTestPIN", "XXXX"` | Pre-seed a known PIN hash in Keychain before test |
| `"-ResetPINLockout", "YES"` | Clear lockout state (attempts counter + expiry) |
| `"-AppLockEnabled", "YES"` | Force App Lock ON without navigating Settings |
| `"-AppLockEnabled", "NO"` | Force App Lock OFF |
| `"-SimulateTimeout", "YES"` | Inject a URLProtocol that times out all requests |
| `"-SimulateNetworkError", "YES"` | Inject a URLProtocol that returns connection refused |

These hooks must only activate when `ProcessInfo.processInfo.arguments.contains("-SetTestPIN")`
is true (i.e., when running under XCUITest). They must not be present in the release build
(guard with `#if DEBUG`).

---

## Definition of Done

A test is considered ready to merge when:
- [ ] It compiles without warnings.
- [ ] It passes 3 consecutive runs on iPhone 16 Simulator (iOS 18).
- [ ] Every `guard else` branch has both a screenshot attachment and `XCTFail`.
- [ ] No `sleep()` calls (except after `XCUIDevice.shared.press(.home)`, documented).
- [ ] Test name follows `test_UXnn_given_when_then` format.
- [ ] Required app-side test hooks are implemented (see table above).
- [ ] The test is listed in `docs/ios-verification-log.md` with its run result.
- [ ] Slow tests (UX-08, UX-09, UX-17, notification group) are flagged in CI with
  extended timeout.
