# E2E XCUITest Plan — HIGH Priority (12 Tests)

**Date:** 2026-04-06
**Scope:** UX-25, UX-26, UX-27, UX-28, UX-12, UX-13, UX-15, UX-20, UX-05, UX-67, UX-68, UX-69
**Estimated effort:** ~8 hours implementation + stabilization
**Companion document:** `2026-04-06-E2E-Medium-Priority_Test_Plan.md`

---

## Conventions Applied

- No `sleep()` — use `waitForExistence(timeout:)` exclusively (exception: system-level delays
  after `XCUIDevice.shared.press(.home)` where there is no observable element to poll)
- Force English locale in every `setUp`: `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `XCTFail` in every `guard else` branch
- Screenshot attachment on every failure path
- `@MainActor` on every test function
- `continueAfterFailure = false` in every `setUp`
- Section headers in SwiftUI Form render as UPPERCASE — match `"SECURITY"`, not `"Security"`
- `navigateToSettings()` is defined in `F14_SettingsGapTests`; copy the pattern, do not import

---

## Class Assignments

| Test class | Existing or New | Groups |
|---|---|---|
| `E2E_WebViewTests` | New | UX-25, UX-26, UX-27, UX-28 |
| `E2E_BiometricPINTests` | New | UX-12, UX-13, UX-15, UX-20 |
| `E2E_LoginAccountTests` | New | UX-05, UX-67, UX-68, UX-69 |

All three classes live in a new file:
`odooUITests/E2E_HighPriority_Tests.swift`

Each class has a private `navigateToSettings()` helper modeled after
`F14_SettingsGapTests.navigateToSettings()` (hamburger menu → Settings button →
assert `APPEARANCE` or `Appearance` section header).

---

## Shared Setup Pattern

```swift
override func setUp() {
    continueAfterFailure = false
    app.launchArguments += ["-AppleLanguages", "(en)"]
    app.launch()
}
```

All tests that require a logged-in state call the existing
`app.loginWithTestCredentials()` extension defined in `odooUITests.swift`.

---

## Failure Screenshot Helper

Every guard/XCTFail block must include:

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

## WebView Tests — Class: `E2E_WebViewTests`

### TEST UX-25 — WebView loads Odoo UI after login

**Test name:** `test_UX25_givenValidLogin_whenMainScreenAppears_thenWebViewExists`

**Setup:**
- `continueAfterFailure = false`
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Fresh simulator state (no prior account) OR clear keychain via launch argument
  `"-ResetAppState", "YES"` if the app supports it; otherwise rely on fresh install

**Steps:**
1. Launch app.
2. Assert login screen appears (`textFields["example.odoo.com"].waitForExistence(timeout: 5)`).
3. Call `app.loginWithTestCredentials()`.
4. Wait for `app.webViews.firstMatch.waitForExistence(timeout: 30)`.

**Expected result:**
`app.webViews.firstMatch.exists == true`

**Known limitations:**
- Simulator network latency can cause flakiness; the 30-second timeout is generous.
- If `loginWithTestCredentials()` lands on a biometric/PIN screen (prior session exists),
  the test should detect `app.buttons["Use PIN"]` and fall back to PIN entry before
  asserting the WebView. Add a guard branch for that case.
- WebView may show a loading spinner briefly; `waitForExistence` on the `webViews` element
  succeeds as soon as the WKWebView is inserted into the hierarchy, regardless of page load
  completion. That is sufficient for UX-25.

---

### TEST UX-26 — WebView blocks navigation to external host

**Test name:** `test_UX26_givenExternalHostURL_whenWebViewNavigates_thenURLStaysSameHost`

**Setup:**
- Logged-in state (call `ensureLoggedIn()` helper)
- `app.launchArguments += ["-AppleLanguages", "(en)"]`

**Prerequisite:** App must be on the main screen with the WebView visible.

**Steps:**
1. Ensure app is logged in via `ensureLoggedIn()`.
2. Assert `app.webViews.firstMatch.waitForExistence(timeout: 10)`.
3. Inject JavaScript into the WebView to attempt navigation to an external host:
   - Use `app.webViews.firstMatch.evaluate(javascript: "window.location.href = 'https://evil.com/test';")`
   - XCUITest does not expose `evaluate(javascript:)` directly; instead, use a
     `WKWebView` navigation delegate assertion at the unit-test level.
   - **XCUITest alternative:** Tap a known external link if one is present in the Odoo UI,
     then verify the app stays in the foreground (not Safari). See "Known limitations."
4. Wait 3 seconds.
5. Assert `app.state == .runningForeground` (app did not leave to Safari).
6. Assert `app.webViews.firstMatch.exists` is still `true`.

**Expected result:**
- App remains in foreground.
- WebView is still present.
- No Safari launch occurs.

**Known limitations:**
- XCUITest cannot inspect the WKWebView's current URL directly.
- Injecting JS via XCUITest is not supported; the actual same-host enforcement is
  tested at the unit-test level (`DeepLinkValidatorTests`). This XCUITest verifies
  only that the app does not leave the foreground — a coarse but verifiable signal.
- If Odoo's UI contains no external links on the default page, this test should be
  marked as a structural verification: assert WebView exists + app state is foreground
  after a navigation attempt using `app.open(URL(string: "https://evil.com")!)`.
  The URL scheme handler will reject it; verify app stays active.
- Preferred implementation: use `XCUIApplication().open(URL(...))` on a `woowodoo://`
  deep link pointing to an external URL, then assert the WebView URL did not change.

---

### TEST UX-27 — External link opens Safari (app leaves foreground)

**Test name:** `test_UX27_givenExternalLinkTapped_whenWebViewHandles_thenAppLeavesForegroud`

**Setup:**
- Logged-in state
- `app.launchArguments += ["-AppleLanguages", "(en)"]`

**Steps:**
1. Ensure app is logged in and WebView is visible.
2. Open a URL that is known to trigger the external-link handler. The cleanest approach
   is to call `XCUIApplication().open(URL(string: "https://www.google.com")!)` from the
   test harness — this exercises the URL routing at the system level rather than tapping
   inside the WebView.
3. Wait 3 seconds.
4. Assert `app.state != .runningForeground`
   (i.e., `app.state == .runningBackground` or `app.state == .notRunning`).
5. Capture screenshot.
6. Re-activate app: `app.activate()`.

**Expected result:**
- After tapping the external link, the app leaves the foreground.
- Safari (or the system browser) has taken focus.

**Known limitations:**
- The simulator opens external URLs in Safari; this behavior is observable via `app.state`.
- The exact element that carries the external link inside the WebView depends on runtime
  Odoo content; use the URL-open approach (step 2) as a deterministic alternative.
- `app.state` polling can be unreliable on simulators with slow animation; add a
  `waitForExistence`-style loop (max 5 iterations, 1-second intervals) on
  `app.state != .runningForeground` before asserting.

---

### TEST UX-28 — Session expiry redirects to login screen

**Test name:** `test_UX28_givenExpiredSession_whenWebViewDetectsRedirect_thenLoginScreenAppears`

**Setup:**
- Logged-in state
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Requires a mechanism to expire the session. Options:
  a. Log out via Odoo server API using `odooRPC` (invalidate the session cookie).
  b. Use a launch argument (`"-SimulateSessionExpiry", "YES"`) if implemented in
     the app's `OdooWebView.Coordinator`.
  c. Clear cookies programmatically before test by adding a special test hook.

**Steps:**
1. Log in and confirm WebView loads.
2. Expire the Odoo session by calling the server logout endpoint via the `odooRPC`
   helper (POST `/web/session/destroy`).
3. Reload the WebView — either wait for an automatic reload cycle or trigger via a
   known Odoo navigation action (e.g., navigate to `/web#action=home`).
4. Wait for login screen to appear:
   `app.textFields["example.odoo.com"].waitForExistence(timeout: 15)`
   OR `app.staticTexts["WoowTech Odoo"].waitForExistence(timeout: 15)`.

**Expected result:**
- Login screen appears without user action.
- WebView is no longer visible.

**Known limitations:**
- Session expiry detection depends on the `WKNavigationDelegate` recognizing the
  `/web/login` redirect. This is inherently a white-box behavior; the XCUITest can
  only observe the resulting screen change.
- If the app does not implement automatic session detection (only detects on navigation),
  the test must trigger a page reload. Use `app.webViews.firstMatch.tap()` followed by
  a URL navigation gesture to force a request.
- This test has a strong dependency on live network connectivity to the test Odoo server.
  Mark with `XCTSkip` if `TestConfig.serverURL` is unreachable.

---

---

## Biometric / PIN Auth Tests — Class: `E2E_BiometricPINTests`

### TEST UX-12 — Biometric success navigates to main screen

**Test name:** `test_UX12_givenBiometricAvailable_whenSucceeds_thenMainScreenAppears`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App lock must be enabled. Set via Keychain/UserDefaults in setUp, or accept that
  on a fresh install with no prior account this test is conditionally skipped.
- Simulator biometric: use `xcrun simctl` to enroll biometrics:
  ```
  xcrun simctl spawn booted notifyd post com.apple.BiometricKit_Simulator.cmd.enroll
  ```
  Then simulate a matching fingerprint:
  ```
  xcrun simctl spawn booted notifyd post com.apple.BiometricKit_Simulator.match.faceID
  ```

**Steps:**
1. Launch app.
2. Assert biometric prompt or `app.staticTexts["Authenticate to continue"]` appears
   within 5 seconds. If neither appears, the app may be on the login screen (no prior
   account) — call `XCTSkip("No logged-in account; biometric test requires prior session")`.
3. Trigger a simulated biometric match via Bash command or a test hook.
4. Assert `app.webViews.firstMatch.waitForExistence(timeout: 10)` OR
   `app.buttons["line.3.horizontal"].waitForExistence(timeout: 10)`.

**Expected result:**
- App navigates to the main screen (WebView or menu button visible).
- No PIN entry or auth prompt remains on screen.

**Known limitations:**
- iOS Simulator biometric simulation requires `xcrun simctl` commands, which cannot
  be issued from within XCUITest. Use a `Process` object in `setUp` or a companion
  shell script.
- On simulators where Face ID is not enrolled, `LAContext.evaluatePolicy` immediately
  returns `.biometryNotAvailable`. The test must detect this and skip gracefully.
- Preferred fallback: if biometric is unavailable, assert that the "Use PIN" button
  appears (which is the UX-13 test scenario) and skip the biometric success path with
  `XCTSkip`.
- The LAContext biometric flow happens in a system process; XCUITest observes only the
  resulting navigation. There is no element to wait on during the biometric animation.
  Use a generous `waitForExistence(timeout: 15)` on the main screen element.

---

### TEST UX-13 — Biometric failure shows "Use PIN" button

**Test name:** `test_UX13_givenBiometricFails_whenAuthPromptShown_thenUsePINButtonAppears`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App lock enabled, prior login session exists.
- Simulate biometric failure via `xcrun simctl`:
  ```
  xcrun simctl spawn booted notifyd post com.apple.BiometricKit_Simulator.mismatch
  ```

**Steps:**
1. Launch app.
2. Detect biometric prompt screen (wait for system LAContext UI or app's own overlay).
3. Trigger a biometric mismatch.
4. Assert `app.buttons["Use PIN"].waitForExistence(timeout: 5)`.
5. Assert `app.buttons["Skip"]` does NOT exist (UX-14 companion check).

**Expected result:**
- "Use PIN" button is visible.
- No "Skip" button is present.

**Known limitations:**
- On simulators with no biometric enrollment, `evaluatePolicy` fails immediately without
  showing a system dialog. The app should show "Use PIN" in that case as well.
- If the app uses a custom overlay instead of LAContext's system dialog, the detection
  in step 2 is more reliable via `app.staticTexts["Authenticate to continue"]` or
  the app-specific auth screen identifier.
- Biometric mismatch simulation with `simctl` may require the simulator to be in an
  enrolled state first. Enroll in `setUp`, then mismatch in the test body.

---

### TEST UX-15 — Correct PIN unlocks app

**Test name:** `test_UX15_givenCorrectPIN_whenEnteredOnPINScreen_thenUnlockSucceeds`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App lock enabled, PIN set to a known value (e.g., `"1234"`) via test fixture or
  pre-seeded Keychain state.
- Precondition: PIN screen is visible (either after biometric failure, or biometric
  is unavailable and "Use PIN" was auto-shown).

**Steps:**
1. Launch app.
2. If biometric screen is shown, tap `app.buttons["Use PIN"]`.
3. Assert `app.staticTexts["Enter PIN"].waitForExistence(timeout: 5)`.
4. Tap each digit of the known PIN using `app.buttons["1"]`, `app.buttons["2"]`,
   `app.buttons["3"]`, `app.buttons["4"]`.
5. Assert `app.webViews.firstMatch.waitForExistence(timeout: 10)` OR
   `app.buttons["line.3.horizontal"].waitForExistence(timeout: 10)`.

**Expected result:**
- After entering the correct PIN, the main screen appears.
- PIN screen is dismissed.

**Known limitations:**
- The PIN is stored as a PBKDF2 hash in Keychain. To pre-seed a known PIN ("1234"),
  a test-only launch argument (`"-SetTestPIN", "1234"`) should be added to the app's
  `AppDelegate` or `App` struct so the Keychain is populated before the test runs.
  Without this, the test cannot know the PIN value and must skip.
- PIN digit buttons are identified by their label ("1"–"9", "0") and the backspace by
  system image name `"delete.backward"`. This is confirmed by the existing
  `F10_PINSetupTests.test_F10_2_pinPad_hasAllDigitsAndBackspace`.
- If App Lock is toggled off in a previous test run, this test must re-enable it.
  Use a dedicated `setUpAppLock()` helper.

---

### TEST UX-20 — App background and foreground re-prompts biometric/PIN

**Test name:** `test_UX20_givenAppLockEnabled_whenAppBackgroundsThenForgrounds_thenAuthPromptAppears`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- App lock enabled, prior login exists, app is on the main screen (logged in + unlocked).

**Steps:**
1. Ensure app is logged in and on main screen (WebView or menu button visible).
2. Send app to background: `XCUIDevice.shared.press(.home)`.
3. Wait 1 second (minimum scene-phase transition time).
4. Re-activate app: `app.activate()`.
5. Wait for auth screen to appear:
   - `app.buttons["Use PIN"].waitForExistence(timeout: 5)` OR
   - `app.staticTexts["Enter PIN"].waitForExistence(timeout: 5)` OR
   - System biometric dialog (detected by absence of WebView).
6. Assert that `app.webViews.firstMatch.exists == false` (main screen is hidden).
7. Assert that either `app.buttons["Use PIN"].exists` OR the auth overlay is present.

**Expected result:**
- Upon foreground, the auth screen (biometric or PIN) is shown.
- The WebView (Odoo content) is not accessible without re-authentication.

**Known limitations:**
- `scenePhase` observation in SwiftUI fires on `.background` → `.inactive` → `.active`
  transitions. On simulator, the `press(.home)` + `app.activate()` pair reliably
  triggers this cycle.
- The biometric system dialog (LAContext) may appear in front of the app's SwiftUI
  overlay. In that case, the XCUITest detects the overlay is gone and the system dialog
  is present. Use the absence of the WebView as the primary assertion.
- If `AppSettings.appLockEnabled` is `false`, the auth screen will NOT appear.
  The test must assert App Lock is on before backgrounding — use the Settings screen
  to verify the switch value, or use a launch argument.

---

---

## Login + Account Tests — Class: `E2E_LoginAccountTests`

### TEST UX-05 — Wrong password shows "Invalid credentials" error

**Test name:** `test_UX05_givenWrongPassword_whenLoginAttempted_thenInvalidCredentialsErrorShown`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Fresh state: no prior account, OR explicitly navigate to login screen.

**Steps:**
1. Launch app.
2. Assert login screen: `app.textFields["example.odoo.com"].waitForExistence(timeout: 5)`.
3. Enter valid server URL and database using `TestConfig` values.
4. Tap `app.buttons["Next"]`.
5. Wait for credentials step: `app.staticTexts["Enter credentials"].waitForExistence(timeout: 5)`.
6. Enter valid username (`TestConfig.adminUser`) and a deliberately wrong password
   (`"wrongpassword_xctest_2026"`).
7. Tap `app.buttons["Login"]`.
8. Assert error message appears within 10 seconds:
   ```swift
   let error = app.staticTexts.matching(
       NSPredicate(format: "label CONTAINS[c] 'Invalid' OR label CONTAINS[c] 'invalid'")
   ).firstMatch
   XCTAssertTrue(error.waitForExistence(timeout: 10), "Invalid credentials error must appear")
   ```

**Expected result:**
- An error message containing "Invalid" or "invalid credentials" is visible.
- The user remains on the login screen.
- No navigation to the main screen occurs.

**Known limitations:**
- The exact error string depends on `LoginViewModel`'s error mapping. Cross-check with
  `odooTests/LoginViewModelTests.swift` for the string constant used.
- Network errors (DNS failure, timeout) produce a different message. The test must use
  a reliable test server (`TestConfig.serverURL`). Mark with `XCTSkip` if unreachable.
- The server returns a JSON-RPC error for invalid credentials; the app must surface it
  within the timeout. If the app shows an activity indicator for a long time, increase
  the timeout to 15 seconds.

---

### TEST UX-67 — Tap "Add Account" opens login screen

**Test name:** `test_UX67_givenConfigScreenOpen_whenAddAccountTapped_thenLoginScreenAppears`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- At least one account already exists (logged-in state).

**Steps:**
1. Ensure logged-in state (call `ensureLoggedIn()`).
2. Tap hamburger menu: `app.buttons["line.3.horizontal"]`.
3. Assert Config/accounts sheet appears (look for `app.staticTexts["Accounts"]` or
   `app.buttons["Add Account"]`).
4. Tap `app.buttons["Add Account"]`.
5. Assert login screen appears:
   `app.textFields["example.odoo.com"].waitForExistence(timeout: 5)` OR
   `app.staticTexts["Enter server details"].waitForExistence(timeout: 5)`.

**Expected result:**
- Login screen appears with the server URL field visible.
- The user can enter a new account's credentials.

**Known limitations:**
- The Config screen may be a `sheet` or pushed navigation; the identifier
  `"Add Account"` must match the actual button label. Confirm via dump if the test fails.
- If the Config screen is a `Form` with a SwiftUI section, the "Add Account" item may
  be a `Button` or a `NavigationLink`-backed row. Both are queryable via
  `app.buttons["Add Account"]`.
- On the first run (no account), the app starts on the login screen directly;
  `ensureLoggedIn()` must succeed before this test proceeds.

---

### TEST UX-68 — Switch account reloads WebView with new account

**Test name:** `test_UX68_givenMultipleAccounts_whenAccountSwitched_thenWebViewReloads`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Two accounts must exist in Core Data. This requires the test to have logged in
  twice (once per account) in prior test runs, OR use a seeded test fixture.
- If only one account exists, call `XCTSkip("Account switch test requires 2+ accounts")`.

**Steps:**
1. Ensure logged-in state on account A.
2. Confirm WebView is visible and record the initial page title or URL via accessibility label.
3. Tap hamburger menu.
4. In the Config/accounts sheet, find the second account row and tap it.
5. Assert the WebView disappears briefly (navigation transition) and reappears:
   `app.webViews.firstMatch.waitForExistence(timeout: 15)`.
6. Optionally assert that the account name shown in the Config sheet matches account B.

**Expected result:**
- WebView reloads with the new account's session.
- No login screen is shown (account B has a valid session).

**Known limitations:**
- If account B's session has expired, the app may redirect to login. The test should
  handle this gracefully and not fail — instead, assert either the WebView loaded OR
  the login screen appeared (both indicate a successful account switch that the app handled).
- The account list rows in the Config sheet are SwiftUI `List` items. They may be
  `Button` elements labeled with the account email or display name. Use an
  `NSPredicate(format: "label CONTAINS[c] %@", secondAccountEmail)` to find them.
- Seeding two accounts deterministically in XCUITest requires either:
  a. A launch argument that creates a fixture account in Core Data.
  b. Running UX-67 (Add Account) as a dependency in a prior test.
  Option (b) means these tests must run in sequence in a `XCTestSuite`.

---

### TEST UX-69 — Logout removes account and shows login screen

**Test name:** `test_UX69_givenLoggedInAccount_whenLogoutConfirmed_thenAccountRemovedAndLoginShown`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- At least one account exists (logged-in state).

**Steps:**
1. Ensure logged-in state.
2. Tap hamburger menu: `app.buttons["line.3.horizontal"].waitForExistence(timeout: 5)`.
3. Scroll down if needed to find `app.buttons["Logout"]`.
4. Tap `app.buttons["Logout"]`.
5. Assert confirmation alert appears:
   ```swift
   let alert = app.alerts.firstMatch
   XCTAssertTrue(alert.waitForExistence(timeout: 3), "Logout confirmation alert must appear")
   ```
6. Tap the destructive confirm button:
   ```swift
   let confirm = alert.buttons.matching(
       NSPredicate(format: "label CONTAINS[c] 'Logout' OR label CONTAINS[c] 'Confirm' OR label CONTAINS[c] 'Yes'")
   ).firstMatch
   XCTAssertTrue(confirm.exists, "Confirm button must exist in logout alert")
   confirm.tap()
   ```
7. Assert login screen appears:
   `app.textFields["example.odoo.com"].waitForExistence(timeout: 10)` OR
   `app.staticTexts["WoowTech Odoo"].waitForExistence(timeout: 10)`.

**Expected result:**
- After confirming logout:
  - Account is removed from the accounts list.
  - App navigates to the login screen.
  - Cookies and session data are cleared.
  - No biometric/PIN prompt appears (nothing to unlock).

**Known limitations:**
- If there are multiple accounts, logout may remove only the current account and switch
  to the next one rather than showing the login screen. The test should handle this case:
  assert either the login screen OR that the remaining account count is one less (not
  directly observable in XCUITest; use the Config sheet to count rows after logout).
- The logout confirmation alert label and button text must match the actual
  `UIAlertController`/`SwiftUI .alert()` strings. Cross-check with `F11_LogoutTests`
  for confirmed working identifiers (`"Logout"` alert, confirm button pattern).
- Existing `F11_LogoutTests.test_F11_2_logoutTap_showsConfirmation` already verifies
  the alert appears. `UX-69` extends this to verify the post-confirmation state.
  Reuse the same navigation pattern from `F11_LogoutTests`.

---

## Test Execution Order Recommendation

Run HIGH priority tests in this order to minimize state pollution:

1. `E2E_LoginAccountTests.test_UX05_*` — uses fresh/unauthenticated state
2. `E2E_WebViewTests.test_UX25_*` — logs in, verifies WebView
3. `E2E_WebViewTests.test_UX26_*` — requires logged-in + WebView
4. `E2E_WebViewTests.test_UX27_*` — requires logged-in + WebView
5. `E2E_WebViewTests.test_UX28_*` — logs in, then expires session
6. `E2E_BiometricPINTests.test_UX13_*` — no login required (detects biometric failure)
7. `E2E_BiometricPINTests.test_UX15_*` — requires PIN pre-seeded
8. `E2E_BiometricPINTests.test_UX12_*` — requires biometric simulation
9. `E2E_BiometricPINTests.test_UX20_*` — requires logged-in + lock enabled
10. `E2E_LoginAccountTests.test_UX67_*` — requires one account
11. `E2E_LoginAccountTests.test_UX68_*` — requires two accounts (skip if only one)
12. `E2E_LoginAccountTests.test_UX69_*` — run last (destroys the test account)

---

## CI Integration Notes

```yaml
# GitHub Actions example step
- name: Run HIGH priority E2E tests
  run: |
    xcodebuild test \
      -project odoo.xcodeproj \
      -scheme odoo \
      -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.0' \
      -only-testing:odooUITests/E2E_WebViewTests \
      -only-testing:odooUITests/E2E_BiometricPINTests \
      -only-testing:odooUITests/E2E_LoginAccountTests \
      TEST_SERVER_URL="${{ secrets.TEST_SERVER_URL }}" \
      TEST_DB="${{ secrets.TEST_DB }}" \
      TEST_ADMIN_USER="${{ secrets.TEST_ADMIN_USER }}" \
      TEST_ADMIN_PASS="${{ secrets.TEST_ADMIN_PASS }}" \
      | xcpretty
```

Biometric simulation steps (`xcrun simctl` commands) must run before the test target
is launched. Add them as a pre-test shell step in the CI workflow.

---

## Definition of Done

A test is considered ready to merge when:
- [ ] It compiles without warnings.
- [ ] It passes 3 consecutive runs on iPhone 16 Simulator (iOS 18).
- [ ] Every `guard else` branch has both a screenshot attachment and `XCTFail`.
- [ ] No `sleep()` calls (except after `XCUIDevice.shared.press(.home)` where documented).
- [ ] The test name follows `test_UXnn_given_when_then` format.
- [ ] The test is listed in `docs/ios-verification-log.md` with its run result.
