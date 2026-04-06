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
- `navigateToSettings()` pattern from `F14_SettingsGapTests` (hamburger -> Settings ->
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

## Required App-Side Test Hooks (MEDIUM Priority)

These launch arguments must be implemented in the app (guarded by `#if DEBUG`) before
the dependent tests can run deterministically. Tests that depend on them are marked
**REQUIRES APP HOOK**.

| Launch Argument | Purpose | Used by |
|---|---|---|
| `"-SetTestPIN", "XXXX"` | Pre-seed a known PIN hash in Keychain | UX-16, UX-17, UX-22 |
| `"-ResetPINLockout", "YES"` | Clear lockout state (attempts counter + expiry) | UX-17 tearDown |
| `"-AppLockEnabled", "YES"` | Force App Lock ON without navigating Settings | UX-10, UX-11, UX-16, UX-17 |
| `"-AppLockEnabled", "NO"` | Force App Lock OFF | UX-21 |
| `"-SimulateTimeout", "YES"` | Inject a URLProtocol that times out all requests | UX-09 |
| `"-SimulateNetworkError", "YES"` | Inject a URLProtocol that returns connection refused | UX-08 (optional) |

None of these hooks exist in the codebase today. Implement them before writing the
dependent tests. The `OdooAPIClient` already has `URLProtocol` injection support from
IC19, but the launch-argument wiring to activate it at runtime is missing.

---

---

## PIN Lockout Tests -- Class: `E2E_PINLockoutTests`

### TEST UX-16 -- Wrong PIN shows error and remaining attempt count

**Test name:** `test_UX16_givenWrongPIN_whenEntered_thenErrorAndRemainingAttemptsShown`

**REQUIRES APP HOOK:** `"-SetTestPIN", "1234"`, `"-AppLockEnabled", "YES"`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `app.launchArguments += ["-SetTestPIN", "1234"]` **REQUIRES APP HOOK**
- `app.launchArguments += ["-AppLockEnabled", "YES"]` **REQUIRES APP HOOK**
- App lock enabled, PIN set to a known value `"1234"`.
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
- Without the `-SetTestPIN` hook, use `XCTSkip("PIN not pre-seeded")`.

---

### TEST UX-17 -- 5 wrong PINs trigger 30-second lockout message

**Test name:** `test_UX17_givenFiveWrongPINs_whenEntered_thenLockoutMessageAppears`

**REQUIRES APP HOOK:** `"-SetTestPIN", "1234"`, `"-AppLockEnabled", "YES"`,
`"-ResetPINLockout", "YES"` (in tearDown)

**Setup:**
- Same as UX-16.
- PIN set to `"1234"` via launch argument.
- **Important:** `tearDown` must reset lockout state via `"-ResetPINLockout", "YES"`
  or the lockout persists and pollutes subsequent tests. Since `tearDown` cannot change
  launch arguments of a running app, the next test's `setUp` must include
  `"-ResetPINLockout", "YES"` if it needs PIN access.

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
- The lockout state is persisted via `ProcessInfo.processInfo.systemUptime` comparison
  (confirmed in `SettingsRepository.swift`). It resets after the lockout duration
  expires, but in CI the test must not depend on waiting 30 seconds. The
  `"-ResetPINLockout"` hook is essential.

---

---

## Notification Tests -- Class: `E2E_NotificationTests`

These tests extend the patterns established in `FCM_EndToEndTests`. The notification
search strategy (four strategies: direct, expand group, dismiss focus, swipe up) is
reused from `verifyNotification()` in `FCM_EndToEndTests`. Extract it to a shared
`UITestNotificationHelper.swift` or copy the helper into this class.

**Flakiness advisory:** All notification tests depend on FCM delivery latency,
Springboard element rendering, and system notification grouping behavior. These tests
have inherent 20-30% flakiness on CI simulators. Mitigation: use generous timeouts
(15-20 seconds for delivery), retry once on failure, and always capture screenshots
on failure for post-mortem analysis.

### TEST UX-41 -- Chinese content in notification displays correctly

**Test name:** `test_UX41_givenChineseNotificationBody_whenDelivered_thenChineseCharsDisplay`

**Setup:**
- Logged-in state.
- Notification permission granted (must be granted at first install; cannot be
  programmatically granted in XCUITest).
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
- Requires live Odoo server connectivity. Skip with `XCTSkip` if unreachable.

---

### TEST UX-44 -- Multiple notifications grouped by event type

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
3. Wait 15 seconds for FCM delivery (use `XCTWaiter.wait(for: [], timeout: 15)` rather
   than `sleep` -- although for notification delivery waits, `sleep` is an accepted
   exception since there is no UI element to poll).
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
  version and user notification preferences.
- The grouping appearance (ScrollView vs. Button) varies between iOS versions; the
  search must try both, consistent with the four-strategy pattern.
- If the simulator has "Notification Grouping: Off" in Settings, notifications will
  not group. The CI simulator image must have default notification settings.
- FCM delivery of 3 messages in quick succession may arrive out of order or be
  coalesced. The test checks for grouping, not individual message content.

---

### TEST UX-45 -- Lock screen notification shows privacy placeholder

**Test name:** `test_UX45_givenLockScreen_whenNotificationArrives_thenContentHiddenOrPlaceholderShown`

**Feasibility:** LOW on simulator. iOS Simulator does not have a real lock screen with
passcode protection. `XCUIDevice.shared.press(.home)` sends the app to Springboard,
not to the lock screen. The "Show Previews: When Unlocked" notification setting only
applies when the device has a passcode set, which simulators do not support by default.

**Recommended approach:** Downgrade this test to a structural check. Verify that the
app configures `UNNotificationCategory` with `hiddenPreviewsBodyPlaceholder` at the
unit-test level (`NotificationServiceTests`). The XCUITest can only verify that a
notification appears on Springboard -- it cannot verify whether the content is hidden
because the simulator is always "unlocked."

**Setup:**
- Logged-in state.
- Notification permission granted.

**Steps:**
1. Call `ensureLoggedIn()`.
2. Send a notification via RPC with body `"UX45 privacy test secret"`.
3. Wait for delivery.
4. Open Springboard and verify the notification exists using `verifyNotification`.
5. **Note:** The content privacy check (asserting body is hidden) is NOT feasible on
   simulator. Log a warning and pass the test if the notification was delivered.

**Expected result:**
- Notification is delivered successfully (structural check).
- Content privacy enforcement is verified at the unit-test level, not here.

**Known limitations:**
- iOS Simulator does not enforce lock-screen content hiding because it has no passcode.
  This test cannot verify the privacy placeholder on a simulator.
- On a real device with a passcode, the behavior is testable manually.
- The `UNNotificationContent.hiddenPreviewsBodyPlaceholder` configuration should be
  verified in `NotificationServiceTests` (unit test), not here.

---

### TEST UX-46 -- Foreground notification shows banner (not auto-navigate)

**Test name:** `test_UX46_givenAppInForeground_whenNotificationDelivered_thenBannerShownNotAutoNavigated`

**Setup:**
- Logged-in state, app is active in the foreground.
- Notification permission granted.

**Steps:**
1. Call `ensureLoggedIn()`.
2. Assert WebView is visible (app is in foreground, Odoo loaded).
3. Send a notification via RPC with body `"UX46 foreground banner test"`.
4. Wait 10 seconds for delivery.
5. Assert the app is STILL showing the WebView (no auto-navigation occurred):
   `XCTAssertTrue(app.webViews.firstMatch.exists, "WebView must remain; app must not auto-navigate")`
6. The foreground banner is shown by the system (iOS `UNUserNotificationCenter`
   `.banner` presentation). Its presence on screen cannot be reliably asserted via
   XCUITest. The primary assertion is the absence of auto-navigation.

**Expected result:**
- App stays on the current screen (WebView visible).
- No automatic navigation to an Odoo record occurs.

**Known limitations:**
- The iOS foreground banner is a system overlay rendered above the app; its
  XCUITest detectability varies by iOS version and is unreliable.
- Auto-navigation suppression is implemented in `AppDelegate.userNotificationCenter(_:willPresent:)`.
  The unit test for this method is the authoritative coverage. This XCUITest provides
  integration-level confidence.
- The test depends on FCM delivery while the app is in the foreground. If the
  notification arrives late (after the assertion), the test still passes (no navigation
  occurred). If it arrives and auto-navigates, the test correctly fails.

---

---

## Cache Tests -- Class: `E2E_CacheTests`

### TEST UX-64 -- After cache clear, user remains logged in

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
   `app.staticTexts["Clear Cache"].waitForExistence(timeout: 5)` (button becomes re-hittable).
7. Navigate back to the main screen:
   - Tap the back/dismiss button or swipe right.
8. Assert the user is STILL logged in:
   `XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), "User must remain logged in after cache clear")`
   OR
   `XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 15), "Hamburger menu indicates logged-in state")`

**Expected result:**
- WebView is visible after returning from Settings.
- No login screen appears.
- Session (Keychain credentials) is not affected by cache clear.

**Overlap with existing tests:** `F14_SettingsTests.test_F14_4_clearCache_buttonExists`
verifies the button exists. UX-64 extends this by actually tapping Clear Cache and
verifying the session survives. No duplication.

**Known limitations:**
- "Clear Cache" triggers `WKWebsiteDataStore.default().removeData(ofTypes:)`, which
  clears WebView storage. Keychain credentials are separate. This test verifies
  the separation is correctly implemented.
- The "DATA & STORAGE" section header is UPPERCASE in SwiftUI Form; assert
  `app.staticTexts["DATA & STORAGE"]` not `"Data & Storage"`.
- Cache clearing is asynchronous. The success indicator (if any) should be waited
  on; if there is none, wait for the Clear Cache button to become hittable again.
- WebView reload after cache clear may take longer (15-second timeout accounts for
  cookie re-injection from Keychain + full page reload).

---

### TEST UX-65 -- After cache clear, Odoo loads (not login page)

**Test name:** `test_UX65_givenCacheCleared_whenWebViewReloads_thenOdooLoadsNotLoginPage`

**Setup:**
- Same as UX-64.

**Steps:**
1. Follow steps 1-7 from UX-64 to clear cache and return to main screen.
2. Wait for WebView to reload: `app.webViews.firstMatch.waitForExistence(timeout: 15)`.
3. Assert the login screen is NOT shown:
   ```swift
   let loginScreenVisible = app.textFields["example.odoo.com"].exists
   XCTAssertFalse(loginScreenVisible, "Login screen must not appear after cache clear when session is valid")
   ```
4. Assert Odoo WebView content loads (not a blank page or Odoo's `/web/login` page).
   A proxy: the hamburger menu (`"line.3.horizontal"`) is visible, indicating the
   main screen -- not the login screen.

**Expected result:**
- After cache clear, the app returns to Odoo's main interface.
- The Odoo web interface loads successfully.
- The user is not prompted to log in again.

**Known limitations:**
- After clearing WKWebView data, the WebView may reload the Odoo URL with the session
  cookie that is re-injected from Keychain. If cookie re-injection is not implemented,
  the session may be lost and the user IS redirected to login -- which would be a bug.
  This test guards against that regression.
- The WebView's Odoo page content cannot be fully inspected from XCUITest. The proxy
  assertion (no login screen + hamburger visible) is the practical verification.

---

---

## Deep Link Security Tests -- Class: `E2E_DeepLinkSecurityTests`

Note: UX-72, UX-73, UX-74 are primarily unit-test concerns (already covered by
`DeepLinkValidatorTests`). These XCUITests verify that the validator is wired into
the navigation pipeline -- i.e., that a rejected URL does NOT cause the WebView to
navigate to it. The verification approach is: send the bad URL via the app's
`woowodoo://open?url=<path>` scheme handler (confirmed in `odooApp.swift:handleIncomingURL`),
then assert the WebView's state did not change.

### TEST UX-72 -- `javascript:alert()` URL is rejected

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
   Note: `URL(string:)` may return nil for malformed URLs. If nil, the OS will not
   route the URL and the test should assert that nothing happened.
3. Open via `XCUIApplication().open(badURL)`.
4. Wait 2 seconds (use `app.webViews.firstMatch.waitForExistence(timeout: 2)` as wait).
5. Assert the app is still in the foreground:
   `XCTAssertEqual(app.state, .runningForeground, "App must stay in foreground")`
6. Assert no JavaScript alert appeared:
   `XCTAssertFalse(app.alerts.firstMatch.exists, "No JS alert must appear -- javascript: URL was rejected")`
7. Assert WebView still exists (no crash):
   `XCTAssertTrue(app.webViews.firstMatch.exists, "WebView must persist after rejection")`

**Expected result:**
- No JavaScript alert appears.
- WebView does not navigate to the JavaScript URL.
- App remains stable.

**Known limitations:**
- WKWebView inherently rejects `javascript:` navigation when it originates from
  `WKWebView.load(_:)`. The `DeepLinkValidator` provides an additional layer.
- The `woowodoo://open?url=` format is confirmed by `odooApp.swift:handleIncomingURL`.
  The handler reads `components.queryItems?.first(where: { $0.name == "url" })?.value`,
  then passes it through `DeepLinkValidator.isValid`.
- If `URL(string:)` returns nil for the javascript URL, the OS simply does not route
  it. Add a guard: `guard let badURL = URL(string: ...) else { XCTSkip("..."); return }`.

---

### TEST UX-73 -- `data:text/html` URL is rejected

**Test name:** `test_UX73_givenDataSchemeURL_whenOpenedViaScheme_thenWebViewDoesNotNavigate`

**Setup:**
- Same as UX-72.

**Steps:**
1. Ensure logged-in state and WebView visible.
2. Construct a `data:` URL deep link:
   ```swift
   let badURL = URL(string: "woowodoo://open?url=data:text/html,<h1>Injected</h1>")!
   ```
   Note: The angle brackets and commas may cause `URL(string:)` to return nil. Use
   percent-encoding if needed:
   `"woowodoo://open?url=data:text/html,%3Ch1%3EInjected%3C/h1%3E"`
3. Open via `XCUIApplication().open(badURL)`.
4. Wait 2 seconds.
5. Assert the WebView does not contain injected content:
   ```swift
   let injectedText = app.staticTexts["Injected"]
   XCTAssertFalse(injectedText.exists, "data: URL content must not appear in WebView")
   ```
6. Assert app remains foreground + WebView exists.

**Expected result:**
- The `data:text/html` URL is silently rejected.
- WebView retains its previous Odoo content.
- No visible change in the app.

**Known limitations:**
- WKWebView natively rejects `data:` URLs from `loadRequest`.
  This test is a belt-and-suspenders check on the validator wiring.
- The `URL(string:)` constructor may reject the raw data URL. If so, percent-encode it.

---

### TEST UX-74 -- External host URL is rejected

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

**Overlap with HIGH priority UX-26:** Both test external URL rejection. UX-26 (HIGH)
focuses on WebView staying intact as an E2E WebView test. UX-74 (MEDIUM) focuses on
the deep link validator wiring. The tests use the same `woowodoo://open?url=` mechanism.
Consider merging them during implementation if the overlap feels redundant.

**Known limitations:**
- The validator in `odooApp.swift:handleIncomingURL` compares the URL host against the
  active account's `serverHost`. An external host like `evil.com` will not match and
  `DeepLinkManager.setPending` will not be called. The WebView remains unchanged.
- If no active account exists, `serverHost` is empty and the validator rejects everything.

---

### TEST UX-75 -- `woowodoo://` URL scheme opens app

**Test name:** `test_UX75_givenWoowodooURLScheme_whenOpenedFromSpringboard_thenAppActivates`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App may be in background or not running.

**Steps:**
1. Launch app and let it reach a stable state (login or main screen).
2. Press home to send app to background: `XCUIDevice.shared.press(.home)`.
3. Wait 2 seconds for background transition.
4. Open the `woowodoo://` URL:
   ```swift
   let deepLink = URL(string: "woowodoo://open")!
   XCUIApplication().open(deepLink)
   ```
5. Assert the app activates and reaches the foreground:
   ```swift
   XCTAssertTrue(
       app.wait(for: .runningForeground, timeout: 10),
       "App must activate when woowodoo:// URL is opened"
   )
   ```
6. Assert the app shows either the login screen or the main screen (not crashed):
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
- `XCUIApplication().open(_:)` opens a URL via the system. If the app is already
  running, it activates it. If not running, it launches it.
- The URL scheme `woowodoo` is registered in `Info.plist` under `CFBundleURLTypes`
  (confirmed: `Info.plist` line 28).
- `app.wait(for: .runningForeground, timeout: 10)` requires XCTest 14+.

---

---

## Login Error Tests -- Class: `E2E_LoginErrorTests`

### TEST UX-08 -- Network error shows error message

**Test name:** `test_UX08_givenNetworkError_whenLoginAttempted_thenErrorMessageShown`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Fresh login state (no prior account).
- Network unreachable: use a deliberately invalid server URL (non-routable IP or
  a domain that does not exist).

**Steps:**
1. Launch app to login screen.
2. Enter a non-routable server URL: `"192.0.2.1"` (TEST-NET-1, RFC 5737, guaranteed unreachable).
3. Enter any database name: `"test"`.
4. Tap `app.buttons["Next"]`.
5. Wait for credentials step. Note: if the app validates the server URL in step 1,
   the error may appear before reaching the credentials step. Check for both paths:
   ```swift
   let credentialsStep = app.staticTexts["Enter credentials"].waitForExistence(timeout: 10)
   if credentialsStep {
       // Reached credentials step -- server URL was accepted syntactically
       app.textFields["Username or email"].tap()
       app.textFields["Username or email"].typeText("test")
       app.secureTextFields["Enter password"].tap()
       app.secureTextFields["Enter password"].typeText("test")
       app.buttons["Login"].tap()
   }
   ```
6. Wait for error message (up to 35 seconds -- exceeds the 30-second URLSession timeout):
   ```swift
   let errorText = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS[c] 'connect' OR label CONTAINS[c] 'network' OR label CONTAINS[c] 'unable' OR label CONTAINS[c] 'reach' OR label CONTAINS[c] 'error'")
   ).firstMatch
   XCTAssertTrue(errorText.waitForExistence(timeout: 35), "Network error message must appear")
   ```

**Expected result:**
- An error message about connectivity failure appears.
- App remains on the login screen.
- No crash.

**Known limitations:**
- This test takes up to 35 seconds due to the URLSession timeout. Mark in CI pipeline
  as a slow test.
- `192.0.2.1` (TEST-NET-1) is specifically reserved and unroutable per RFC 5737.
  On a CI machine with a corporate proxy, it may still get a response.
  Use `invalid-server.xctest-nonexistent` (guaranteed NXDOMAIN) as an alternative.
- The actual error string must match `LoginViewModel`'s error mapping for
  `URLError.notConnectedToInternet` or `URLError.timedOut`. Cross-check with
  `odooTests/LoginViewModelTests.swift`.

---

### TEST UX-09 -- Connection timeout shows error message

**Test name:** `test_UX09_givenConnectionTimeout_whenLoginAttempted_thenTimeoutErrorShown`

**REQUIRES APP HOOK (optional but strongly recommended):** `"-SimulateTimeout", "YES"`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- **Preferred:** `app.launchArguments += ["-SimulateTimeout", "YES"]` **REQUIRES APP HOOK**
  This uses the `URLProtocol` injection from IC19 to simulate a timeout in ~3 seconds.
- **Fallback (no hook):** Use a black-hole address `"10.255.255.1"` that accepts TCP
  connections but never responds. This takes 30+ seconds.

**Steps:**
1. Launch app.
2. Enter the server URL (either the black-hole address or any URL if using the
   `"-SimulateTimeout"` hook).
3. Enter credentials and tap Login.
4. Wait for timeout error:
   ```swift
   let timeout = app.launchArguments.contains("-SimulateTimeout") ? 10 : 35
   let timeoutText = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS[c] 'timeout' OR label CONTAINS[c] 'timed out' OR label CONTAINS[c] 'error'")
   ).firstMatch
   XCTAssertTrue(timeoutText.waitForExistence(timeout: TimeInterval(timeout)), "Timeout error message must appear")
   ```

**Expected result:**
- An error message mentioning "timeout" or "timed out" appears.
- App remains on login screen.

**Known limitations:**
- IC19 added `URLProtocol` injection for testability in `OdooAPIClient`. The
  `"-SimulateTimeout"` launch argument wiring is not yet implemented. Without it,
  the test is slow (30+ seconds) and fragile on CI networks.
- Black-hole addresses (`10.255.255.1`) may be filtered by firewalls on CI machines.
- Document in the test: `// Slow test: depends on URLSession timeout (30s)`.

---

---

## App Lock Tests -- Class: `E2E_AppLockTests`

### TEST UX-10 -- Enable App Lock requires auth on next launch

**Test name:** `test_UX10_givenAppLockEnabled_whenAppRelaunched_thenAuthRequired`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Logged-in state.
- App Lock starts OFF (or in a known state).

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
4. Handle PIN setup if it appears: the toggle may require setting a PIN before App Lock
   can be enabled. If a PIN setup sheet appears, enter `"1234"` twice (new + confirm).
5. Terminate the app: `app.terminate()`.
6. Relaunch: `app.launch()`.
7. Assert auth screen appears (biometric or PIN prompt, not WebView directly):
   ```swift
   let authRequired = app.buttons["Use PIN"].waitForExistence(timeout: 8)
       || app.staticTexts["Enter PIN"].waitForExistence(timeout: 5)
   XCTAssertTrue(authRequired, "Auth screen must appear after enabling App Lock and relaunching")
   ```

**Expected result:**
- After enabling App Lock and relaunching, the app requires biometric or PIN auth.
- The Odoo WebView is not visible until authentication succeeds.

**Overlap with existing tests:** `F14_SettingsTests.test_F14_3_appLock_toggleExists`
verifies the toggle exists. UX-10 extends this to test the actual behavior after
toggling. No duplication.

**Known limitations:**
- `app.terminate()` + `app.launch()` simulates a cold launch. The `scenePhase`
  transition from background to foreground (without termination) is a different
  flow (UX-20, covered in HIGH priority tests).
- The toggle may require a PIN to be set before App Lock can be enabled. The test
  must handle the PIN setup flow inline.
- App Lock toggle state is persisted via `AppSettings`. Ensure `tearDown` disables
  it to avoid polluting subsequent tests (terminate and relaunch with
  `"-AppLockEnabled", "NO"` if the hook is available).

---

### TEST UX-11 -- Launch with lock ON shows biometric prompt

**Test name:** `test_UX11_givenAppLockOn_whenAppLaunched_thenBiometricOrPINPromptShown`

**REQUIRES APP HOOK (optional):** `"-AppLockEnabled", "YES"` to pre-configure state.

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App Lock enabled (precondition -- either set in UX-10 which runs first, or via
  launch argument `"-AppLockEnabled", "YES"`).
- Prior login session exists.

**Steps:**
1. Launch app.
2. Wait for the auth screen:
   ```swift
   let biometricOrPIN = app.buttons["Use PIN"].waitForExistence(timeout: 8)
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
- This test depends on UX-10 having run first (App Lock is ON). Order tests
  accordingly, or use the `-AppLockEnabled` hook.

---

### TEST UX-21 -- App Lock OFF + background/foreground = no auth prompt

**Test name:** `test_UX21_givenAppLockOff_whenAppBackgroundsThenForegrounds_thenNoAuthPromptAppears`

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
3. Navigate back to the main screen (dismiss Settings).
4. Send app to background: `XCUIDevice.shared.press(.home)`.
5. Wait 2 seconds.
6. Re-activate: `app.activate()`.
7. Assert NO auth screen appeared:
   ```swift
   // Use a short timeout -- we are asserting ABSENCE, not presence.
   // Wait briefly for any auth screen to appear (it should not).
   let usePinAppeared = app.buttons["Use PIN"].waitForExistence(timeout: 3)
   XCTAssertFalse(usePinAppeared, "No Use PIN when lock is off")
   XCTAssertFalse(app.staticTexts["Enter PIN"].exists, "No PIN screen when lock is off")
   ```
8. Assert WebView is still visible:
   `XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5), "WebView must remain visible")`

**Expected result:**
- No auth prompt appears after background/foreground cycle.
- WebView remains accessible.

**Known limitations:**
- The navigateToSettings() -> return flow requires the Settings sheet to be dismissible.
  Use `app.navigationBars.buttons.firstMatch.tap()` or swipe-to-dismiss the sheet.
- The 2-second background time must exceed the `scenePhase` debounce interval in
  `AuthViewModel`. If the app uses a grace period (e.g., 5 seconds before locking),
  adjust the wait to match.
- Step 7 uses a 3-second timeout for absence assertion. This is a trade-off: too short
  and we might miss a delayed auth screen; too long and the test is slow. 3 seconds is
  a reasonable balance.

---

### TEST UX-22 -- Set new PIN is stored and usable on next unlock

**Test name:** `test_UX22_givenNewPINSet_whenAppRelaunched_thenNewPINUnlocks`

**REQUIRES APP HOOK:** `"-SetTestPIN", "1111"` to set the initial known PIN.
**REQUIRES APP HOOK:** `"-AppLockEnabled", "YES"` to ensure App Lock is ON.

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `app.launchArguments += ["-SetTestPIN", "1111"]` **REQUIRES APP HOOK**
- `app.launchArguments += ["-AppLockEnabled", "YES"]` **REQUIRES APP HOOK**
- Logged-in state, App Lock enabled, initial PIN is `"1111"`.

**Steps:**
1. Launch app. Unlock with PIN `"1111"` to reach main screen.
2. Navigate to Settings.
3. Find and tap "Change PIN" in the SECURITY section:
   ```swift
   let changePINButton = app.staticTexts["Change PIN"]
   XCTAssertTrue(changePINButton.waitForExistence(timeout: 5))
   changePINButton.tap()
   ```
4. If current PIN is required, enter `"1111"`.
5. On the "New PIN" entry screen, enter `"2468"`.
6. On the confirmation screen, enter `"2468"` again.
7. Assert success indicator (return to Settings, or success message).
8. Terminate and relaunch app (without the `-SetTestPIN` hook so the new PIN persists):
   ```swift
   app.terminate()
   app.launchArguments = ["-AppleLanguages", "(en)", "-AppLockEnabled", "YES"]
   app.launch()
   ```
9. On the PIN screen, enter `"2468"`.
10. Assert main screen appears:
    `XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), "New PIN must unlock the app")`

**Expected result:**
- The new PIN `"2468"` successfully unlocks the app.
- The old PIN `"1111"` would no longer work (not verified in this test to avoid
  triggering lockout).

**Known limitations:**
- The "Change PIN" flow requires knowing the current PIN. The `-SetTestPIN` hook
  ensures the initial PIN is known.
- PIN entry on the setup screen may differ from the unlock screen (step count may
  be 4 or 6 digits; both are acceptable per UX-15). Use 4 digits consistently in tests.
- After setting the new PIN (`"2468"`), subsequent tests that need PIN access must
  know this value. Use `-SetTestPIN` in the next test's setUp to reset.

---

---

## Misc Tests -- Class: `E2E_MiscTests`

### TEST UX-30 -- Menu button opens config/settings

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

**Overlap with existing tests:** `F14_SettingsTests.test_F14_1_settings_hasFourSections`
navigates through the hamburger menu to Settings. UX-30 stops at the Config sheet level
(does not enter Settings). The menu-button-opens-config flow is implicitly tested by
every test that calls `navigateToSettings()`, but UX-30 explicitly asserts the Config
sheet contents. Mild overlap; keep for explicit coverage.

**Known limitations:**
- `"line.3.horizontal"` is the SF Symbols identifier used for the hamburger icon.
  Confirmed working in `F14_SettingsTests.test_F14_1_settings_hasFourSections`.

---

### TEST UX-31 -- WebView shows loading spinner

**Test name:** `test_UX31_givenWebViewLoading_whenNavigating_thenLoadingSpinnerVisible`

**Flakiness advisory:** HIGH. The spinner is transient (0.5-5 seconds). On a fast
simulator with a local Odoo server, it may not be detectable. This test should use
`XCTExpectFailure` for the spinner assertion while still asserting the WebView loads.

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Fresh login (so the WebView will perform a full load from the login transition).

**Steps:**
1. Launch app to login screen.
2. Start the `loginWithTestCredentials()` helper.
3. Immediately after tapping Login (before the WebView loads), poll for the spinner:
   ```swift
   let spinner = app.activityIndicators.firstMatch
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
   // Use XCTExpectFailure for the spinner check -- it is timing-dependent
   XCTExpectFailure("Spinner detection is timing-sensitive and may not be caught on fast connections") {
       XCTAssertTrue(spinnerWasSeen, "Loading spinner must be visible while WebView loads")
   }
   ```
5. Wait for the WebView to appear (this is the hard requirement):
   `XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30), "WebView must load after login")`

**Expected result:**
- A spinner/activity indicator is visible during the WebView load (best-effort).
- The WebView loads successfully (hard requirement).

**Known limitations:**
- If the app uses a `ProgressView` or a custom overlay with an `accessibilityIdentifier`,
  update the query accordingly.
- The `loginWithTestCredentials()` helper has internal `sleep()` calls that may cause
  the test to miss the spinner window. The helper should be refactored to return
  after tapping Login (before the sleep) so the spinner can be caught.

---

### TEST UX-59 -- Language set to simplified Chinese changes UI strings

**Test name:** `test_UX59_givenSimplifiedChineseLocale_whenAppLaunched_thenUIStringsAreSimplifiedChinese`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]` -- override locale
- `app.launchArguments += ["-AppleLocale", "zh_CN"]`
- Do NOT add the English locale override for this test.
- No prior account (login screen will show localized strings).

**Steps:**
1. Launch app with Simplified Chinese launch arguments.
2. Wait for the login screen.
3. Assert key UI strings appear in Simplified Chinese:
   ```swift
   let serverLabel = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS '服务器' OR label CONTAINS 'WoowTech Odoo'")
   ).firstMatch
   XCTAssertTrue(serverLabel.waitForExistence(timeout: 5),
                 "Simplified Chinese UI strings must appear when zh-Hans locale is active")
   ```
4. Assert the HTTPS prefix label is unchanged (it is a constant):
   `XCTAssertTrue(app.staticTexts["https://"].exists)`

**Expected result:**
- App UI strings (labels, buttons, section headers) are in Simplified Chinese.
- No English text appears for translated strings.
- zh-Hant variants (Traditional Chinese) are NOT used.

**Known limitations:**
- iOS applies the `-AppleLanguages` launch argument at process launch. This overrides
  the system language for the test process. Confirmed working in existing tests.
- The exact Simplified Chinese strings must be confirmed from
  `odoo/Resources/zh-Hans.lproj/Localizable.strings`.
- Navigating to Settings in Chinese locale: the `navigateToSettings()` helper uses
  `app.buttons["Settings"]` -- in zh-Hans this may be `app.buttons["设置"]`.
  **Action needed:** Either use `accessibilityIdentifier` for the Settings button
  (requires app change) or create a locale-aware `navigateToSettings(locale:)` helper.
  For this test, skip the Settings navigation and verify only the login screen strings.

---

### TEST UX-61 -- Language set to English changes UI strings

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
   app.textFields["Enter database name"].tap()
   app.textFields["Enter database name"].typeText("demo")
   app.buttons["Next"].tap()
   XCTAssertTrue(app.staticTexts["Enter credentials"].waitForExistence(timeout: 10),
                 "English locale must show 'Enter credentials'")
   ```
4. Verify no Chinese characters appear in any visible static text:
   ```swift
   let allTexts = app.staticTexts.allElementsBoundByIndex
   let hasChinese = allTexts.contains { element in
       let label = element.label
       return label.unicodeScalars.contains { scalar in
           (0x4E00...0x9FFF).contains(scalar.value)
       }
   }
   XCTAssertFalse(hasChinese, "No Chinese characters should appear in English locale")
   ```

**Expected result:**
- All app UI strings are in English.
- No Chinese characters appear in navigation labels, section headers, or button labels.

**Known limitations:**
- The original plan used `NSPredicate(format: "label MATCHES '.*[\\u4e00-\\u9fff].*'")`.
  NSPredicate MATCHES with Unicode ranges is fragile. The revised approach iterates
  elements in Swift, which is more reliable.
- The `allElementsBoundByIndex` call can be slow if the element tree is large. Keep it
  to the login screen (before WebView loads) to avoid querying Odoo's web content.
- The WebView content (Odoo's own UI) may contain Chinese regardless of app locale --
  assert only on native iOS UI layer elements (before the WebView appears).

---

## Test Execution Order Recommendation

Run MEDIUM priority tests grouped by dependency:

**Group A -- No active session needed:**
1. `E2E_LoginErrorTests.test_UX08_*` (slow: 35s timeout)
2. `E2E_LoginErrorTests.test_UX09_*` (slow: 35s timeout without hook)
3. `E2E_MiscTests.test_UX59_*` (uses zh-Hans locale override)
4. `E2E_MiscTests.test_UX61_*` (uses en locale override)

**Group B -- Requires active session:**
5. `E2E_MiscTests.test_UX30_*` (requires logged-in)
6. `E2E_MiscTests.test_UX31_*` (requires login transition)
7. `E2E_CacheTests.test_UX64_*`
8. `E2E_CacheTests.test_UX65_*`

**Group C -- Requires App Lock / PIN configuration:**
9. `E2E_AppLockTests.test_UX10_*` (enables App Lock)
10. `E2E_AppLockTests.test_UX11_*` (depends on UX-10)
11. `E2E_AppLockTests.test_UX21_*` (requires App Lock OFF)
12. `E2E_AppLockTests.test_UX22_*` (requires PIN pre-seeded)
13. `E2E_PINLockoutTests.test_UX16_*` (requires PIN pre-seeded)
14. `E2E_PINLockoutTests.test_UX17_*` (run last in group -- triggers lockout)

**Group D -- Deep link security (short, stateless):**
15. `E2E_DeepLinkSecurityTests.test_UX72_*`
16. `E2E_DeepLinkSecurityTests.test_UX73_*`
17. `E2E_DeepLinkSecurityTests.test_UX74_*`
18. `E2E_DeepLinkSecurityTests.test_UX75_*`

**Group E -- Notifications (slow, require FCM delivery):**
19. `E2E_NotificationTests.test_UX41_*`
20. `E2E_NotificationTests.test_UX44_*`
21. `E2E_NotificationTests.test_UX45_*` (structural check only on simulator)
22. `E2E_NotificationTests.test_UX46_*`

---

## CI Integration Notes

```yaml
# GitHub Actions -- MEDIUM priority tests (run after HIGH priority pass)
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

---

## Architect Review Notes

**Reviewed:** 2026-04-06
**Reviewer:** Architect (Claude)

### Changes Made

1. **Moved "Required App-Side Test Hooks" to the top of the document.** The original
   placed the hooks table at the bottom. Since every PIN/AppLock test depends on them,
   having them upfront makes it immediately clear what must be built first. Also added
   **REQUIRES APP HOOK** markers to each dependent test.

2. **UX-45 (Lock screen privacy): Downgraded to structural check.** The original plan
   assumed the simulator could show a privacy placeholder on the lock screen. iOS Simulator
   does not have a real lock screen with passcode, so `UNNotificationCategory`'s
   `hiddenPreviewsBodyPlaceholder` is not enforced. Rewrote the test to verify notification
   delivery only (structural) and recommended the privacy enforcement be tested at the
   unit-test level in `NotificationServiceTests`.

3. **UX-31 (Loading spinner): Added `XCTExpectFailure`.** The spinner is transient and
   the existing `loginWithTestCredentials()` helper has `sleep()` calls that make the
   spinner detection window unreliable. Wrapped the spinner assertion in
   `XCTExpectFailure` so the test does not block CI, while still asserting the WebView
   loads (the hard requirement).

4. **UX-73 (data: URL): Added percent-encoding note.** The URL
   `woowodoo://open?url=data:text/html,<h1>Injected</h1>` contains angle brackets that
   may cause `URL(string:)` to return nil. Added the percent-encoded alternative.

5. **UX-74 (External host): Added overlap note with HIGH-priority UX-26.** Both tests
   use `woowodoo://open?url=` to test external URL rejection. Documented the overlap
   and recommended considering a merge during implementation.

6. **UX-59 (Simplified Chinese): Flagged `navigateToSettings()` incompatibility.** The
   helper uses `app.buttons["Settings"]` which is English. In zh-Hans locale, the button
   label is `"设置"`. Documented the need for either an `accessibilityIdentifier` or a
   locale-aware helper. Recommended skipping Settings navigation in this test and
   verifying only login screen strings.

7. **UX-61 (English locale): Replaced NSPredicate Unicode regex.** The original used
   `NSPredicate(format: "label MATCHES '.*[\\u4e00-\\u9fff].*'")` which is fragile with
   NSPredicate's regex engine. Replaced with a Swift-native Unicode scalar check that
   iterates `allElementsBoundByIndex`. Added note to limit the check to pre-WebView
   elements.

8. **UX-08/UX-09: Added fallback flow for server validation.** The original assumed the
   login flow always reaches the credentials step. If the app validates the server URL
   in step 1 (before credentials), the error may appear earlier. Added branching logic.

9. **UX-10: Added PIN setup handling.** The original did not account for the toggle
   requiring PIN setup before App Lock can be enabled. Added step 4 to handle the
   PIN setup sheet.

10. **UX-17: Documented lockout state persistence.** The lockout uses
    `ProcessInfo.processInfo.systemUptime` (confirmed in `SettingsRepository.swift`).
    Documented that the `-ResetPINLockout` hook is essential for CI, since waiting 30
    seconds is not acceptable.

11. **UX-22: Fixed relaunch strategy.** The original did not address that relaunching
    with `-SetTestPIN` would overwrite the newly set PIN. Changed step 8 to relaunch
    WITHOUT the `-SetTestPIN` argument so the new PIN (`"2468"`) persists.

12. **UX-11: Renamed from "shows biometric prompt" to "shows biometric or PIN prompt".**
    On simulators without biometric enrollment, the "Use PIN" fallback is shown. The test
    name and assertions now accept both outcomes.

13. **Added flakiness advisory to notification tests section.** All four notification
    tests depend on FCM delivery and Springboard rendering, making them inherently
    flaky. Added a section-level advisory with mitigation strategies.

14. **Added overlap notes throughout.** Cross-referenced existing tests
    (`F14_SettingsTests`, `F2_AuthGateTests`, `FCM_EndToEndTests`) where the new E2E
    tests cover similar ground. This helps the implementer decide whether to merge or
    keep both.

15. **Removed test count from Group B execution order.** The original listed
    `E2E_WebViewTests.test_UX25_*` in the medium-priority execution order, but UX-25
    is a HIGH-priority test. Removed it.

### Issues NOT Fixed (Accepted Risks)

- **Notification tests have inherent 20-30% flakiness.** FCM delivery timing is
  non-deterministic. The four-strategy pattern mitigates this but cannot eliminate it.
- **`loginWithTestCredentials()` uses `sleep()`.** The shared helper has `sleep(2)` and
  `sleep(5)`. This is outside the scope of this plan but should be refactored.
- **UX-22 Change PIN flow is app-implementation dependent.** The exact screen sequence
  (current PIN -> new PIN -> confirm) must be confirmed from the app source.
- **UX-09 without the SimulateTimeout hook takes 30+ seconds.** This is acceptable for
  medium-priority tests but should be improved with the hook.
