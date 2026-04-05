# Security Fixes Verification Plan — H1 through H6

**Date:** 2026-04-05
**Author:** Claude Code (test automation engineer)
**Scope:** Six high-priority security fixes identified in the 2026-04-05 Remaining Work Audit
**Reference:** `docs/2026-04-05-Remaining-Work-Audit_Implementation_Plan.md` sections H1–H6

---

## How to Read This Document

Each section follows this structure:

- **Fix summary** — what the audit found and what the implementation must change
- **Tests** — one row per test case:
  - **Name** — follows the project convention `test_{method}_given{Condition}_returns{Expected}`
  - **Type** — Unit (XCTest, no simulator required) or XCUITest (requires simulator)
  - **File** — where the test lives (create the file if it does not exist yet)
  - **Setup** — preconditions and fakes/stubs needed
  - **Steps** — action performed inside the test body
  - **Expected result** — the assertion that must pass

Tests are ordered from cheapest to most expensive within each section. Unit tests come before XCUITests.

---

## H1: DispatchSemaphore Removal

### Fix Summary

`AccountRepository.getSessionId(for:)` currently wraps an `async` `Task` inside a
`DispatchSemaphore.wait()` on the calling thread. When the caller is on the main thread
(as `MainViewModel.loadActiveAccount()` is), the `Task` that wants to resume on the main
thread finds it blocked by the semaphore — a deadlock.

The fix converts `getSessionId(for:)` to `async`, removes the semaphore, and propagates
`async` upward through `AccountRepositoryProtocol` and all call sites.

### Tests

---

#### H1-U1: Protocol signature is async

| Field | Value |
|-------|-------|
| **Name** | `test_getSessionId_protocolSignatureIsAsync` |
| **Type** | Unit |
| **File** | `odooTests/AccountRepositoryAsyncTests.swift` (new) |
| **Setup** | No setup — compile-time verification only |
| **Steps** | The test body calls `await mockRepo.getSessionId(for: "https://test.example.com")` where `mockRepo` is a `MockAccountRepository`. The call must compile without error, confirming the protocol method carries `async`. |
| **Expected result** | File compiles. `await` keyword is accepted by the compiler on the call. Absence of `async` in the protocol would be a compile error, so a passing build is the assertion. |

**Note:** If the protocol is not yet async, this test will fail to compile — which is the intended red phase of TDD.

---

#### H1-U2: MockAccountRepository getSessionId returns nil without blocking

| Field | Value |
|-------|-------|
| **Name** | `test_getSessionId_givenMockRepo_returnsWithoutBlocking` |
| **Type** | Unit |
| **File** | `odooTests/AccountRepositoryAsyncTests.swift` |
| **Setup** | Use the existing `MockAccountRepository` from `TestDoubles/TestDoubles.swift`. Update `MockAccountRepository.getSessionId(for:)` stub to be `async` and return `nil`. |
| **Steps** | Inside `XCTestCase.setUp`, capture `Date.now`. Call `await mockRepo.getSessionId(for: "https://any.com")`. Record `Date.now` again. |
| **Expected result** | The async call returns `nil` and completes in under 1 second (`XCTAssertLessThan(elapsed, 1.0)`). A semaphore-based implementation would hang indefinitely; async returns immediately. |

---

#### H1-U3: getSessionId called from MainActor does not deadlock

| Field | Value |
|-------|-------|
| **Name** | `test_getSessionId_givenMainActorCaller_completesWithoutDeadlock` |
| **Type** | Unit |
| **File** | `odooTests/AccountRepositoryAsyncTests.swift` |
| **Setup** | Create a `MockOdooAPIClient` that returns a fixed session cookie value of `"session_abc"` for any URL. Instantiate a real `AccountRepository` with an in-memory `PersistenceController` and the mock API client, bypassing the real Keychain and network. |
| **Steps** | Annotate the test function with `@MainActor`. Call `let result = await repo.getSessionId(for: "https://odoo.example.com")`. Apply a timeout expectation of 3 seconds via `XCTestExpectation`. |
| **Expected result** | The expectation is fulfilled before the timeout. `result` equals `"session_abc"`. A deadlock would cause the test runner to time out and report the test as a failure with a hang. |

---

#### H1-U4: MockAccountRepository getSessionId stub updated to async

| Field | Value |
|-------|-------|
| **Name** | `test_mockAccountRepository_getSessionId_returnsNil` |
| **Type** | Unit |
| **File** | `odooTests/AccountRepositoryAsyncTests.swift` |
| **Setup** | Instantiate `MockAccountRepository()` directly. |
| **Steps** | Call `await mockRepo.getSessionId(for: "https://odoo.example.com")`. |
| **Expected result** | Returns `nil`. This confirms the existing `TestDoubles.swift` stub has been updated to the new `async` signature without breaking existing tests. |

---

## H2: DeepLinkValidator — Empty serverHost and /web Prefix Bypass

### Fix Summary

Two separate issues exist:

1. `odooApp.swift` line 32 and `AppDelegate.swift` line 126 both pass `serverHost: ""`
   to `DeepLinkValidator.isValid`. The validator currently accepts any absolute HTTPS URL
   when `serverHost` is empty because the `caseInsensitiveCompare` against `""` always fails,
   which is the correct defensive behavior — but the callers should pass the actual active
   server host instead of `""`.

2. `AppDelegate.swift` line 126 has the short-circuit:
   `actionUrl.hasPrefix("/web") || DeepLinkValidator.isValid(...)`. This means any URL
   starting with `/web` — including crafted paths like `/web/../admin` or
   `/web@evil.com` — bypasses `isValid` entirely before the validator can reject it.
   The fix removes the short-circuit and lets the validator handle `/web` paths directly
   (the validator already has the `/web` allowlist internally).

Additionally, the audit identified that the validator should reject absolute URLs when
`serverHost` is empty, rather than silently failing to match.

### Tests

---

#### H2-U1: Validator rejects absolute HTTPS URL when serverHost is empty

| Field | Value |
|-------|-------|
| **Name** | `test_isValid_givenEmptyServerHost_rejectsAbsoluteUrl` |
| **Type** | Unit |
| **File** | `odooTests/odooTests.swift` — append to existing `DeepLinkValidatorTests` class |
| **Setup** | None. `DeepLinkValidator` is a stateless enum. |
| **Steps** | Call `DeepLinkValidator.isValid(url: "https://odoo.example.com/web", serverHost: "")`. |
| **Expected result** | Returns `false`. An empty `serverHost` means no server is configured; no absolute URL should be trusted. |

**Implementation note:** The current code returns `false` here because `caseInsensitiveCompare("odoo.example.com", "")` is `.orderedDescending`, not `.orderedSame`. This test codifies and verifies that defensive behavior so a future refactor cannot accidentally break it.

---

#### H2-U2: Validator accepts absolute HTTPS URL matching serverHost

| Field | Value |
|-------|-------|
| **Name** | `test_isValid_givenMatchingHost_acceptsAbsoluteHttpsUrl` |
| **Type** | Unit |
| **File** | `odooTests/odooTests.swift` — append to `DeepLinkValidatorTests` |
| **Setup** | None. |
| **Steps** | Call `DeepLinkValidator.isValid(url: "https://odoo.example.com/web#action=contacts", serverHost: "odoo.example.com")`. |
| **Expected result** | Returns `true`. |

---

#### H2-U3: Validator rejects absolute HTTPS URL with different host

| Field | Value |
|-------|-------|
| **Name** | `test_isValid_givenDifferentHost_rejectsAbsoluteHttpsUrl` |
| **Type** | Unit |
| **File** | `odooTests/odooTests.swift` — append to `DeepLinkValidatorTests` |
| **Setup** | None. |
| **Steps** | Call `DeepLinkValidator.isValid(url: "https://attacker.example.com/web", serverHost: "odoo.example.com")`. |
| **Expected result** | Returns `false`. |

---

#### H2-U4: Validator accepts relative /web path regardless of serverHost value

| Field | Value |
|-------|-------|
| **Name** | `test_isValid_givenRelativeWebPath_acceptsRegardlessOfServerHost` |
| **Type** | Unit |
| **File** | `odooTests/odooTests.swift` — append to `DeepLinkValidatorTests` |
| **Setup** | None. |
| **Steps** | Call `DeepLinkValidator.isValid(url: "/web#action=42", serverHost: "odoo.example.com")` and separately `DeepLinkValidator.isValid(url: "/web#action=42", serverHost: "")`. |
| **Expected result** | Both calls return `true`. The `/web` relative path is safe without a host comparison. |

---

#### H2-U5: AppDelegate.handleNotificationTap passes actual server host, not empty string

| Field | Value |
|-------|-------|
| **Name** | `test_handleNotificationTap_givenAbsoluteUrlDifferentHost_doesNotSetPending` |
| **Type** | Unit |
| **File** | `odooTests/AppDelegateDeepLinkTests.swift` (already exists — add test) |
| **Setup** | Instantiate `AppDelegate`. Inject or set a stubbed active account whose `serverUrl` is `"odoo.example.com"`. Use a `MockDeepLinkManager` or inspect `DeepLinkManager.shared.pendingUrl` before and after. |
| **Steps** | Call `handleNotificationTap(userInfo: ["odoo_action_url": "https://evil.com/web"])`. |
| **Expected result** | `DeepLinkManager.shared.pendingUrl` remains `nil` (or unchanged). The malicious host is blocked because `handleNotificationTap` now passes the real server host to `isValid`. |

**Context:** The existing `AppDelegateDeepLinkTests.swift` file likely already tests the happy path. This test specifically targets the bypass that existed because `serverHost: ""` was hardcoded.

---

#### H2-U6: AppDelegate short-circuit removed — /web prefix alone does not bypass validator

| Field | Value |
|-------|-------|
| **Name** | `test_handleNotificationTap_givenCraftedWebUrl_doesNotSetPending` |
| **Type** | Unit |
| **File** | `odooTests/AppDelegateDeepLinkTests.swift` |
| **Setup** | Same as H2-U5. Active server host is `"odoo.example.com"`. |
| **Steps** | Call `handleNotificationTap(userInfo: ["odoo_action_url": "/web@evil.com"])`. |
| **Expected result** | `DeepLinkManager.shared.pendingUrl` remains `nil`. The crafted URL starts with `/web` but is not a valid path; the validator rejects it when the short-circuit `hasPrefix("/web")` is removed and all URLs go through `isValid`. |

**Note on implementation:** After the fix, `AppDelegate.handleNotificationTap` should call only `DeepLinkValidator.isValid(url:serverHost:)` with the real host — no `hasPrefix` short-circuit. The validator already handles relative `/web` paths internally at line 29-31 of `DeepLinkValidator.swift`.

---

## H3: Session Cookie Saved to and Cleared from SecureStorage

### Fix Summary

The Odoo `session_id` cookie is currently stored in `HTTPCookieStorage.shared`, which
writes to an unencrypted `Cookies.binarycookies` file on disk. The fix migrates the
`session_id` value to Keychain via `SecureStorage` after a successful authentication,
and deletes it from Keychain during logout.

### Tests

---

#### H3-U1: session_id saved to SecureStorage after successful authentication

| Field | Value |
|-------|-------|
| **Name** | `test_authenticate_givenSuccess_savesSessionIdToSecureStorage` |
| **Type** | Unit |
| **File** | `odooTests/SessionCookieStorageTests.swift` (new) |
| **Setup** | Create a `MockSecureStorage` (from `TestDoubles.swift`). Extend it with a `sessionId` property — `func saveSessionId(serverUrl: String, sessionId: String)` and `func getSessionId(serverUrl: String) -> String?` — backed by the existing `store` dictionary with key `"session_\(serverUrl)"`. Create a `MockOdooAPIClient` that returns `AuthResult.success(AuthData(userId: 1, sessionId: "sid_abc", username: "admin", displayName: "Admin"))`. Inject both into an `AccountRepository`. |
| **Steps** | Call `await repo.authenticate(serverUrl: "odoo.example.com", database: "db", username: "admin", password: "pass")`. |
| **Expected result** | `mockSecureStorage.getSessionId(serverUrl: "https://odoo.example.com")` returns `"sid_abc"`. The session cookie is in the Keychain-backed store, not only in `HTTPCookieStorage`. |

---

#### H3-U2: session_id cleared from SecureStorage on logout

| Field | Value |
|-------|-------|
| **Name** | `test_logout_givenActiveAccount_deletesSessionIdFromSecureStorage` |
| **Type** | Unit |
| **File** | `odooTests/SessionCookieStorageTests.swift` |
| **Setup** | Use the same `MockSecureStorage`. Pre-populate it with `saveSessionId(serverUrl: "https://odoo.example.com", sessionId: "sid_old")`. Create an in-memory Core Data store with one active `OdooAccountEntity` pointing to `"odoo.example.com"`. |
| **Steps** | Call `await repo.logout(accountId: nil)`. |
| **Expected result** | `mockSecureStorage.getSessionId(serverUrl: "https://odoo.example.com")` returns `nil`. The session cookie has been removed from Keychain alongside the password deletion that already happens in `logout`. |

---

#### H3-U3: getSessionId reads from SecureStorage, not HTTPCookieStorage

| Field | Value |
|-------|-------|
| **Name** | `test_getSessionId_givenKeychainEntry_returnsKeychainValue` |
| **Type** | Unit |
| **File** | `odooTests/SessionCookieStorageTests.swift` |
| **Setup** | Use `MockSecureStorage` with a pre-populated session entry `"session_https://odoo.example.com" = "sid_from_keychain"`. Ensure `HTTPCookieStorage.shared` has no cookie for the URL (delete any stale test cookies in `setUp`). |
| **Steps** | Call `await repo.getSessionId(for: "https://odoo.example.com")`. |
| **Expected result** | Returns `"sid_from_keychain"`. The value comes from `SecureStorage`, not from `HTTPCookieStorage.shared`. |

---

#### H3-U4: session_id not written to HTTPCookieStorage after authentication

| Field | Value |
|-------|-------|
| **Name** | `test_authenticate_givenSuccess_doesNotWriteSessionToCookieStorage` |
| **Type** | Unit |
| **File** | `odooTests/SessionCookieStorageTests.swift` |
| **Setup** | Clear `HTTPCookieStorage.shared` for `"https://odoo.example.com"` in `setUp`. Use the same mock chain as H3-U1. |
| **Steps** | Call `await repo.authenticate(serverUrl: "odoo.example.com", database: "db", username: "admin", password: "pass")`. Query `HTTPCookieStorage.shared.cookies(for: URL(string: "https://odoo.example.com")!)` for a cookie named `"session_id"`. |
| **Expected result** | The `HTTPCookieStorage` query returns no `session_id` cookie (or the existing ephemeral WKWebView cookie is the only path, not the shared storage). This verifies the fix did not inadvertently add a second write path to the unencrypted store. |

---

## H4: Privacy Overlay on App Backgrounding

### Fix Summary

When the user presses the Home button or switches apps, iOS takes a screenshot of the
current view for the task switcher. `AppRootView` already observes `scenePhase` but only
calls `authViewModel.onAppBackgrounded()` — it does not add any visual overlay.

The fix adds a full-screen privacy overlay (a solid or blurred rectangle) that becomes
visible when `scenePhase == .inactive || scenePhase == .background`.

### Tests

---

#### H4-U1: Overlay state is `true` when scenePhase transitions to .background

| Field | Value |
|-------|-------|
| **Name** | `test_privacyOverlay_givenScenePhaseBackground_overlayIsVisible` |
| **Type** | Unit |
| **File** | `odooTests/PrivacyOverlayTests.swift` (new) |
| **Setup** | If privacy overlay state is managed by `AppRootViewModel` or `AuthViewModel`, instantiate the relevant ViewModel and set it up in `@MainActor`. If overlay state is local `@State` in `AppRootView`, extract it into a small dedicated `PrivacyOverlayViewModel` or a computed property on `AuthViewModel` for testability. |
| **Steps** | Simulate a `scenePhase` transition to `.background` by calling the handler that `.onChange(of: scenePhase)` invokes (e.g., `authViewModel.onAppBackgrounded()`). Read the overlay-visible property. |
| **Expected result** | `overlayIsVisible == true`. |

---

#### H4-U2: Overlay state is `false` when scenePhase transitions to .active

| Field | Value |
|-------|-------|
| **Name** | `test_privacyOverlay_givenScenePhaseActive_overlayIsHidden` |
| **Type** | Unit |
| **File** | `odooTests/PrivacyOverlayTests.swift` |
| **Setup** | Same as H4-U1. Transition first to `.background`, then to `.active`. |
| **Steps** | After transitioning to `.active`, read the overlay-visible property. |
| **Expected result** | `overlayIsVisible == false`. The overlay lifts when the user returns to the app. |

---

#### H4-U3: Overlay state is `true` when scenePhase transitions to .inactive

| Field | Value |
|-------|-------|
| **Name** | `test_privacyOverlay_givenScenePhaseInactive_overlayIsVisible` |
| **Type** | Unit |
| **File** | `odooTests/PrivacyOverlayTests.swift` |
| **Setup** | Same as H4-U1. |
| **Steps** | Simulate transition to `.inactive` (the phase that fires before `.background`, e.g., during Control Center swipe-up). Call whatever handler is wired to `.inactive`. |
| **Expected result** | `overlayIsVisible == true`. The overlay must appear before the system screenshot is taken, which happens during the inactive phase — not the background phase. |

**Critical implementation note:** The system screenshot is taken during `.inactive`, not `.background`. The overlay MUST be applied on `.inactive` to prevent leaking data in the task switcher. Tests H4-U1 and H4-U3 together verify both phases are handled.

---

#### H4-X1: Privacy overlay view is visible in task switcher (XCUITest)

| Field | Value |
|-------|-------|
| **Name** | `test_privacyOverlay_givenAppBackgrounded_overlayIsRendered` |
| **Type** | XCUITest |
| **File** | `odooUITests/PrivacyOverlayUITests.swift` (new) |
| **Setup** | Launch the app. Log in with test credentials or use a pre-seeded account via launch arguments. Navigate to the main WebView screen so sensitive content is visible. |
| **Steps** | 1. Take a baseline screenshot of the main screen with `XCUIScreen.main.screenshot()`. 2. Press Home button using `XCUIDevice.shared.press(.home)`. 3. Wait 1 second for the system to capture the snapshot. 4. Re-launch the app by tapping its icon via Springboard. 5. Take a screenshot of the app after returning to the foreground. |
| **Expected result** | The overlay is no longer visible after returning to foreground (foreground screenshot matches the main screen). **Limitation:** XCUITest cannot directly inspect the task switcher thumbnail; this test verifies (a) the app does not crash when backgrounded and (b) the overlay lifts on return. For full verification that the overlay blocks the screenshot, use manual testing with the iOS task switcher or a screenshot comparison tool against a known-blurred reference image. |

**Manual verification note:** After implementing H4, a developer must manually press the Home button and verify the task switcher shows the privacy overlay rather than the WebView content. Add this step to the simulator verification script `scripts/verify_all.py` as `iV-H4-manual`.

---

## H5: Theme Mode Applied to UI

### Fix Summary

`WoowTheme.setThemeMode(_:)` persists the user's choice to `SecureStorage` and publishes
`@Published var themeMode: ThemeMode = .system`, but no `.preferredColorScheme()` modifier
reads this value anywhere in the view hierarchy. The root `AppRootView` in `odooApp.swift`
does not apply the modifier.

The fix adds `.preferredColorScheme(woowTheme.colorScheme)` to the root view, where
`colorScheme` is a computed property that maps `ThemeMode.light` to
`ColorScheme.light`, `ThemeMode.dark` to `ColorScheme.dark`, and `ThemeMode.system`
to `nil` (letting SwiftUI follow the system default).

### Tests

---

#### H5-U1: setThemeMode(.dark) publishes themeMode as .dark

| Field | Value |
|-------|-------|
| **Name** | `test_setThemeMode_givenDark_publishesThemeModeAsDark` |
| **Type** | Unit |
| **File** | `odooTests/ThemeModeTests.swift` (new) |
| **Setup** | Instantiate a `WoowTheme()` with a stubbed `SettingsRepository` that returns `AppSettings()` (system default). Observe `themeMode` via Combine `sink` or by reading after the synchronous call. |
| **Steps** | Call `woowTheme.setThemeMode(.dark)`. Read `woowTheme.themeMode`. |
| **Expected result** | `woowTheme.themeMode == ThemeMode.dark`. |

---

#### H5-U2: setThemeMode(.light) publishes themeMode as .light

| Field | Value |
|-------|-------|
| **Name** | `test_setThemeMode_givenLight_publishesThemeModeAsLight` |
| **Type** | Unit |
| **File** | `odooTests/ThemeModeTests.swift` |
| **Setup** | Same as H5-U1. |
| **Steps** | Call `woowTheme.setThemeMode(.light)`. |
| **Expected result** | `woowTheme.themeMode == ThemeMode.light`. |

---

#### H5-U3: setThemeMode(.system) publishes themeMode as .system

| Field | Value |
|-------|-------|
| **Name** | `test_setThemeMode_givenSystem_publishesThemeModeAsSystem` |
| **Type** | Unit |
| **File** | `odooTests/ThemeModeTests.swift` |
| **Setup** | Same as H5-U1. Start from `.dark`, then switch back. |
| **Steps** | Call `woowTheme.setThemeMode(.dark)` then `woowTheme.setThemeMode(.system)`. |
| **Expected result** | `woowTheme.themeMode == ThemeMode.system`. |

---

#### H5-U4: colorScheme computed property returns correct ColorScheme for each ThemeMode

| Field | Value |
|-------|-------|
| **Name** | `test_colorScheme_givenDark_returnsColorSchemeDark` |
| **Type** | Unit |
| **File** | `odooTests/ThemeModeTests.swift` |
| **Setup** | This test targets the new computed property `WoowTheme.colorScheme: ColorScheme?`. |
| **Steps** | Set `woowTheme.themeMode = .dark`. Read `woowTheme.colorScheme`. Repeat for `.light` and `.system`. |
| **Expected result** | `.dark` → `ColorScheme.dark`, `.light` → `ColorScheme.light`, `.system` → `nil`. The `nil` return for `.system` is what `.preferredColorScheme(nil)` requires to defer to the system. |

---

#### H5-U5: SettingsViewModel.updateThemeMode delegates to WoowTheme and publishes new value

| Field | Value |
|-------|-------|
| **Name** | `test_updateThemeMode_givenDark_woowThemeReceivesDark` |
| **Type** | Unit |
| **File** | `odooTests/ThemeModeTests.swift` |
| **Setup** | Instantiate `SettingsViewModel`. Inject a mock or observable `WoowTheme` if the class supports injection; otherwise read `WoowTheme.shared.themeMode` after the call. The L7 audit note flags a dual-write path, so this test also guards against the ViewModel writing theme mode in a way that bypasses `WoowTheme`. |
| **Steps** | Call `settingsVM.updateThemeMode(.dark)` (or whatever the ViewModel method is named). |
| **Expected result** | `WoowTheme.shared.themeMode == .dark`. The published value changed. |

---

#### H5-X1: Selecting Dark mode in Settings renders the app in dark appearance (XCUITest)

| Field | Value |
|-------|-------|
| **Name** | `test_themeMode_givenUserSelectsDark_appRendersInDarkAppearance` |
| **Type** | XCUITest |
| **File** | `odooUITests/ThemeUITests.swift` (new) |
| **Setup** | Launch the app. Navigate to Settings. (This requires B4 — Config navigation — to be fixed first. If B4 is not yet fixed, skip this test and mark it as blocked.) |
| **Steps** | 1. Open Settings. 2. Tap the theme mode selector and choose "Dark". 3. Dismiss Settings and return to main screen. 4. Take a screenshot with `XCUIScreen.main.screenshot()`. |
| **Expected result** | The screenshot background color is dark (approximately dark gray or black). This can be verified by sampling the pixel color of a known background region, or by comparing against a reference screenshot. Use `XCTAttachment` to attach the screenshot for manual review if pixel comparison is unavailable. |

**Dependency note:** This XCUITest depends on H4 (navigation to Config/Settings must work, i.e., B4 must be fixed). Add a guard at the top of the test: if the Settings screen is unreachable, record an `XCTSkip` with reason "B4 Config navigation not yet implemented". Do not fail the test for a missing dependency.

---

## H6: Keychain Password Key Scoped to Server URL

### Fix Summary

`SecureStorage.savePassword(accountId:)` uses the key `"pwd_\(accountId)"` where
`accountId` is the username. If two accounts share the same username on different servers
(e.g., `admin` on `odoo1.example.com` and `admin` on `odoo2.example.com`), they use the
same Keychain key and the second `save` overwrites the first.

The fix changes the key format to `"pwd_\(serverUrl)_\(username)"`. A migration step must
also be added: on first launch after the update, existing `"pwd_\(username)"` keys are
read and re-saved under the new format, then the old keys are deleted.

The `AccountRepositoryProtocol` and all call sites (`authenticate`, `switchAccount`,
`logout`, `removeAccount`) must pass both `serverUrl` and `username` to `SecureStorage`.

### Tests

---

#### H6-U1: savePassword key includes serverUrl and username

| Field | Value |
|-------|-------|
| **Name** | `test_savePassword_givenServerUrlAndUsername_keyIncludesBoth` |
| **Type** | Unit |
| **File** | `odooTests/KeychainKeyScopingTests.swift` (new) |
| **Setup** | Use `MockSecureStorage` with an updated signature: `savePassword(serverUrl: String, accountId: String, password: String)`. Inspect `mockStorage.store` after saving. |
| **Steps** | Call `mockStorage.savePassword(serverUrl: "https://odoo.example.com", accountId: "admin", password: "secret")`. Inspect the keys of `mockStorage.store`. |
| **Expected result** | `mockStorage.store` contains a key matching `"pwd_https://odoo.example.com_admin"` (or whatever the new format is defined as — the exact separator must match the implementation). The old key `"pwd_admin"` must NOT be present. |

---

#### H6-U2: Two accounts — same username, different servers — store separate passwords

| Field | Value |
|-------|-------|
| **Name** | `test_savePassword_givenSameUsernameDifferentServers_storesSeparatePasswords` |
| **Type** | Unit |
| **File** | `odooTests/KeychainKeyScopingTests.swift` |
| **Setup** | Use `MockSecureStorage`. |
| **Steps** | 1. Call `savePassword(serverUrl: "https://odoo1.example.com", accountId: "admin", password: "pass1")`. 2. Call `savePassword(serverUrl: "https://odoo2.example.com", accountId: "admin", password: "pass2")`. 3. Call `getPassword(serverUrl: "https://odoo1.example.com", accountId: "admin")`. 4. Call `getPassword(serverUrl: "https://odoo2.example.com", accountId: "admin")`. |
| **Expected result** | Step 3 returns `"pass1"`. Step 4 returns `"pass2"`. The two entries are independent — saving `pass2` did not overwrite `pass1`. |

---

#### H6-U3: deletePassword removes only the matching server+username entry

| Field | Value |
|-------|-------|
| **Name** | `test_deletePassword_givenOneServer_doesNotDeleteOtherServer` |
| **Type** | Unit |
| **File** | `odooTests/KeychainKeyScopingTests.swift` |
| **Setup** | Pre-populate `MockSecureStorage` with two entries: `"https://odoo1.example.com" + "admin" = "pass1"` and `"https://odoo2.example.com" + "admin" = "pass2"`. |
| **Steps** | Call `deletePassword(serverUrl: "https://odoo1.example.com", accountId: "admin")`. Then call `getPassword(serverUrl: "https://odoo2.example.com", accountId: "admin")`. |
| **Expected result** | Returns `"pass2"`. Only the `odoo1` entry was deleted. |

---

#### H6-U4: Migration preserves password for existing single-server account

| Field | Value |
|-------|-------|
| **Name** | `test_migrateKeychain_givenLegacyKey_preservesPasswordUnderNewKey` |
| **Type** | Unit |
| **File** | `odooTests/KeychainKeyScopingTests.swift` |
| **Setup** | Write a legacy entry directly into `MockSecureStorage.store` as `"pwd_admin" = "legacy_pass"` (bypassing the new `savePassword` method). Create a `KeychainMigration` helper or call the migration function directly. Pass the list of existing accounts (with their `serverUrl` + `username`) to the migration function. |
| **Steps** | Run the migration. Then call `getPassword(serverUrl: "https://odoo.example.com", accountId: "admin")`. |
| **Expected result** | Returns `"legacy_pass"`. The migration read the old key, wrote the new scoped key, and the new `getPassword` finds it. |

---

#### H6-U5: Migration removes legacy key after migration completes

| Field | Value |
|-------|-------|
| **Name** | `test_migrateKeychain_givenLegacyKey_deletesOldKeyAfterMigration` |
| **Type** | Unit |
| **File** | `odooTests/KeychainKeyScopingTests.swift` |
| **Setup** | Same as H6-U4. |
| **Steps** | Run the migration. Inspect `mockStorage.store` directly for the old key `"pwd_admin"`. |
| **Expected result** | `mockStorage.store["pwd_admin"]` is `nil`. The legacy key is gone, preventing a dual-read path. |

---

#### H6-U6: AccountRepository.authenticate saves password with scoped key

| Field | Value |
|-------|-------|
| **Name** | `test_authenticate_givenSuccess_savesPasswordWithScopedKey` |
| **Type** | Unit |
| **File** | `odooTests/KeychainKeyScopingTests.swift` |
| **Setup** | Create a `MockSecureStorage` with the updated scoped API. Create a `MockOdooAPIClient` returning `.success`. Inject both into `AccountRepository`. |
| **Steps** | Call `await repo.authenticate(serverUrl: "odoo.example.com", database: "db", username: "admin", password: "secret")`. Inspect `mockSecureStorage.store`. |
| **Expected result** | The store contains a key incorporating both `"https://odoo.example.com"` and `"admin"`. The old `"pwd_admin"` format is absent. |

---

## Implementation Order and Dependencies

The tests in this plan can be written in the following order — cheapest first, avoiding
dependencies on unfinished fixes:

| Step | Tests | Dependency |
|------|-------|------------|
| 1 | H2-U1 through H2-U4 | None — validator is pure and already exists |
| 2 | H1-U1 through H1-U4 | Requires async signature change to protocol first |
| 3 | H6-U1 through H6-U6 | Requires `SecureStorage` API signature change |
| 4 | H5-U1 through H5-U5 | Requires `colorScheme` computed property on `WoowTheme` |
| 5 | H3-U1 through H3-U4 | Requires `SecureStorage.saveSessionId/getSessionId` additions |
| 6 | H4-U1 through H4-U3 | Requires privacy overlay state extraction from view |
| 7 | H2-U5, H2-U6 | Requires `handleNotificationTap` to accept injected server host |
| 8 | H4-X1 | Requires simulator + H4 implementation complete |
| 9 | H5-X1 | Requires simulator + B4 Config navigation complete |

---

## Test File Summary

| File | Tests | Fix |
|------|-------|-----|
| `odooTests/odooTests.swift` | H2-U1, H2-U2, H2-U3, H2-U4 (append to `DeepLinkValidatorTests`) | H2 |
| `odooTests/AppDelegateDeepLinkTests.swift` | H2-U5, H2-U6 | H2 |
| `odooTests/AccountRepositoryAsyncTests.swift` (new) | H1-U1, H1-U2, H1-U3, H1-U4 | H1 |
| `odooTests/SessionCookieStorageTests.swift` (new) | H3-U1, H3-U2, H3-U3, H3-U4 | H3 |
| `odooTests/PrivacyOverlayTests.swift` (new) | H4-U1, H4-U2, H4-U3 | H4 |
| `odooTests/ThemeModeTests.swift` (new) | H5-U1, H5-U2, H5-U3, H5-U4, H5-U5 | H5 |
| `odooTests/KeychainKeyScopingTests.swift` (new) | H6-U1, H6-U2, H6-U3, H6-U4, H6-U5, H6-U6 | H6 |
| `odooUITests/PrivacyOverlayUITests.swift` (new) | H4-X1 | H4 |
| `odooUITests/ThemeUITests.swift` (new) | H5-X1 | H5 |

**Total: 23 unit tests + 2 XCUITests = 25 tests**

---

## TestDoubles Required

The following additions to `odooTests/TestDoubles/TestDoubles.swift` are needed:

### MockSecureStorage — updated signature for H6

```swift
// Replace existing savePassword/getPassword/deletePassword with scoped versions:
func savePassword(serverUrl: String, accountId: String, password: String) {
    store["pwd_\(serverUrl)_\(accountId)"] = password
}

func getPassword(serverUrl: String, accountId: String) -> String? {
    store["pwd_\(serverUrl)_\(accountId)"]
}

func deletePassword(serverUrl: String, accountId: String) {
    store.removeValue(forKey: "pwd_\(serverUrl)_\(accountId)")
}
```

Note: The `SecureStorageProtocol` signature must change to include `serverUrl`. All
existing tests that use `MockSecureStorage` with the old signature must be updated.

### MockSecureStorage — session storage for H3

```swift
func saveSessionId(serverUrl: String, sessionId: String) {
    store["session_\(serverUrl)"] = sessionId
}

func getSessionId(serverUrl: String) -> String? {
    store["session_\(serverUrl)"]
}

func deleteSessionId(serverUrl: String) {
    store.removeValue(forKey: "session_\(serverUrl)")
}
```

### MockAccountRepository — async getSessionId for H1

```swift
// Update existing stub from synchronous to async:
func getSessionId(for serverUrl: String) async -> String? { nil }
```

---

## Naming Convention Reference

All test names in this document follow the project convention from `CLAUDE.md`:

```
test_{method}_given{Condition}_returns{Expected}
```

Examples from this plan:
- `test_getSessionId_givenMainActorCaller_completesWithoutDeadlock`
- `test_isValid_givenEmptyServerHost_rejectsAbsoluteUrl`
- `test_savePassword_givenSameUsernameDifferentServers_storesSeparatePasswords`
- `test_migrateKeychain_givenLegacyKey_preservesPasswordUnderNewKey`
