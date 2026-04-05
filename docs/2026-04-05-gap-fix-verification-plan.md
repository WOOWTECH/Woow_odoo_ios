# Gap Fix Verification Plan — P0 and P1 Gaps

**Date:** 2026-04-05
**Scope:** Unit tests and XCUITests for G3, G7, G9 (P0) and G8, G2 (P1)
**Gaps:** from `functional-equivalence-matrix.md` — Gap Prioritization table
**Test runner:** `xcodebuild -scheme odoo -destination "platform=iOS Simulator,name=iPhone 16" test`

---

## Conventions Used in This Document

- **Unit test** — XCTest class in `odooTests/`, runs in-process, no UI, fully deterministic.
- **XCUITest** — XCTest class in `odooUITests/`, drives a real app process via Accessibility.
- **Mock suffix** — A hand-written fake or MockK-style stub injected through the protocol parameter of the class under test.
- **Given_When_Then** — test function names follow `test_given<State>_when<Action>_then<Expectation>()`.
- All new unit test classes live in `odooTests/GapFixTests.swift` (one new file, one MARK per gap).
- All new XCUITest classes live in `odooUITests/GapFixUITests.swift` (one new file, one MARK per gap).

---

## G3 — `woowodoo://` URL Scheme Deep Link (P0)

**What is broken:** `DeepLinkValidator.isValid` is never called for `woowodoo://open?url=…` URLs.
The scheme is not registered in `Info.plist`, so iOS silently ignores the link.
`UX-75` maps to this gap.

### Unit Tests — class `DeepLinkValidatorWoowSchemeTests`

---

#### TEST-G3-U1

| Field | Value |
|-------|-------|
| **Test name** | `test_givenWoowSchemeUrl_whenUrlParamIsValidWebPath_thenValidatorAcceptsIt` |
| **Test class** | `DeepLinkValidatorWoowSchemeTests` (new, in `GapFixTests.swift`) |
| **Type** | Unit test |
| **Setup** | None — `DeepLinkValidator` is a stateless enum. `serverHost = "odoo.example.com"`. |
| **Input** | `woowodoo://open?url=/web%23id=42` (percent-encoded `#`) with same `serverHost` |
| **Expected result** | `DeepLinkValidator.isValidWoowScheme(url:serverHost:)` returns `true` and the extracted path `/web#id=42` passes the existing path validator. |
| **Failure mode caught** | Scheme extraction is missing or `%23` is not decoded before validation. |

```swift
func test_givenWoowSchemeUrl_whenUrlParamIsValidWebPath_thenValidatorAcceptsIt() {
    let raw = "woowodoo://open?url=/web%23id=42"
    XCTAssertTrue(
        DeepLinkValidator.isValidWoowScheme(url: raw, serverHost: "odoo.example.com"),
        "woowodoo:// with a safe /web#id= path must be accepted"
    )
}
```

---

#### TEST-G3-U2

| Field | Value |
|-------|-------|
| **Test name** | `test_givenWoowSchemeUrl_whenUrlParamContainsJavascript_thenValidatorRejectsIt` |
| **Test class** | `DeepLinkValidatorWoowSchemeTests` |
| **Type** | Unit test |
| **Setup** | None. `serverHost = "odoo.example.com"`. |
| **Input** | `woowodoo://open?url=javascript:alert(1)` |
| **Expected result** | `DeepLinkValidator.isValidWoowScheme(url:serverHost:)` returns `false`. The inner `url` param is still passed through `DeepLinkValidator.isValid` before acceptance. |
| **Failure mode caught** | The scheme handler skips the inner validation and loads a `javascript:` URI in the WebView. |

```swift
func test_givenWoowSchemeUrl_whenUrlParamContainsJavascript_thenValidatorRejectsIt() {
    let malicious = "woowodoo://open?url=javascript:alert(1)"
    XCTAssertFalse(
        DeepLinkValidator.isValidWoowScheme(url: malicious, serverHost: "odoo.example.com"),
        "woowodoo:// with javascript: inner URL must be rejected"
    )
}
```

---

#### TEST-G3-U3

| Field | Value |
|-------|-------|
| **Test name** | `test_givenWoowSchemeUrl_whenUrlParamIsPercentEncodedJavascript_thenValidatorRejectsIt` |
| **Test class** | `DeepLinkValidatorWoowSchemeTests` |
| **Type** | Unit test |
| **Setup** | None. `serverHost = "odoo.example.com"`. |
| **Input** | `woowodoo://open?url=javascript%3Aalert(1)` (percent-encoded colon) |
| **Expected result** | Returns `false`. Validates that the handler percent-decodes the `url` query param before delegating to `DeepLinkValidator.isValid`. |
| **Failure mode caught** | Percent-encoded bypass not caught — same class of bug already documented in `DeepLinkValidatorEdgeCaseTests.test_rejectPercentEncodedJavascript`. |

```swift
func test_givenWoowSchemeUrl_whenUrlParamIsPercentEncodedJavascript_thenValidatorRejectsIt() {
    let bypass = "woowodoo://open?url=javascript%3Aalert(1)"
    XCTAssertFalse(
        DeepLinkValidator.isValidWoowScheme(url: bypass, serverHost: "odoo.example.com"),
        "Percent-encoded javascript: must still be rejected after decoding"
    )
}
```

---

#### TEST-G3-U4

| Field | Value |
|-------|-------|
| **Test name** | `test_givenWoowSchemeUrl_whenUrlParamIsMissing_thenValidatorRejectsIt` |
| **Test class** | `DeepLinkValidatorWoowSchemeTests` |
| **Type** | Unit test |
| **Setup** | None. |
| **Input** | `woowodoo://open` (no `url=` query parameter) |
| **Expected result** | Returns `false`. A bare scheme with no navigation target is not actionable. |
| **Failure mode caught** | Missing parameter guard causes a force-unwrap crash or loads the app root unexpectedly. |

```swift
func test_givenWoowSchemeUrl_whenUrlParamIsMissing_thenValidatorRejectsIt() {
    XCTAssertFalse(
        DeepLinkValidator.isValidWoowScheme(url: "woowodoo://open", serverHost: "odoo.example.com"),
        "woowodoo:// with no url= param must be rejected"
    )
}
```

---

## G7 — Lock Screen Notification Privacy (P0)

**What is broken:** `NotificationService.buildContent` does not set a `categoryIdentifier`,
so iOS uses the default behaviour and shows full notification content on the lock screen.
`UX-45` requires `VISIBILITY_PRIVATE` parity — iOS equivalent is a registered `UNNotificationCategory`
with `hiddenPreviewsBodyPlaceholder`.

### Unit Tests — class `NotificationServicePrivacyTests`

---

#### TEST-G7-U1

| Field | Value |
|-------|-------|
| **Test name** | `test_givenValidPayload_whenBuildContent_thenCategoryIdentifierIsSet` |
| **Test class** | `NotificationServicePrivacyTests` (new, in `GapFixTests.swift`) |
| **Type** | Unit test |
| **Setup** | A minimal valid FCM `data` dict: `["title": "Alice", "body": "Please review SO-99"]`. |
| **Expected result** | `content.categoryIdentifier == "ODOO_PRIVATE"` (or the constant defined by the implementation). A non-empty category identifier is what triggers iOS to consult the registered category's `hiddenPreviewsBodyPlaceholder`. |
| **Failure mode caught** | Category identifier is never set — the current implementation gap (line 16–39 of `NotificationService.swift` sets no `categoryIdentifier`). |

```swift
func test_givenValidPayload_whenBuildContent_thenCategoryIdentifierIsSet() {
    let data = ["title": "Alice", "body": "Please review SO-99"]
    let content = NotificationService.buildContent(from: data)
    XCTAssertNotNil(content, "buildContent must return non-nil for valid payload")
    XCTAssertFalse(
        content!.categoryIdentifier.isEmpty,
        "categoryIdentifier must be set so iOS applies the privacy category"
    )
}
```

---

#### TEST-G7-U2

| Field | Value |
|-------|-------|
| **Test name** | `test_givenValidPayload_whenBuildContent_thenCategoryIdentifierMatchesRegisteredCategory` |
| **Test class** | `NotificationServicePrivacyTests` |
| **Type** | Unit test |
| **Setup** | Same minimal payload. `NotificationService` must expose the category identifier constant (e.g., `NotificationService.privateCategoryId`). |
| **Expected result** | `content.categoryIdentifier == NotificationService.privateCategoryId`. This pins the value so that a rename in one place does not silently break the other. |
| **Failure mode caught** | Category string mismatch between registration (in `AppDelegate`/`UNUserNotificationCenter`) and content builder. |

```swift
func test_givenValidPayload_whenBuildContent_thenCategoryIdentifierMatchesRegisteredCategory() {
    let data = ["title": "Alice", "body": "Please review SO-99"]
    let content = NotificationService.buildContent(from: data)!
    XCTAssertEqual(
        content.categoryIdentifier,
        NotificationService.privateCategoryId,
        "categoryIdentifier must match the constant used during UNNotificationCategory registration"
    )
}
```

---

#### TEST-G7-U3

| Field | Value |
|-------|-------|
| **Test name** | `test_givenPrivateCategoryRegistered_whenQueried_thenHiddenPreviewPlaceholderIsSet` |
| **Test class** | `NotificationServicePrivacyTests` |
| **Type** | Unit test |
| **Setup** | Call `NotificationService.registerCategories()` (or equivalent registration function). Then query `UNUserNotificationCenter.current()` for registered categories using an async expectation. |
| **Expected result** | The category with identifier `NotificationService.privateCategoryId` has a non-empty `hiddenPreviewsBodyPlaceholder`. This is the string shown on the lock screen instead of the message body. |
| **Failure mode caught** | Category is registered but `hiddenPreviewsBodyPlaceholder` is `nil` or empty — content is still visible on the lock screen. |

```swift
func test_givenPrivateCategoryRegistered_whenQueried_thenHiddenPreviewPlaceholderIsSet() async {
    NotificationService.registerCategories()
    let categories = await UNUserNotificationCenter.current().notificationCategories()
    let privateCategory = categories.first { $0.identifier == NotificationService.privateCategoryId }
    XCTAssertNotNil(privateCategory, "Privacy category must be registered")
    XCTAssertFalse(
        privateCategory!.hiddenPreviewsBodyPlaceholder?.isEmpty ?? true,
        "hiddenPreviewsBodyPlaceholder must be a non-empty string"
    )
}
```

---

#### TEST-G7-U4

| Field | Value |
|-------|-------|
| **Test name** | `test_givenMissingTitle_whenBuildContent_thenReturnsNil` |
| **Test class** | `NotificationServicePrivacyTests` |
| **Type** | Unit test |
| **Setup** | Payload with missing `title` key: `["body": "some message"]`. |
| **Expected result** | `buildContent` returns `nil`. Guard path is not broken by the new `categoryIdentifier` assignment. This is a regression guard for the existing behaviour. |
| **Failure mode caught** | Adding `categoryIdentifier` logic breaks the early-return guard. |

```swift
func test_givenMissingTitle_whenBuildContent_thenReturnsNil() {
    let content = NotificationService.buildContent(from: ["body": "some message"])
    XCTAssertNil(content, "Missing title must still return nil after privacy category changes")
}
```

---

## G9 — FCM Token Unregister on Logout (P0)

**What is broken:** `AccountRepository.logout` clears cookies and Keychain password but never
calls `PushTokenRepository.unregisterToken`. A logged-out user continues to receive push
notifications on the device. `UX-69` documents the required behaviour.

### Unit Tests — class `PushTokenUnregisterTests`

All tests use `MockPushTokenRepository` and `MockOdooAPIClient` (hand-written protocol fakes).

---

#### TEST-G9-U1

| Field | Value |
|-------|-------|
| **Test name** | `test_givenRegisteredToken_whenUnregisterToken_thenCallsOdooUnregisterEndpoint` |
| **Test class** | `PushTokenUnregisterTests` (new, in `GapFixTests.swift`) |
| **Type** | Unit test |
| **Setup** | `MockOdooAPIClient` records all `callKw` invocations. Inject into `PushTokenRepository`. Pre-store a token `"fcm-abc"` via `secureStorage`. One active account with `serverUrl = "https://odoo.example.com"`. |
| **Expected result** | After `pushTokenRepository.unregisterToken(for: account)` resolves, `mockApiClient.recordedCallKw` contains exactly one entry where `method == "unregister_device"` and `kwargs["fcm_token"] == "fcm-abc"`. |
| **Failure mode caught** | `unregisterToken` is not implemented — the method does not exist yet. |

```swift
func test_givenRegisteredToken_whenUnregisterToken_thenCallsOdooUnregisterEndpoint() async {
    let mockApi = MockOdooAPIClient()
    let storage = MockSecureStorage()
    storage.savedFcmToken = "fcm-abc"
    let account = OdooAccount(serverUrl: "https://odoo.example.com", database: "db",
                               username: "admin", displayName: "Admin")
    let repo = PushTokenRepository(secureStorage: storage,
                                   accountRepository: MockAccountRepository(accounts: [account]),
                                   apiClient: mockApi)

    await repo.unregisterToken(for: account)

    XCTAssertEqual(mockApi.recordedCallKwMethod, "unregister_device",
                   "Must call unregister_device on Odoo")
    XCTAssertEqual(mockApi.recordedCallKwKwargs["fcm_token"] as? String, "fcm-abc")
}
```

---

#### TEST-G9-U2

| Field | Value |
|-------|-------|
| **Test name** | `test_givenActiveAccount_whenLogout_thenUnregisterTokenIsCalled` |
| **Test class** | `PushTokenUnregisterTests` |
| **Type** | Unit test |
| **Setup** | `MockPushTokenRepository` with a `unregisterCallCount` counter. Inject into `AccountRepository`. One active account in an in-memory `PersistenceController`. |
| **Expected result** | After `await accountRepository.logout(accountId: nil)` resolves, `mockPushTokenRepository.unregisterCallCount == 1`. |
| **Failure mode caught** | `AccountRepository.logout` does not call `pushTokenRepository.unregisterToken` — the current implementation gap (line 109–124 of `AccountRepository.swift`). |

```swift
func test_givenActiveAccount_whenLogout_thenUnregisterTokenIsCalled() async {
    let mockPushRepo = MockPushTokenRepository()
    let persistence = PersistenceController(inMemory: true)
    // Seed one active account
    let context = persistence.container.viewContext
    let entity = OdooAccountEntity(context: context)
    entity.id = "acc-1"
    entity.serverUrl = "https://odoo.example.com"
    entity.database = "db"
    entity.username = "admin"
    entity.displayName = "Admin"
    entity.isActive = true
    entity.createdAt = Date()
    try? context.save()

    let repo = AccountRepository(persistence: persistence,
                                  secureStorage: MockSecureStorage(),
                                  apiClient: MockOdooAPIClient(),
                                  pushTokenRepository: mockPushRepo)

    await repo.logout(accountId: nil)

    XCTAssertEqual(mockPushRepo.unregisterCallCount, 1,
                   "logout must call unregisterToken exactly once")
}
```

---

#### TEST-G9-U3

| Field | Value |
|-------|-------|
| **Test name** | `test_givenRegisteredToken_whenUnregisterToken_thenFcmTokenClearedFromSecureStorage` |
| **Test class** | `PushTokenUnregisterTests` |
| **Type** | Unit test |
| **Setup** | `MockSecureStorage` that records `deleteFcmToken()` calls. `MockOdooAPIClient` succeeds silently. One account. |
| **Expected result** | After `await repo.unregisterToken(for: account)`, `mockStorage.fcmTokenDeleted == true`. |
| **Failure mode caught** | API call is made but the local FCM token is never deleted — a partial fix that still leaves the token readable by other code paths. |

```swift
func test_givenRegisteredToken_whenUnregisterToken_thenFcmTokenClearedFromSecureStorage() async {
    let mockStorage = MockSecureStorage()
    mockStorage.savedFcmToken = "fcm-xyz"
    let account = OdooAccount(serverUrl: "https://odoo.example.com", database: "db",
                               username: "admin", displayName: "Admin")
    let repo = PushTokenRepository(secureStorage: mockStorage,
                                   accountRepository: MockAccountRepository(accounts: [account]),
                                   apiClient: MockOdooAPIClient())

    await repo.unregisterToken(for: account)

    XCTAssertTrue(mockStorage.fcmTokenDeleted,
                  "FCM token must be deleted from SecureStorage after unregister")
    XCTAssertNil(mockStorage.savedFcmToken,
                 "getFcmToken must return nil after deletion")
}
```

---

#### TEST-G9-U4

| Field | Value |
|-------|-------|
| **Test name** | `test_givenApiFailure_whenUnregisterToken_thenTokenStillClearedLocally` |
| **Test class** | `PushTokenUnregisterTests` |
| **Type** | Unit test |
| **Setup** | `MockOdooAPIClient` throws a `URLError(.notConnectedToInternet)` for the `callKw` call. `MockSecureStorage` with pre-stored token. |
| **Expected result** | Despite the API error, `mockStorage.fcmTokenDeleted == true`. The local token must always be cleared on logout regardless of server reachability — the device is the authoritative store to clean. |
| **Failure mode caught** | `do { try await api.callKw(...) }` failure propagates and skips the local deletion. |

```swift
func test_givenApiFailure_whenUnregisterToken_thenTokenStillClearedLocally() async {
    let mockApi = MockOdooAPIClient()
    mockApi.callKwError = URLError(.notConnectedToInternet)
    let mockStorage = MockSecureStorage()
    mockStorage.savedFcmToken = "fcm-offline"
    let account = OdooAccount(serverUrl: "https://odoo.example.com", database: "db",
                               username: "admin", displayName: "Admin")
    let repo = PushTokenRepository(secureStorage: mockStorage,
                                   accountRepository: MockAccountRepository(accounts: [account]),
                                   apiClient: mockApi)

    await repo.unregisterToken(for: account)

    XCTAssertTrue(mockStorage.fcmTokenDeleted,
                  "Local FCM token must be cleared even when the server is unreachable")
}
```

---

## G8 — Account Switch Re-Authentication (P1)

**What is broken:** `AccountRepository.switchAccount(id:)` immediately sets the account active
and returns `true` without validating that the stored session cookie for that account is still
alive. A user switching to an account whose session expired gets a stale WebView loaded with a
login-redirect page. `UX-68` requires a session check first.

### Unit Tests — class `AccountSwitchReAuthTests`

---

#### TEST-G8-U1

| Field | Value |
|-------|-------|
| **Test name** | `test_givenExpiredSession_whenSwitchAccount_thenReturnsFalseWithSessionExpiredError` |
| **Test class** | `AccountSwitchReAuthTests` (new, in `GapFixTests.swift`) |
| **Type** | Unit test |
| **Setup** | `MockOdooAPIClient.validateSession(serverUrl:)` returns `.expired`. Two accounts in in-memory Core Data; account `"acc-2"` is the target. |
| **Expected result** | `await repo.switchAccount(id: "acc-2")` returns `false` and no account row has `isActive = true` for `"acc-2"` after the call. The method must not silently promote an account with a known-expired session. |
| **Failure mode caught** | The current `switchAccount` implementation (lines 98–107 of `AccountRepository.swift`) sets `isActive = true` unconditionally without any session check. |

```swift
func test_givenExpiredSession_whenSwitchAccount_thenReturnsFalseWithSessionExpiredError() async {
    let mockApi = MockOdooAPIClient()
    mockApi.sessionValidationResult = .expired
    let persistence = PersistenceController(inMemory: true)
    seedTwoAccounts(in: persistence, activeId: "acc-1", inactiveId: "acc-2")

    let repo = AccountRepository(persistence: persistence,
                                  secureStorage: MockSecureStorage(),
                                  apiClient: mockApi)

    let result = await repo.switchAccount(id: "acc-2")

    XCTAssertFalse(result, "switchAccount with expired session must return false")
    let active = repo.getActiveAccount()
    XCTAssertEqual(active?.id, "acc-1",
                   "Previously active account must remain active when switch fails")
}
```

---

#### TEST-G8-U2

| Field | Value |
|-------|-------|
| **Test name** | `test_givenValidSession_whenSwitchAccount_thenReturnsTrueAndActivatesAccount` |
| **Test class** | `AccountSwitchReAuthTests` |
| **Type** | Unit test |
| **Setup** | `MockOdooAPIClient.validateSession(serverUrl:)` returns `.valid`. Two accounts in Core Data. |
| **Expected result** | `await repo.switchAccount(id: "acc-2")` returns `true`, and `repo.getActiveAccount()?.id == "acc-2"`. |
| **Failure mode caught** | Over-zealous implementation that rejects all switches, or incorrect account activation logic. |

```swift
func test_givenValidSession_whenSwitchAccount_thenReturnsTrueAndActivatesAccount() async {
    let mockApi = MockOdooAPIClient()
    mockApi.sessionValidationResult = .valid
    let persistence = PersistenceController(inMemory: true)
    seedTwoAccounts(in: persistence, activeId: "acc-1", inactiveId: "acc-2")

    let repo = AccountRepository(persistence: persistence,
                                  secureStorage: MockSecureStorage(),
                                  apiClient: mockApi)

    let result = await repo.switchAccount(id: "acc-2")

    XCTAssertTrue(result, "switchAccount with valid session must return true")
    XCTAssertEqual(repo.getActiveAccount()?.id, "acc-2")
}
```

---

#### TEST-G8-U3

| Field | Value |
|-------|-------|
| **Test name** | `test_givenNetworkError_whenSwitchAccount_thenReturnsFalseWithoutChangingActiveAccount` |
| **Test class** | `AccountSwitchReAuthTests` |
| **Type** | Unit test |
| **Setup** | `MockOdooAPIClient.validateSession(serverUrl:)` throws `URLError(.notConnectedToInternet)`. |
| **Expected result** | `await repo.switchAccount(id: "acc-2")` returns `false`. No account activation change occurs. Offline behaviour must be safe — do not let users into a potentially stale account when network state is unknown. |
| **Failure mode caught** | Network error is swallowed and treated as a valid session. |

```swift
func test_givenNetworkError_whenSwitchAccount_thenReturnsFalseWithoutChangingActiveAccount() async {
    let mockApi = MockOdooAPIClient()
    mockApi.sessionValidationError = URLError(.notConnectedToInternet)
    let persistence = PersistenceController(inMemory: true)
    seedTwoAccounts(in: persistence, activeId: "acc-1", inactiveId: "acc-2")

    let repo = AccountRepository(persistence: persistence,
                                  secureStorage: MockSecureStorage(),
                                  apiClient: mockApi)

    let result = await repo.switchAccount(id: "acc-2")

    XCTAssertFalse(result, "Network error during session check must cause switchAccount to fail")
    XCTAssertEqual(repo.getActiveAccount()?.id, "acc-1")
}
```

---

## G2 — PIN Setup Wired in Settings (P1)

**What is broken:** The `SettingsView` renders a `HStack` label for "PIN Code" but wraps it in
nothing tappable — no `Button`, no `.onTapGesture`, no sheet presentation. Tapping "Set PIN" /
"Change PIN" does nothing. `UX-56` requires the full PIN setup flow to be reachable from Settings.

### Unit Tests — class `SettingsViewModelPinTests`

---

#### TEST-G2-U1

| Field | Value |
|-------|-------|
| **Test name** | `test_givenValidPin_whenSetPin_thenStoredHashMatchesInputPin` |
| **Test class** | `SettingsViewModelPinTests` (new, in `GapFixTests.swift`) |
| **Type** | Unit test |
| **Setup** | `MockSettingsRepository` that delegates `setPin`/`verifyPin` to the real `PinHasher` (no mocking of hashing — we want to verify the full chain). Inject into `SettingsViewModel`. |
| **Expected result** | `viewModel.setPin("123456")` returns `true`, and a subsequent call to `mockRepo.verifyPin("123456")` returns `true`. The stored hash is PBKDF2 (salt:hash format, contains `:`). |
| **Failure mode caught** | `SettingsViewModel.setPin` exists (`SettingsViewModel.swift` line 49) but `SettingsView` never calls it — this unit test verifies the ViewModel layer works correctly before the UI wiring is added. |

```swift
@MainActor
func test_givenValidPin_whenSetPin_thenStoredHashMatchesInputPin() {
    let mockRepo = SpySettingsRepository()
    let vm = SettingsViewModel(settingsRepo: mockRepo,
                               cacheService: MockCacheService(),
                               theme: MockWoowTheme())

    let result = vm.setPin("123456")

    XCTAssertTrue(result, "setPin must return true for a 6-digit PIN")
    XCTAssertTrue(mockRepo.verifyPin("123456"),
                  "Stored hash must verify correctly against the original PIN")
    XCTAssertTrue(mockRepo.capturedPinHash?.contains(":") ?? false,
                  "Hash must be in PBKDF2 salt:hash format")
}
```

---

#### TEST-G2-U2

| Field | Value |
|-------|-------|
| **Test name** | `test_givenTooShortPin_whenSetPin_thenReturnsFalseAndHashNotStored` |
| **Test class** | `SettingsViewModelPinTests` |
| **Type** | Unit test |
| **Setup** | `SpySettingsRepository` (real `setPin` logic). Inject into `SettingsViewModel`. |
| **Expected result** | `viewModel.setPin("12")` returns `false`. `mockRepo.capturedPinHash` is `nil`. Settings `pinEnabled` remains `false`. |
| **Failure mode caught** | PIN length validation missing in the ViewModel — relies solely on the repo guard but UI could call with any input. |

```swift
@MainActor
func test_givenTooShortPin_whenSetPin_thenReturnsFalseAndHashNotStored() {
    let mockRepo = SpySettingsRepository()
    let vm = SettingsViewModel(settingsRepo: mockRepo,
                               cacheService: MockCacheService(),
                               theme: MockWoowTheme())

    let result = vm.setPin("12")

    XCTAssertFalse(result, "setPin must return false for a PIN shorter than 4 digits")
    XCTAssertNil(mockRepo.capturedPinHash, "No hash must be stored for an invalid PIN")
}
```

---

#### TEST-G2-U3

| Field | Value |
|-------|-------|
| **Test name** | `test_givenPinAlreadySet_whenSetPin_thenSettingsReflectsPinEnabled` |
| **Test class** | `SettingsViewModelPinTests` |
| **Type** | Unit test |
| **Setup** | `SpySettingsRepository`. `SettingsViewModel` injected with it. |
| **Expected result** | After `viewModel.setPin("4321")`, `viewModel.settings.pinEnabled == true`. The `@Published settings` property is updated by the ViewModel so the UI toggle state is driven reactively. |
| **Failure mode caught** | `SettingsViewModel.setPin` (line 50–52) calls `settingsRepo.getSettings()` to refresh — this test pins that the published state is in sync after the call. |

```swift
@MainActor
func test_givenPinAlreadySet_whenSetPin_thenSettingsReflectsPinEnabled() {
    let mockRepo = SpySettingsRepository()
    let vm = SettingsViewModel(settingsRepo: mockRepo,
                               cacheService: MockCacheService(),
                               theme: MockWoowTheme())

    _ = vm.setPin("4321")

    XCTAssertTrue(vm.settings.pinEnabled,
                  "settings.pinEnabled must be true after successful setPin")
    XCTAssertNotNil(vm.settings.pinHash,
                    "settings.pinHash must be non-nil after setPin")
}
```

---

### XCUITests — class `G2_PINSetupFromSettingsUITests`

All XCUITests require the app to be in a logged-in state. Use `app.launchArguments = ["--uitesting-skip-auth", "--uitesting-logged-in"]` launch args (pattern already used by existing UI test helpers).

---

#### TEST-G2-E1

| Field | Value |
|-------|-------|
| **Test name** | `test_givenSettings_whenTapPinCode_thenPINSetupViewAppears` |
| **Test class** | `G2_PINSetupFromSettingsUITests` (new, in `GapFixUITests.swift`) |
| **Type** | XCUITest |
| **Setup** | App launched logged-in. App Lock toggle enabled (requirement: PIN row is only visible when `appLockEnabled == true`). Navigate: menu button → Settings. |
| **Expected result** | Tapping the "PIN Code" row presents a view with `staticTexts["Set PIN"]` or `staticTexts["Enter new PIN"]` and the numeric PIN pad buttons `"1"` through `"9"` and `"0"`. |
| **Failure mode caught** | The current `SettingsView` has an `HStack` label with no tap action — the test will time out on `waitForExistence`. |

```swift
@MainActor
func test_givenSettings_whenTapPinCode_thenPINSetupViewAppears() {
    app.launchArguments = ["--uitesting-logged-in", "--uitesting-app-lock-enabled"]
    app.launch()

    navigateToSettings()
    app.cells["PIN Code"].tap()  // or: app.buttons["Set PIN"]

    XCTAssertTrue(
        app.staticTexts["Set PIN"].waitForExistence(timeout: 3) ||
        app.staticTexts["Enter new PIN"].waitForExistence(timeout: 3),
        "PIN setup view must appear after tapping PIN Code in Settings"
    )
    XCTAssertTrue(app.buttons["1"].exists, "PIN numpad must be visible")
}
```

---

#### TEST-G2-E2

| Field | Value |
|-------|-------|
| **Test name** | `test_givenPINSetupView_whenEnter6DigitPinAndConfirm_thenPINSavedAndSettingsShowsChangePIN` |
| **Test class** | `G2_PINSetupFromSettingsUITests` |
| **Type** | XCUITest |
| **Setup** | App launched with no PIN set (`--uitesting-app-lock-enabled`, no `--uitesting-pin-set`). Navigate to Settings → tap PIN Code. |
| **Expected result** | Enter `"1"`, `"2"`, `"3"`, `"4"`, `"5"`, `"6"` on the numpad. Confirmation step appears. Enter the same six digits again. On return to Settings, the PIN Code row label changes to `"Change PIN"` (not `"Set PIN"`). |
| **Failure mode caught** | The setup flow is presented but the confirm step is missing, or the ViewModel is not called, so the setting is not persisted. |

```swift
@MainActor
func test_givenPINSetupView_whenEnter6DigitPinAndConfirm_thenPINSavedAndSettingsShowsChangePIN() {
    app.launchArguments = ["--uitesting-logged-in", "--uitesting-app-lock-enabled"]
    app.launch()

    navigateToSettings()
    app.cells["PIN Code"].tap()

    enterPINOnNumpad("123456")
    // Confirmation step
    XCTAssertTrue(app.staticTexts["Confirm PIN"].waitForExistence(timeout: 2),
                  "Confirmation step must appear after first entry")
    enterPINOnNumpad("123456")

    // Return to Settings
    XCTAssertTrue(app.staticTexts["Change PIN"].waitForExistence(timeout: 3),
                  "Settings must show 'Change PIN' once a PIN is saved")
}
```

---

#### TEST-G2-E3

| Field | Value |
|-------|-------|
| **Test name** | `test_givenPINSet_whenChangePIN_thenOldPINVerifiedBeforeNewPINAccepted` |
| **Test class** | `G2_PINSetupFromSettingsUITests` |
| **Type** | XCUITest |
| **Setup** | App launched with a PIN already set via launch argument `--uitesting-pin-hash=<PBKDF2 of 654321>`. Navigate to Settings → tap "Change PIN". |
| **Expected result** | The flow first shows `"Enter current PIN"`. Enter `"654321"`. Then `"Enter new PIN"` appears. Enter `"111111"` twice. On return to Settings, the label still reads `"Change PIN"` (PIN remains set, just updated). |
| **Failure mode caught** | Change PIN flow skips old PIN verification — a security regression. |

```swift
@MainActor
func test_givenPINSet_whenChangePIN_thenOldPINVerifiedBeforeNewPINAccepted() {
    app.launchArguments = [
        "--uitesting-logged-in",
        "--uitesting-app-lock-enabled",
        "--uitesting-pin-set"     // seeds a known PIN (654321) via AppDelegate launch arg handler
    ]
    app.launch()

    navigateToSettings()
    app.cells["PIN Code"].tap()

    // Must first verify the existing PIN
    XCTAssertTrue(app.staticTexts["Enter current PIN"].waitForExistence(timeout: 3),
                  "Change PIN flow must ask for the current PIN first")
    enterPINOnNumpad("654321")

    // Now set the new PIN
    XCTAssertTrue(app.staticTexts["Enter new PIN"].waitForExistence(timeout: 2))
    enterPINOnNumpad("111111")
    XCTAssertTrue(app.staticTexts["Confirm PIN"].waitForExistence(timeout: 2))
    enterPINOnNumpad("111111")

    XCTAssertTrue(app.staticTexts["Change PIN"].waitForExistence(timeout: 3),
                  "PIN Code row must still show 'Change PIN' after successful change")
}
```

---

#### TEST-G2-E4

| Field | Value |
|-------|-------|
| **Test name** | `test_givenPINSetupView_whenConfirmPINMismatch_thenErrorShownAndPINNotSaved` |
| **Test class** | `G2_PINSetupFromSettingsUITests` |
| **Type** | XCUITest |
| **Setup** | App launched with no PIN set. Navigate to Settings → tap PIN Code. |
| **Expected result** | Enter `"123456"` then `"999999"` at the confirmation step. An error message such as `"PINs do not match"` appears. On return to Settings, the row still reads `"Set PIN"` (no PIN was saved). |
| **Failure mode caught** | Mismatch on confirm is ignored and the first entry is saved — a usability and security bug. |

```swift
@MainActor
func test_givenPINSetupView_whenConfirmPINMismatch_thenErrorShownAndPINNotSaved() {
    app.launchArguments = ["--uitesting-logged-in", "--uitesting-app-lock-enabled"]
    app.launch()

    navigateToSettings()
    app.cells["PIN Code"].tap()

    enterPINOnNumpad("123456")
    XCTAssertTrue(app.staticTexts["Confirm PIN"].waitForExistence(timeout: 2))
    enterPINOnNumpad("999999")  // intentional mismatch

    XCTAssertTrue(
        app.staticTexts["PINs do not match"].waitForExistence(timeout: 2) ||
        app.staticTexts["PIN mismatch"].waitForExistence(timeout: 2),
        "An error message must appear when the confirmation PIN does not match"
    )

    // Navigate back and confirm Settings still shows "Set PIN"
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Set PIN"].waitForExistence(timeout: 2),
                  "PIN must not be saved after a mismatch")
}
```

---

## Shared Test Infrastructure Required

The tests above require the following test doubles that do not yet exist in `odooTests/` or
`:testing-unit`. Create them in `odooTests/TestDoubles/` alongside the gap fix test files.

### `MockSecureStorage`

Conforms to a `SecureStorageProtocol` (extract the interface from `SecureStorage` for testability).
Must record:
- `savedFcmToken: String?` — value stored by `saveFcmToken`
- `fcmTokenDeleted: Bool` — set to `true` by `deleteFcmToken`
- `savedSettings: AppSettings?`

### `MockOdooAPIClient`

Record-and-replay stub. Must support:
- `callKwError: Error?` — if set, `callKw` throws it
- `recordedCallKwMethod: String?`, `recordedCallKwKwargs: [String: Any]`
- `sessionValidationResult: SessionValidationResult` (add `.valid`, `.expired` cases)
- `sessionValidationError: Error?`

### `MockPushTokenRepository`

Conforms to `PushTokenRepositoryProtocol` plus the new `unregisterToken(for:)` method.
Must record:
- `unregisterCallCount: Int`
- `lastUnregisteredAccount: OdooAccount?`

### `MockAccountRepository`

Conforms to `AccountRepositoryProtocol`. Initialised with a fixed `[OdooAccount]` array.

### `SpySettingsRepository`

Wraps the real `SettingsRepository` with in-memory `MockSecureStorage`. Exposes:
- `capturedPinHash: String?` — the last `pinHash` saved

### `MockCacheService` and `MockWoowTheme`

Minimal no-op implementations for `SettingsViewModel` constructor injection.

### XCUITest launch argument handlers

Add to `AppDelegate` (or `App.init` for SwiftUI lifecycle) a block that reads `CommandLine.arguments` for:
- `--uitesting-logged-in` — seeds a fake active account in the in-memory store
- `--uitesting-app-lock-enabled` — seeds `AppSettings.appLockEnabled = true`
- `--uitesting-pin-set` — seeds a known PIN hash (`PinHasher.hash(pin: "654321")`)
- `--uitesting-skip-auth` — bypasses `AppLockView` gate

This pattern matches the existing `TestConfig` `ProcessInfo.processInfo.environment` approach in `odooUITests.swift`.

---

## XCUITest Helper Methods (add to `GapFixUITests.swift`)

```swift
private func navigateToSettings() {
    let menuButton = app.buttons["line.3.horizontal"]
    if menuButton.waitForExistence(timeout: 3) {
        menuButton.tap()
    }
    let settingsLabel = app.staticTexts["Settings"]
    if settingsLabel.waitForExistence(timeout: 2) {
        settingsLabel.tap()
    }
}

private func enterPINOnNumpad(_ digits: String) {
    for char in digits {
        app.buttons[String(char)].tap()
    }
}
```

---

## Test Count Summary

| Gap | Priority | Unit Tests | XCUITests | Total |
|-----|----------|-----------|-----------|-------|
| G3 — woowodoo:// URL scheme | P0 | 4 | 0 | 4 |
| G7 — Lock screen notification privacy | P0 | 4 | 0 | 4 |
| G9 — FCM token unregister on logout | P0 | 4 | 0 | 4 |
| G8 — Account switch re-authentication | P1 | 3 | 0 | 3 |
| G2 — PIN setup wired in Settings | P1 | 3 | 4 | 7 |
| **Total** | | **18** | **4** | **22** |

---

## Traceability Matrix

| Test ID | UX Item | Gap | Priority | Pass Criteria |
|---------|---------|-----|----------|---------------|
| TEST-G3-U1 | UX-75 | G3 | P0 | `isValidWoowScheme` accepts safe path |
| TEST-G3-U2 | UX-75 | G3 | P0 | `isValidWoowScheme` rejects `javascript:` |
| TEST-G3-U3 | UX-75 | G3 | P0 | Percent-encoded bypass rejected |
| TEST-G3-U4 | UX-75 | G3 | P0 | Missing `url=` param rejected |
| TEST-G7-U1 | UX-45 | G7 | P0 | `categoryIdentifier` non-empty |
| TEST-G7-U2 | UX-45 | G7 | P0 | `categoryIdentifier` matches constant |
| TEST-G7-U3 | UX-45 | G7 | P0 | Category registered with placeholder |
| TEST-G7-U4 | UX-45 | G7 | P0 | Regression: missing title still returns nil |
| TEST-G9-U1 | UX-69 | G9 | P0 | `unregisterToken` calls Odoo endpoint |
| TEST-G9-U2 | UX-69 | G9 | P0 | `logout` calls `unregisterToken` |
| TEST-G9-U3 | UX-69 | G9 | P0 | Token cleared from SecureStorage |
| TEST-G9-U4 | UX-69 | G9 | P0 | Token cleared even on API failure |
| TEST-G8-U1 | UX-68 | G8 | P1 | Expired session → `switchAccount` returns false |
| TEST-G8-U2 | UX-68 | G8 | P1 | Valid session → `switchAccount` returns true |
| TEST-G8-U3 | UX-68 | G8 | P1 | Network error → `switchAccount` returns false |
| TEST-G2-U1 | UX-56 | G2 | P1 | `setPin` stores PBKDF2 hash |
| TEST-G2-U2 | UX-56 | G2 | P1 | Short PIN rejected by ViewModel |
| TEST-G2-U3 | UX-56 | G2 | P1 | `settings.pinEnabled` reflects stored state |
| TEST-G2-E1 | UX-56 | G2 | P1 | Settings → PIN Code → setup view appears |
| TEST-G2-E2 | UX-56 | G2 | P1 | 6-digit PIN entry + confirm → label changes |
| TEST-G2-E3 | UX-22/23 | G2 | P1 | Change PIN verifies old PIN first |
| TEST-G2-E4 | UX-56 | G2 | P1 | Confirm mismatch shows error, no save |
