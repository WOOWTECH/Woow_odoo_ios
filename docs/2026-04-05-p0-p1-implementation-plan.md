# P0 & P1 Gap Fix Implementation Plan

> **Date:** 2026-04-05
> **Scope:** G3, G7, G9 (P0 -- App Store blockers) and G8, G2 (P1 -- public beta blockers)
> **Total Estimated Effort:** ~11.5 hours
> **Dependency Order:** G3 -> G7 -> G9 -> G8 -> G2

---

## P0-1: G3 -- Register `woowodoo://` URL Scheme (0.5h)

**Gap:** `woowodoo://open` deep links silently fail because `CFBundleURLTypes` is missing from `Info.plist` (UX-75).

### Files to Modify

| File | Action |
|------|--------|
| `odoo/Info.plist` | Add `CFBundleURLTypes` array |
| `odoo/odooApp.swift` | Add `.onOpenURL` handler to `WindowGroup` |

### Changes

#### 1. `odoo/Info.plist`

Add a `CFBundleURLTypes` entry inside the top-level `<dict>`. The new block goes after the existing `UIBackgroundModes` entry:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>io.woowtech.odoo</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>woowodoo</string>
        </array>
    </dict>
</array>
```

This registers the `woowodoo://` scheme with iOS so the system routes these URLs to the app.

#### 2. `odoo/odooApp.swift`

In the `odooApp` struct, add an `.onOpenURL` modifier to `WindowGroup` that validates and routes the incoming URL:

```swift
WindowGroup {
    AppRootView()
        .onOpenURL { url in
            handleIncomingURL(url)
        }
}
```

Add a private function `handleIncomingURL(_:)` to `odooApp` that:
1. Checks `url.scheme == "woowodoo"`
2. Extracts the path and query parameters (e.g., `woowodoo://open?path=/web%23id=42&model=sale.order`)
3. Runs the extracted path through `DeepLinkValidator.isValid(url:serverHost:)` -- the validator already accepts relative `/web` paths
4. If valid, calls `DeepLinkManager.shared.setPending(path)` to queue it for consumption after auth

No new files are needed. The existing `DeepLinkManager` and `DeepLinkValidator` handle persistence and security.

### Dependencies

None. This is the first task and is self-contained.

### Tests

- Unit test: call `handleIncomingURL` with `woowodoo://open?path=/web%23id=42` and assert `DeepLinkManager.shared.pendingUrl` is set
- Unit test: call with `woowodoo://open?path=javascript:alert(1)` and assert `pendingUrl` is nil (validator rejects it)
- Manual: tap a `woowodoo://open` link from Notes app and verify the app launches

### Commit Message

```
fix(deeplink): register woowodoo:// URL scheme in Info.plist (G3)

Add CFBundleURLTypes to Info.plist and .onOpenURL handler in odooApp.
Incoming URLs are validated through DeepLinkValidator before being
queued in DeepLinkManager for consumption after authentication.

Closes UX-75.
```

---

## P0-2: G7 -- Lock Screen Notification Privacy (1h)

**Gap:** Push notifications display full Odoo content (sender name, message body) on the lock screen. Android uses `VISIBILITY_PRIVATE`; iOS needs `hiddenPreviewsDeclaration` (UX-45).

### Files to Modify

| File | Action |
|------|--------|
| `odoo/App/AppDelegate.swift` | Register `UNNotificationCategory` with `hiddenPreviewsBodyPlaceholder` |
| `odoo/Data/Push/NotificationService.swift` | Assign the category to every notification content |

### Changes

#### 1. `odoo/App/AppDelegate.swift`

In `application(_:didFinishLaunchingWithOptions:)`, after requesting authorization and before `registerForRemoteNotifications()`, register a notification category that controls lock screen visibility:

```swift
let odooCategory = UNNotificationCategory(
    identifier: "odoo_message",
    actions: [],
    intentIdentifiers: [],
    hiddenPreviewsBodyPlaceholder: "New Odoo notification",
    options: []
)
UNUserNotificationCenter.current().setNotificationCategories([odooCategory])
```

The `hiddenPreviewsBodyPlaceholder` string is displayed on the lock screen when the user has "Show Previews: When Unlocked" enabled in iOS Settings > Notifications. This is the iOS equivalent of Android's `VISIBILITY_PRIVATE`.

The placeholder text "New Odoo notification" reveals no business data -- just that a notification arrived.

#### 2. `odoo/Data/Push/NotificationService.swift`

In `buildContent(from:)`, after setting `content.threadIdentifier`, add:

```swift
content.categoryIdentifier = "odoo_message"
```

This links every notification to the registered category so the privacy placeholder applies.

### How iOS Notification Privacy Works

iOS notification privacy is a two-layer system:

1. **System-level:** The user controls "Show Previews" in iOS Settings > Notifications (Always / When Unlocked / Never). When set to "When Unlocked" or "Never", the system hides the notification body on the lock screen.

2. **App-level:** By registering a `UNNotificationCategory` with `hiddenPreviewsBodyPlaceholder`, the app provides a safe replacement string that is shown when previews are hidden. Without this registration, iOS shows a generic "Notification" text.

There is **no per-notification API** to force hiding on iOS (unlike Android's `VISIBILITY_PRIVATE`). The system respects the user's global or per-app notification privacy setting. Our job is to ensure a meaningful placeholder is ready.

### Dependencies

None. Independent of G3.

### Tests

- Unit test: verify `buildContent(from:)` returns content with `categoryIdentifier == "odoo_message"`
- Manual: set iOS notification preview to "When Unlocked", lock device, send a test push, verify the lock screen shows "New Odoo notification" instead of message body

### Commit Message

```
fix(notifications): add lock screen privacy placeholder (G7)

Register UNNotificationCategory with hiddenPreviewsBodyPlaceholder
so that notification content is hidden on the lock screen when the
user has "Show Previews: When Unlocked" enabled. Assign the category
to all Odoo notifications via categoryIdentifier.

Closes UX-45.
```

---

## P0-3: G9 -- FCM Token Unregister on Logout (3h)

**Gap:** When a user logs out, the FCM token remains registered on the Odoo server. The logged-out user continues receiving push notifications for that account. Android has `FcmTokenRepository.unregisterToken()` but iOS `PushTokenRepository` lacks it (UX-69).

### Android Reference

`FcmTokenRepositoryImpl.kt` defines `unregisterToken(accountId)` which calls `/woow_fcm_push/unregister` (currently stubbed with TODO). The Android `AccountRepository.logout()` does **not** call unregister itself -- it is called by the ViewModel/UseCase layer. However, for iOS we will integrate it directly into the logout flow for simplicity, matching the pattern where `AccountRepository.logout()` is the single cleanup point.

### Files to Modify

| File | Action |
|------|--------|
| `odoo/Data/Push/PushTokenRepository.swift` | Add `unregisterToken(account:)` method to protocol and implementation |
| `odoo/Data/Repository/AccountRepository.swift` | Call `pushTokenRepo.unregisterToken()` inside `logout()` and `removeAccount()` |
| `odoo/Data/Storage/SecureStorage.swift` | Add `deleteFcmToken()` method |

### Changes

#### 1. `odoo/Data/Push/PushTokenRepository.swift`

**Protocol:** Add to `PushTokenRepositoryProtocol`:

```swift
func unregisterToken(for account: OdooAccount) async
func clearLocalToken()
```

**Implementation:** Add to `PushTokenRepository`:

`unregisterToken(for:)`:
1. Read the stored FCM token via `secureStorage.getFcmToken()`
2. If nil, return early (nothing to unregister)
3. Call `apiClient.callKw(serverUrl: account.fullServerUrl, model: "woow.fcm.device", method: "unregister_device", args: [], kwargs: ["fcm_token": token, "platform": "ios"])`
4. Wrap in do/catch -- log errors with `#if DEBUG print(...)` but do not throw. Unregister is best-effort; a failed unregister must not block logout.

`clearLocalToken()`:
1. Call `secureStorage.deleteFcmToken()` to remove the token from Keychain
2. This is called only when the **last** account is logged out (no remaining accounts). If other accounts remain, the token stays because those accounts still need it.

#### 2. `odoo/Data/Storage/SecureStorage.swift`

Add a `deleteFcmToken()` method:

```swift
func deleteFcmToken() {
    delete(key: "fcm_token")
}
```

This is a one-line addition following the existing pattern of `saveFcmToken` / `getFcmToken`.

#### 3. `odoo/Data/Repository/AccountRepository.swift`

**Constructor change:** Add `pushTokenRepository: PushTokenRepositoryProtocol` as a dependency. Default to `PushTokenRepository()` in the initializer for backward compatibility.

**`logout(accountId:)` change:** Before the existing `context.delete(account)` line, add:

```swift
// Unregister FCM token from this account's server (G9 security fix)
let domainAccount = account.toDomainModel()
await pushTokenRepository.unregisterToken(for: domainAccount)

// If this was the last account, clear local FCM token entirely
let remainingCount = (try? context.count(for: OdooAccountEntity.fetchAllRequest())) ?? 0
if remainingCount <= 1 {
    pushTokenRepository.clearLocalToken()
}
```

**`removeAccount(id:)` change:** Apply the same pattern -- unregister before deletion, clear token if last account.

### Data Flow

```
User taps Logout
    -> AccountRepository.logout()
        -> pushTokenRepo.unregisterToken(for: account)
            -> POST /web/dataset/call_kw { model: "woow.fcm.device", method: "unregister_device", ... }
            -> (best-effort, errors logged but not thrown)
        -> apiClient.clearCookies(for: serverUrl)
        -> secureStorage.deletePassword(accountId:)
        -> context.delete(account)
        -> if lastAccount: pushTokenRepo.clearLocalToken()
```

### Dependencies

None. Independent of G3 and G7. However, completing G7 before G9 is recommended because G7 is simpler and touching similar notification files.

### Tests

- **Unit test `PushTokenRepository`:** Mock `OdooAPIClient` and `SecureStorage`. Call `unregisterToken(for:)`. Assert `callKw` was called with correct model/method/kwargs. Assert `deleteFcmToken` is NOT called (because only `clearLocalToken` does that).
- **Unit test `PushTokenRepository`:** Call `clearLocalToken()`. Assert `secureStorage.deleteFcmToken()` was called.
- **Unit test `AccountRepository`:** Mock `PushTokenRepository`. Call `logout()`. Assert `unregisterToken(for:)` was called with the correct account. Assert FCM token is cleared when it is the last account.
- **Unit test `AccountRepository`:** With 2 accounts, log out of one. Assert `unregisterToken` was called but `clearLocalToken` was NOT called (other account still needs the token).
- **Manual E2E:** Log in, trigger a notification, log out, trigger the same event -- verify no notification arrives.

### Commit Message

```
fix(push): unregister FCM token on logout (G9)

Add unregisterToken(for:) to PushTokenRepository that calls
woow.fcm.device/unregister_device on the Odoo server. AccountRepository
now calls it during logout and removeAccount flows. Local FCM token is
cleared from Keychain only when the last account is removed.

Best-effort: server errors are logged but do not block logout.

Closes UX-69.
```

---

## P1-1: G8 -- Account Switch Re-authentication (4h)

**Gap:** `AccountRepository.switchAccount(id:)` on iOS simply flips the `isActive` flag in Core Data without validating the session. If the session expired or the password changed, the user lands on a broken WebView. Android re-authenticates on every switch (UX-68).

### Android Reference

`AccountRepository.kt` line 62-82 -- `switchAccount(accountId)`:
1. Fetches the account from DB
2. Retrieves the password from `EncryptedPrefs`
3. Calls `odooClient.authenticate(serverUrl, database, username, password)`
4. Only activates the account if `AuthResult.Success` is returned
5. Returns `false` if authentication fails (password wrong, session expired, server unreachable)

The iOS version must follow the same pattern exactly.

### Files to Modify

| File | Action |
|------|--------|
| `odoo/Data/Repository/AccountRepository.swift` | Rewrite `switchAccount(id:)` to re-authenticate |

### Changes

#### `odoo/Data/Repository/AccountRepository.swift`

Replace the current `switchAccount(id:)` body. The new implementation:

```swift
func switchAccount(id: String) async -> Bool {
    let context = persistence.container.viewContext

    // 1. Fetch target account entity
    guard let entity = (try? context.fetch(OdooAccountEntity.fetchByIdRequest(id: id)))?.first else {
        return false
    }

    // 2. Retrieve stored password from Keychain
    guard let password = secureStorage.getPassword(accountId: entity.username) else {
        return false  // No password = cannot re-authenticate
    }

    // 3. Re-authenticate with the Odoo server (mirrors Android exactly)
    let result = await apiClient.authenticate(
        serverUrl: entity.fullServerUrl,
        database: entity.database,
        username: entity.username,
        password: password
    )

    // 4. Only activate if authentication succeeds
    guard case .success = result else {
        return false
    }

    // 5. Deactivate all, activate target (same as before)
    let allRequest = OdooAccountEntity.fetchAllRequest()
    guard let all = try? context.fetch(allRequest) else { return false }
    all.forEach { $0.isActive = false }
    entity.isActive = true
    entity.createdAt = Date()  // Update last login timestamp
    return (try? context.save()) != nil
}
```

Key differences from the current iOS implementation:
- **Current:** Blindly sets `isActive = true` without any server contact
- **New:** Calls `apiClient.authenticate()` first, which also refreshes the session cookie in `HTTPCookieStorage`
- If authentication fails (expired password, server down), returns `false` so the UI can show an error or redirect to login

### Caller Impact

The existing callers of `switchAccount(id:)` already check the `Bool` return value. Wherever the caller handles `false`, it should now present an error alert (e.g., "Session expired. Please log in again.") and optionally remove the stale account or redirect to the login screen. This is a UI-layer change in whatever view calls `switchAccount`.

Check if there is an account list/switcher view that calls this. If the UI does not yet handle the `false` case, add an alert:

```swift
let success = await accountRepo.switchAccount(id: targetId)
if !success {
    showError = true  // "Unable to switch account. Session may have expired."
}
```

### Dependencies

Depends on G9 being complete first. Reason: if `switchAccount` fails and the caller decides to remove the stale account, the `removeAccount()` flow should already have FCM unregister in place (from G9). Otherwise a removed account's FCM token lingers.

### Tests

- **Unit test (happy path):** Mock `apiClient.authenticate()` to return `.success(...)`. Call `switchAccount(id:)`. Assert `isActive` is true for target, false for others, and return value is `true`.
- **Unit test (expired session):** Mock `apiClient.authenticate()` to return `.error("Invalid credentials", .invalidCredentials)`. Call `switchAccount(id:)`. Assert no account is marked active. Return value is `false`.
- **Unit test (no password):** Ensure `secureStorage.getPassword()` returns nil. Call `switchAccount(id:)`. Assert returns `false` without calling `apiClient`.
- **Unit test (server unreachable):** Mock `apiClient.authenticate()` to return `.error("Unable to connect", .networkError)`. Assert returns `false`.

### Commit Message

```
fix(account): re-authenticate on account switch (G8)

Rewrite switchAccount to call apiClient.authenticate() before
activating the account, matching Android behavior. Returns false if
the session has expired, the password is wrong, or the server is
unreachable. Callers must handle the false case with an error UI.

Closes UX-68.
```

---

## P1-2: G2 -- Wire PIN Setup in Settings (3h)

**Gap:** In `SettingsView.swift`, the "Set PIN" / "Change PIN" row is a static `HStack` with no tap action. Tapping it does nothing. The backend (`SettingsRepository.setPin()`, `removePin()`, `PinHasher`) and UI component (`PinView`) both exist but are not connected (UX-56).

### Existing Assets

- **`PinView.swift`** -- Full number pad with dot indicators, shake animation, lockout display. Currently only used for unlock verification (reads `authViewModel.verifyPin`).
- **`SettingsViewModel.swift`** -- Has `setPin(_:)` and `removePin()` methods already implemented.
- **`SettingsRepository.swift`** -- Has `setPin(_:)` (PBKDF2 hash + save) and `removePin()`.

### The Problem

`PinView` is designed for **verification** (enter existing PIN to unlock). It cannot be reused as-is for **setup** (enter new PIN, confirm new PIN). The setup flow requires:
1. Enter new PIN (4-6 digits)
2. Confirm new PIN (enter again)
3. If they match, save via `SettingsViewModel.setPin()`

### Files to Create/Modify

| File | Action |
|------|--------|
| `odoo/UI/Settings/PinSetupView.swift` | **Create** -- new PIN setup/change flow |
| `odoo/UI/Settings/SettingsView.swift` | Modify -- make PIN row tappable, navigate to `PinSetupView` |
| `odoo/UI/Settings/SettingsViewModel.swift` | No changes needed (already has `setPin` and `removePin`) |

### Changes

#### 1. Create `odoo/UI/Settings/PinSetupView.swift`

A new SwiftUI view implementing the two-step PIN setup flow. Reuses the number pad layout from `PinView` (extract the pad into a shared component, or duplicate the layout -- shared component is preferred).

**State machine with three steps:**

```
enum PinSetupStep {
    case enterCurrent   // Only shown when changing existing PIN
    case enterNew
    case confirmNew
}
```

**Props:**
```swift
struct PinSetupView: View {
    let isChangingPin: Bool          // true = change flow (verify old first), false = new setup
    let onPinSet: (String) -> Bool   // Callback to SettingsViewModel.setPin()
    let onVerifyOld: (String) -> Bool // Callback to verify current PIN (for change flow)
    let onCancel: () -> Void
}
```

**Flow for "Set PIN" (new):**
1. Show "Enter new PIN" with dot indicators
2. When 4+ digits entered, store temporarily, advance to confirmNew
3. Show "Confirm PIN" with dot indicators
4. If match, call `onPinSet(pin)`. If mismatch, show error, reset to enterNew.

**Flow for "Change PIN" (existing):**
1. Show "Enter current PIN" -- call `onVerifyOld(pin)` to verify
2. If correct, advance to enterNew
3. Same as steps 2-4 above

**Number pad:** Extract the 3x3 grid + 0 + backspace layout from `PinView` into a shared `PinNumpad` view in `odoo/UI/Components/PinNumpad.swift`, or inline-duplicate it. The shared component approach is cleaner:

```swift
struct PinNumpad: View {
    let onNumberTap: (String) -> Void
    let onDelete: () -> Void
    // ... same grid layout as PinView.numberPad
}
```

If extracting `PinNumpad`, also refactor `PinView` to use it (keep the refactor minimal -- just replace the `numberPad` computed property with `PinNumpad(onNumberTap:onDelete:)`).

#### 2. Modify `odoo/UI/Settings/SettingsView.swift`

Replace the static `HStack` for PIN with a `Button` that triggers navigation:

**Current (lines 52-58):**
```swift
HStack {
    Label("PIN Code", systemImage: "lock.fill")
    Spacer()
    Text(viewModel.settings.pinEnabled ? "Change PIN" : "Set PIN")
        .foregroundStyle(WoowColors.primaryBlue)
        .font(.caption)
}
```

**New:**
```swift
Button {
    showPinSetup = true
} label: {
    HStack {
        Label("PIN Code", systemImage: "lock.fill")
        Spacer()
        Text(viewModel.settings.pinEnabled ? "Change PIN" : "Set PIN")
            .foregroundStyle(WoowColors.primaryBlue)
            .font(.caption)
    }
}

// Also add a "Remove PIN" button when PIN is enabled
if viewModel.settings.pinEnabled {
    Button(role: .destructive) {
        viewModel.removePin()
    } label: {
        Label("Remove PIN", systemImage: "lock.slash")
    }
}
```

Add state and sheet:
```swift
@State private var showPinSetup = false
```

Present `PinSetupView` via `.sheet`:
```swift
.sheet(isPresented: $showPinSetup) {
    PinSetupView(
        isChangingPin: viewModel.settings.pinEnabled,
        onPinSet: { pin in viewModel.setPin(pin) },
        onVerifyOld: { pin in viewModel.settings.pinHash.map { PinHasher.verify(pin: pin, against: $0) } ?? false },
        onCancel: { showPinSetup = false }
    )
}
```

### Navigation Flow

```
Settings
  -> Tap "Set PIN"
    -> Sheet: PinSetupView (enterNew step)
      -> User enters 4-6 digits
      -> PinSetupView advances to confirmNew step
      -> User re-enters same digits
      -> Match -> calls viewModel.setPin() -> dismisses sheet
      -> Mismatch -> error shake, resets to enterNew

Settings
  -> Tap "Change PIN"
    -> Sheet: PinSetupView (enterCurrent step)
      -> User enters current PIN
      -> Verified -> advances to enterNew step
      -> Wrong -> error message + remaining attempts
      -> (same as above from enterNew onward)

Settings
  -> Tap "Remove PIN"
    -> Confirmation alert
    -> viewModel.removePin()
    -> PIN row updates to "Set PIN"
```

### Dependencies

Independent of all P0 tasks. Can be done in parallel with G8, but recommended after G8 because G8 touches `AccountRepository` which is nearby code and avoids merge conflicts.

### Tests

- **Unit test `PinSetupView` (snapshot/screenshot):** Render in each of the three steps, verify correct title text ("Enter current PIN", "Enter new PIN", "Confirm PIN").
- **Unit test (matching PINs):** Simulate entering "1234" twice. Assert `onPinSet` callback is invoked with "1234".
- **Unit test (mismatching PINs):** Simulate entering "1234" then "5678". Assert `onPinSet` is NOT called. Assert error state is shown.
- **Unit test (change flow -- wrong current PIN):** Simulate entering wrong current PIN. Assert `onVerifyOld` returns false, view stays on enterCurrent step.
- **Integration test `SettingsView`:** Tap "Set PIN" button. Assert `PinSetupView` sheet appears.
- **Integration test `SettingsView`:** With PIN enabled, verify "Change PIN" text is shown. Verify "Remove PIN" button is present.

### Commit Message

```
feat(settings): wire PIN setup and change flow in Settings (G2)

Create PinSetupView with enter-new/confirm-new two-step flow and
optional verify-current-first step for PIN changes. Extract shared
PinNumpad component from PinView. Add tappable PIN row and Remove
PIN button in SettingsView.

Closes UX-56.
```

---

## Task Dependency Graph

```
G3 (URL scheme, 0.5h)  ----\
                              >---> All P0 complete
G7 (lock screen, 1h)   ----/          |
                                       v
G9 (FCM unregister, 3h) -------> G8 (re-auth switch, 4h)
                                       |
                                       v
                              G2 (PIN setup, 3h)
                                       |
                                       v
                              All P1 complete
```

- G3 and G7 are fully independent; work on them in parallel or in either order.
- G9 should come after G7 (same notification domain, warm context).
- G8 depends on G9 (account removal during failed switch should unregister FCM).
- G2 is independent but recommended last to avoid merge conflicts with AccountRepository changes.

## Files Summary

### Files to Create

| File | Task | Description |
|------|------|-------------|
| `odoo/UI/Settings/PinSetupView.swift` | G2 | Two-step PIN setup/change flow |
| `odoo/UI/Components/PinNumpad.swift` | G2 | Shared number pad extracted from PinView |

### Files to Modify

| File | Task(s) | Description |
|------|---------|-------------|
| `odoo/Info.plist` | G3 | Add `CFBundleURLTypes` for `woowodoo://` |
| `odoo/odooApp.swift` | G3 | Add `.onOpenURL` handler |
| `odoo/App/AppDelegate.swift` | G7 | Register `UNNotificationCategory` with privacy placeholder |
| `odoo/Data/Push/NotificationService.swift` | G7 | Set `categoryIdentifier` on all notification content |
| `odoo/Data/Push/PushTokenRepository.swift` | G9 | Add `unregisterToken(for:)` and `clearLocalToken()` |
| `odoo/Data/Storage/SecureStorage.swift` | G9 | Add `deleteFcmToken()` |
| `odoo/Data/Repository/AccountRepository.swift` | G9, G8 | Call unregister on logout (G9); re-authenticate on switch (G8) |
| `odoo/UI/Settings/SettingsView.swift` | G2 | Make PIN row tappable, add sheet, add Remove PIN |
| `odoo/UI/Auth/PinView.swift` | G2 | Refactor to use shared `PinNumpad` |

### Files NOT Modified

| File | Reason |
|------|--------|
| `odoo/UI/Settings/SettingsViewModel.swift` | Already has `setPin()` and `removePin()` -- no changes needed |
| `odoo/Data/Repository/SettingsRepository.swift` | Already has full PIN CRUD -- no changes needed |
| `odoo/Data/Push/DeepLinkManager.swift` | Already handles pending URL persistence -- no changes needed |
| `odoo/Data/Push/DeepLinkValidator.swift` | Already validates `/web` paths -- no changes needed |
| `odoo/Domain/Models/AppSettings.swift` | Already has `pinEnabled` and `pinHash` fields -- no changes needed |
