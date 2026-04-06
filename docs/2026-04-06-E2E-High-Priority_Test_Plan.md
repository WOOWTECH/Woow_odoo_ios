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

## Required App-Side Test Hooks (HIGH Priority)

The following launch arguments must be implemented in the app (guarded by `#if DEBUG`)
before these tests can run deterministically. Tests that depend on unimplemented hooks
are marked **REQUIRES APP HOOK** in their descriptions.

| Launch Argument | Purpose | Used by |
|---|---|---|
| `"-SetTestPIN", "XXXX"` | Pre-seed a known PIN hash in Keychain | UX-15, UX-20 |
| `"-AppLockEnabled", "YES"` | Force App Lock ON without navigating Settings | UX-12, UX-13, UX-15, UX-20 |
| `"-ResetAppState", "YES"` | Clear Keychain + Core Data for clean slate | UX-25 |

None of these hooks exist in the codebase today. Implement them before writing these tests.

---

---

## WebView Tests — Class: `E2E_WebViewTests`

### TEST UX-25 — WebView loads Odoo UI after login

**Test name:** `test_UX25_givenValidLogin_whenMainScreenAppears_thenWebViewExists`

**Setup:**
- `continueAfterFailure = false`
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Fresh simulator state (no prior account). On CI, use a fresh simulator snapshot.
  The launch argument `"-ResetAppState", "YES"` can be used if implemented.
  **REQUIRES APP HOOK:** `"-ResetAppState", "YES"`

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

**Overlap with existing tests:** `FCM_EndToEndTests.test_FCM_1_loginToOdooServer` covers
the same login-and-verify-WebView flow. UX-25 is a stricter version that asserts the
`webViews` element specifically and does not short-circuit on the menu button alone.
Keep both; UX-25 runs in its own clean-slate context.

---

### TEST UX-26 — WebView blocks navigation to external host

**Test name:** `test_UX26_givenExternalHostURL_whenOpenedViaDeepLink_thenWebViewDoesNotNavigate`

**Setup:**
- Logged-in state (call `ensureLoggedIn()` helper)
- `app.launchArguments += ["-AppleLanguages", "(en)"]`

**Prerequisite:** App must be on the main screen with the WebView visible.

**Steps:**
1. Ensure app is logged in via `ensureLoggedIn()`.
2. Assert `app.webViews.firstMatch.waitForExistence(timeout: 10)`.
3. Open an external URL via the app's deep link scheme. The app handles
   `woowodoo://open?url=<path>` and validates it through `DeepLinkValidator.isValid`.
   Send a URL that should be rejected:
   ```swift
   let badURL = URL(string: "woowodoo://open?url=https://evil.com/test")!
   XCUIApplication().open(badURL)
   ```
4. Wait 3 seconds (use `app.webViews.firstMatch.waitForExistence(timeout: 3)` as the wait).
5. Assert `app.state == .runningForeground` (app did not leave to Safari).
6. Assert `app.webViews.firstMatch.exists` is still `true`.

**Expected result:**
- App remains in foreground.
- WebView is still present.
- No Safari launch occurs.
- `DeepLinkValidator` rejected the external host URL silently.

**Known limitations:**
- XCUITest cannot inspect the WKWebView's current URL directly.
- The actual same-host enforcement is also covered at the unit-test level
  (`DeepLinkValidatorTests`). This XCUITest verifies the wiring at the app entry point.
- This test overlaps with medium-priority UX-74 (`E2E_DeepLinkSecurityTests`). UX-26
  focuses on the WebView staying intact; UX-74 focuses on the validator rejection.
  Both are valuable at different abstraction levels.

---

### TEST UX-27 — External link opens Safari (app leaves foreground)

**Test name:** `test_UX27_givenExternalLinkTapped_whenWebViewHandles_thenAppLeavesForground`

**Setup:**
- Logged-in state
- `app.launchArguments += ["-AppleLanguages", "(en)"]`

**Steps:**
1. Ensure app is logged in and WebView is visible.
2. Open an HTTPS URL that is NOT handled by the app's URL scheme (no `woowodoo://` prefix).
   The system will route it to Safari:
   ```swift
   let externalURL = URL(string: "https://www.google.com")!
   XCUIApplication().open(externalURL)
   ```
3. Poll for the app to leave the foreground (max 5 iterations, 1-second intervals):
   ```swift
   var leftForeground = false
   for _ in 0..<5 {
       if app.state != .runningForeground {
           leftForeground = true
           break
       }
       _ = XCTWaiter.wait(for: [], timeout: 1.0)
   }
   XCTAssertTrue(leftForeground, "App must leave foreground when external HTTPS URL is opened")
   ```
4. Capture screenshot.
5. Re-activate app: `app.activate()`.
6. Assert app returns to its previous state (WebView still present):
   `app.webViews.firstMatch.waitForExistence(timeout: 10)`

**Expected result:**
- After opening the external URL, the app leaves the foreground.
- Safari (or the system browser) has taken focus.
- App can be re-activated without data loss.

**Known limitations:**
- `XCUIApplication().open(URL)` opens the URL via the system, not through the WebView's
  navigation delegate. This tests the OS-level routing, which is the correct behavior
  for tapping external links that open in Safari.
- `app.state` polling can be unreliable on simulators with slow animation; the 5-iteration
  polling loop accounts for this.

---

### TEST UX-28 — Session expiry redirects to login screen

**Test name:** `test_UX28_givenExpiredSession_whenWebViewDetectsRedirect_thenLoginScreenAppears`

**Setup:**
- Logged-in state
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Requires a mechanism to expire the session. The feasible approach is to call the Odoo
  server's `/web/session/destroy` endpoint via the `odooRPC` helper. This invalidates
  the server-side session; the next WebView navigation will receive a `/web/login` redirect.

**Steps:**
1. Log in and confirm WebView loads.
2. Obtain session cookies via `odooLogin()` (reuse from `FCM_EndToEndTests` helpers).
3. Expire the Odoo session by calling:
   ```swift
   odooRPC(cookies: cookies, model: "", method: "",
           args: [], kwargs: [:])
   // Actually: direct POST to /web/session/destroy
   ```
   Implementation note: the `odooRPC` helper calls `/web/dataset/call_kw` which is
   model-specific. For session destruction, add a dedicated `odooSessionDestroy(cookies:)`
   helper that POSTs to `/web/session/destroy` directly.
4. Force the WebView to make a new request. Since XCUITest cannot inject JavaScript,
   use one of:
   a. Background and foreground the app (triggers WebView reload on some implementations).
   b. Tap the hamburger menu then navigate back (forces a WebView activity).
5. Wait for login screen to appear:
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
  the test must trigger a navigation event. This may require multiple attempts.
- This test has a strong dependency on live network connectivity to the test Odoo server.
  Mark with `XCTSkip` if `TestConfig.serverURL` is unreachable.
- The `odooSessionDestroy` helper does not exist yet in `odooUITests.swift`. It must
  be added alongside these tests.

---

---

## Biometric / PIN Auth Tests — Class: `E2E_BiometricPINTests`

### TEST UX-12 — Biometric success navigates to main screen

**Test name:** `test_UX12_givenBiometricEnrolled_whenMatchSucceeds_thenMainScreenAppears`

**Feasibility:** LIMITED ON SIMULATOR. Biometric simulation requires `xcrun simctl`
commands that cannot be issued from within XCUITest at runtime. The `Process` API is
sandboxed in XCUITest bundles and may not have permission to invoke `simctl`.

**REQUIRES APP HOOK:** `"-AppLockEnabled", "YES"` to ensure App Lock is ON without
navigating through Settings.

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `app.launchArguments += ["-AppLockEnabled", "YES"]` **REQUIRES APP HOOK**
- App lock must be enabled. Prior login session must exist.
- Simulator biometric enrollment must be done BEFORE the test target launches.
  Add to CI workflow as a pre-test step:
  ```bash
  xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.fingerTouch.match
  ```

**Recommended approach for CI:** Use a pre-test shell script that:
1. Enrolls Face ID: `xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.enrollFace`
2. The test detects the biometric prompt appears and the CI script sends a match signal.

**Alternative approach (more reliable):** Skip runtime biometric simulation entirely.
Instead, verify that:
1. The app shows the auth gate (biometric prompt or "Use PIN").
2. Fall back to PIN entry (UX-15) to unlock.
3. Mark the biometric-specific success path with `XCTSkip("Biometric match simulation
   requires CI shell coordination")` when not in CI.

**Steps:**
1. Launch app.
2. Assert biometric prompt or `app.staticTexts["Authenticate to continue"]` appears
   within 5 seconds. If neither appears, the app may be on the login screen (no prior
   account) — call `XCTSkip("No logged-in account; biometric test requires prior session")`.
3. If the biometric system dialog appears, the CI pre-test script sends a match signal.
4. Assert `app.webViews.firstMatch.waitForExistence(timeout: 15)` OR
   `app.buttons["line.3.horizontal"].waitForExistence(timeout: 15)`.

**Expected result:**
- App navigates to the main screen (WebView or menu button visible).
- No PIN entry or auth prompt remains on screen.

**Known limitations:**
- iOS Simulator biometric simulation requires `xcrun simctl` commands, which cannot
  be reliably issued from within XCUITest. The test depends on CI pipeline coordination.
- On simulators where Face ID is not enrolled, `LAContext.evaluatePolicy` immediately
  returns `.biometryNotAvailable`. The test must detect this and skip gracefully.
- The LAContext biometric flow happens in a system process; XCUITest observes only the
  resulting navigation. There is no element to wait on during the biometric animation.
  Use a generous `waitForExistence(timeout: 15)` on the main screen element.

---

### TEST UX-13 — Biometric failure shows "Use PIN" button

**Test name:** `test_UX13_givenBiometricUnavailableOrFails_whenAuthPromptShown_thenUsePINButtonAppears`

**Feasibility:** HIGH on simulator. On simulators without biometric enrollment (the
default state), `LAContext.evaluatePolicy` fails immediately and the app should
present the "Use PIN" fallback. No `xcrun simctl` coordination is needed.

**REQUIRES APP HOOK:** `"-AppLockEnabled", "YES"` to ensure App Lock is ON.

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `app.launchArguments += ["-AppLockEnabled", "YES"]` **REQUIRES APP HOOK**
- App lock enabled, prior login session exists.
- Do NOT enroll biometrics on the simulator (default state). This causes `LAContext`
  to fail immediately, which triggers the "Use PIN" fallback.

**Steps:**
1. Launch app.
2. Wait for the auth screen. On a simulator without biometric enrollment, the app should
   show "Use PIN" immediately (no system dialog appears):
   `app.buttons["Use PIN"].waitForExistence(timeout: 8)`.
3. Assert `app.buttons["Use PIN"].exists == true`.
4. Assert `app.buttons["Skip"]` does NOT exist (UX-14 companion check).

**Expected result:**
- "Use PIN" button is visible.
- No "Skip" button is present.

**Overlap with existing tests:** `F2_AuthGateTests.test_F2_2_biometricScreen_hasUsePinNotSkip`
verifies the same "Use PIN" button exists and "Skip" does not. UX-13 adds the explicit
precondition of App Lock being ON and does not silently pass when the auth screen is absent.
Consider whether UX-13 should replace F2.2 to avoid duplication; for now both are retained
because F2.2 runs on any app state while UX-13 requires App Lock ON.

**Known limitations:**
- On simulators with no biometric enrollment, `evaluatePolicy` fails immediately without
  showing a system dialog. The app should show "Use PIN" in that case. This is actually
  the most reliable test path for XCUITest.
- If the app uses a custom overlay instead of LAContext's system dialog, the detection
  is more reliable via `app.staticTexts["Authenticate to continue"]` or
  the app-specific auth screen identifier.

---

### TEST UX-15 — Correct PIN unlocks app

**Test name:** `test_UX15_givenCorrectPIN_whenEnteredOnPINScreen_thenUnlockSucceeds`

**REQUIRES APP HOOK:** `"-SetTestPIN", "1234"` to pre-seed a known PIN in Keychain.
**REQUIRES APP HOOK:** `"-AppLockEnabled", "YES"` to ensure App Lock is ON.

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `app.launchArguments += ["-SetTestPIN", "1234"]` **REQUIRES APP HOOK**
- `app.launchArguments += ["-AppLockEnabled", "YES"]` **REQUIRES APP HOOK**
- App lock enabled, PIN set to `"1234"` via test launch argument.
- Precondition: PIN screen is visible (either after biometric failure, or biometric
  is unavailable and "Use PIN" was auto-shown).

**Steps:**
1. Launch app.
2. If biometric screen is shown, tap `app.buttons["Use PIN"]`.
   If "Use PIN" is already visible (biometric unavailable), proceed directly.
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
  the `"-SetTestPIN"` launch argument must be implemented in the app's `App.swift`.
  Without this hook, the test cannot know the PIN value and must call
  `XCTSkip("PIN pre-seeding hook not implemented")`.
- PIN digit buttons are identified by their label ("1"--"9", "0") and the backspace by
  system image name `"delete.backward"`. This is confirmed by the existing
  `F10_PINSetupTests.test_F10_2_pinPad_hasAllDigitsAndBackspace`.
- If App Lock is toggled off in a previous test run, the launch argument hook handles
  re-enabling it. Without the hook, use a dedicated `setUpAppLock()` helper that
  navigates through Settings.

---

### TEST UX-20 — App background and foreground re-prompts biometric/PIN

**Test name:** `test_UX20_givenAppLockEnabled_whenAppBackgroundsThenForegrounds_thenAuthPromptAppears`

**REQUIRES APP HOOK:** `"-AppLockEnabled", "YES"` to ensure App Lock is ON.
**REQUIRES APP HOOK:** `"-SetTestPIN", "1234"` to enable PIN entry for unlock after assertion.

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- `app.launchArguments += ["-AppLockEnabled", "YES"]` **REQUIRES APP HOOK**
- `app.launchArguments += ["-SetTestPIN", "1234"]` **REQUIRES APP HOOK**
- App lock enabled, prior login exists, app is on the main screen (logged in + unlocked).

**Steps:**
1. Launch app. Unlock via PIN entry ("1234") to reach the main screen.
2. Assert WebView or menu button is visible (confirmed unlocked state).
3. Send app to background: `XCUIDevice.shared.press(.home)`.
4. Wait 2 seconds (system needs time for scene-phase transition; this is an acceptable
   exception to the no-sleep rule since there is no UI element to poll on Springboard).
5. Re-activate app: `app.activate()`.
6. Wait for auth screen to appear:
   - `app.buttons["Use PIN"].waitForExistence(timeout: 5)` OR
   - `app.staticTexts["Enter PIN"].waitForExistence(timeout: 5)` OR
   - System biometric dialog (detected by absence of WebView).
7. Assert that `app.webViews.firstMatch.exists == false` (main screen is hidden behind auth).
8. Assert that either `app.buttons["Use PIN"].exists` OR `app.staticTexts["Enter PIN"].exists`.

**Expected result:**
- Upon foreground, the auth screen (biometric or PIN) is shown.
- The WebView (Odoo content) is not accessible without re-authentication.

**Known limitations:**
- `scenePhase` observation in SwiftUI fires on `.background` -> `.inactive` -> `.active`
  transitions. On simulator, the `press(.home)` + `app.activate()` pair reliably
  triggers this cycle.
- The biometric system dialog (LAContext) may appear in front of the app's SwiftUI
  overlay. In that case, the XCUITest detects the overlay is gone and the system dialog
  is present. Use the absence of the WebView as the primary assertion.
- If `AppSettings.appLockEnabled` is `false`, the auth screen will NOT appear.
  The launch argument hook ensures it is ON. Without the hook, the test must navigate
  to Settings to verify the switch value before backgrounding.

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
5. Wait for credentials step: `app.staticTexts["Enter credentials"].waitForExistence(timeout: 10)`.
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
  `"Add Account"` must match the actual button label. Confirm via element dump if the test fails.
- If the Config screen is a `Form` with a SwiftUI section, the "Add Account" item may
  be a `Button` or a `NavigationLink`-backed row. Both are queryable via
  `app.buttons["Add Account"]`.
- On the first run (no account), the app starts on the login screen directly;
  `ensureLoggedIn()` must succeed before this test proceeds.

---

### TEST UX-68 — Switch account reloads WebView with new account

**Test name:** `test_UX68_givenMultipleAccounts_whenAccountSwitched_thenWebViewReloads`

**Feasibility:** LOW in isolated runs. Seeding two accounts deterministically requires
either a launch-argument hook to create a fixture account in Core Data, or running
UX-67 (Add Account) + completing a second login as a prerequisite step within this test.

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- Two accounts must exist in Core Data. This requires the test to have logged in
  twice (once per account) in prior test runs, OR use a seeded test fixture.
- If only one account exists, call `XCTSkip("Account switch test requires 2+ accounts")`.

**Recommended approach:** Make this test self-contained by:
1. Logging in as account A via `ensureLoggedIn()`.
2. Adding account B via the Config sheet "Add Account" flow (inline UX-67 steps).
3. Then switching to account B.
This makes the test independent of execution order, at the cost of being slower.

**Steps:**
1. Ensure logged-in state on account A.
2. Confirm WebView is visible.
3. Tap hamburger menu.
4. In the Config/accounts sheet, find the second account row and tap it.
   Use `NSPredicate(format: "label CONTAINS[c] %@", secondAccountEmail)` to find it.
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
  `Button` elements labeled with the account email or display name.
- This test requires a second test account with valid credentials. Add `TestConfig.secondUser`
  and `TestConfig.secondPass` environment variables, or skip if unavailable.

---

### TEST UX-69 — Logout removes account and shows login screen

**Test name:** `test_UX69_givenLoggedInAccount_whenLogoutConfirmed_thenAccountRemovedAndLoginShown`

**Setup:**
- `app.launchArguments += ["-AppleLanguages", "(en)"]`
- At least one account exists (logged-in state).

**Steps:**
1. Ensure logged-in state.
2. Tap hamburger menu: `app.buttons["line.3.horizontal"].waitForExistence(timeout: 5)`.
   Then tap the button.
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

**Overlap with existing tests:** `F11_LogoutTests.test_F11_2_logoutTap_showsConfirmation`
verifies the alert appears. UX-69 extends this to verify the **post-confirmation** state
(login screen shown, session cleared). The navigation pattern from F11 is reused.

**Known limitations:**
- If there are multiple accounts, logout may remove only the current account and switch
  to the next one rather than showing the login screen. The test should handle this case:
  assert either the login screen OR that the WebView reloaded with a different account.
- The logout confirmation alert label and button text must match the actual
  `SwiftUI .alert()` strings. Cross-check with `F11_LogoutTests` for confirmed working
  identifiers (`"Logout"` alert, confirm button pattern).

---

## Test Execution Order Recommendation

Run HIGH priority tests in this order to minimize state pollution:

1. `E2E_LoginAccountTests.test_UX05_*` -- uses fresh/unauthenticated state
2. `E2E_WebViewTests.test_UX25_*` -- logs in, verifies WebView
3. `E2E_WebViewTests.test_UX26_*` -- requires logged-in + WebView
4. `E2E_WebViewTests.test_UX27_*` -- requires logged-in + WebView
5. `E2E_WebViewTests.test_UX28_*` -- logs in, then expires session (destructive)
6. `E2E_BiometricPINTests.test_UX13_*` -- requires App Lock ON (no biometric enrollment needed)
7. `E2E_BiometricPINTests.test_UX15_*` -- requires PIN pre-seeded via hook
8. `E2E_BiometricPINTests.test_UX12_*` -- requires biometric CI coordination (likely skipped locally)
9. `E2E_BiometricPINTests.test_UX20_*` -- requires logged-in + lock enabled + PIN known
10. `E2E_LoginAccountTests.test_UX67_*` -- requires one account
11. `E2E_LoginAccountTests.test_UX68_*` -- requires two accounts (skip if only one)
12. `E2E_LoginAccountTests.test_UX69_*` -- run last (destroys the test account)

---

## CI Integration Notes

```yaml
# GitHub Actions example step
- name: Enroll Face ID on Simulator (required for UX-12)
  run: |
    xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit_Sim.enrollFace

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
- [ ] All REQUIRES APP HOOK items are implemented before the test is considered passing.

---

## Architect Review Notes

**Reviewed:** 2026-04-06
**Reviewer:** Architect (Claude)

### Changes Made

1. **Added "Required App-Side Test Hooks" section.** The original plan referenced
   launch arguments (`-ResetAppState`, `-SetTestPIN`, `-AppLockEnabled`) that do not
   exist in the app codebase. Grepping the `odoo/` source for `ProcessInfo.processInfo.arguments`
   confirmed none of these hooks are implemented. Every test that depends on them is now
   marked **REQUIRES APP HOOK** so the implementer knows to build the app-side code first.

2. **UX-26: Rewrote test approach.** The original referenced `evaluate(javascript:)` on
   `XCUIElement` and `app.open(URL)` with a bare HTTPS URL. XCUITest does not expose
   `evaluate(javascript:)`. The correct approach is to use the app's `woowodoo://open?url=`
   deep link scheme (confirmed in `odooApp.swift:handleIncomingURL`). Rewrote steps to
   use this verified URL format.

3. **UX-27: Fixed test name typo.** `thenAppLeavesForegroud` corrected to
   `thenAppLeavesForground`. Also replaced the bare `sleep(3)` with a polling loop
   (5 iterations, 1-second intervals) to comply with the no-sleep convention.

4. **UX-12: Added feasibility warning.** The `Process` API for running `xcrun simctl`
   from within XCUITest is sandboxed. Documented that biometric match simulation requires
   CI pipeline coordination (pre-test shell script), not inline `Process` calls. Added
   an alternative approach that skips runtime biometric simulation.

5. **UX-13: Simplified to leverage simulator default state.** On simulators without
   biometric enrollment (the default), `LAContext.evaluatePolicy` fails immediately
   and the app shows "Use PIN" without any `xcrun simctl` commands. Rewrote the test
   to rely on this behavior, making it fully feasible without CI coordination.
   Added overlap note with `F2_AuthGateTests.test_F2_2_biometricScreen_hasUsePinNotSkip`.

6. **UX-15, UX-20: Marked as REQUIRES APP HOOK.** Both tests assume a known PIN value.
   Without the `-SetTestPIN` hook, these tests must skip. Made this explicit.

7. **UX-20: Fixed test name.** Changed `thenForgrounds` to `thenForegrounds`.

8. **UX-25: Added overlap note.** `FCM_EndToEndTests.test_FCM_1_loginToOdooServer`
   covers the same flow. Documented why both are retained.

9. **UX-28: Removed reference to nonexistent launch argument.**
   `"-SimulateSessionExpiry", "YES"` is not implemented. Focused the plan on the
   server-side session destruction approach (POST `/web/session/destroy`) which is
   feasible using the existing `odooRPC` pattern.

10. **UX-68: Added feasibility warning and self-contained approach.** The original
    assumed two accounts exist from prior test runs, which makes it order-dependent.
    Added a recommended approach that creates the second account inline.

11. **UX-69: Added overlap note with F11_LogoutTests.** Documented that UX-69 extends
    the existing F11.2 test by verifying post-confirmation state.

12. **UX-05: Increased timeout for credentials step to 10 seconds.** The existing
    `loginWithTestCredentials()` has a `sleep(2)` after tapping Next (indicating the
    server validation can be slow). Changed `waitForExistence(timeout: 5)` to 10 seconds
    for the credentials step.

13. **CI Integration Notes: Added Face ID enrollment step.** The original mentioned
    biometric simulation as a pre-test step but did not include the actual CI YAML.

14. **Definition of Done: Added app hook requirement.** Tests depending on hooks should
    not be considered passing until the hooks are implemented.

### Issues NOT Fixed (Accepted Risks)

- **UX-28 relies on live Odoo server for session destruction.** No offline alternative
  exists. The `XCTSkip` guard is the mitigation.
- **UX-68 requires two distinct test accounts.** This is an infrastructure requirement,
  not a code issue. Documented the need for `TestConfig.secondUser`.
- **`loginWithTestCredentials()` uses `sleep()`.** The existing helper in
  `odooUITests.swift` has `sleep(2)` and `sleep(5)` calls. These should be refactored
  to `waitForExistence` but are outside the scope of this test plan.
