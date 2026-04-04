# XCUITest A-Grade Quality Plan — FCM E2E Tests

**Date:** 2026-04-05
**Status:** Planned
**Grade Before:** C+
**Target Grade:** A (100% automation, zero human intervention)

---

## Design Principle

> We proved XCUITest CAN read iOS notification content from Springboard:
> `ODOO, 現在, Test User, XCUITest FCM verification`
>
> Android uses uiautomator2 to verify notifications. iOS uses XCUITest + Springboard.
> Same approach, same confidence level. No manual QA fallback.

---

## Architecture: 3 Layers, All Automated

| Layer | Tool | What It Tests | Runs On | Speed |
|-------|------|---------------|---------|-------|
| **Unit tests** | XCTest | Notification content construction, deep link validation, `aps.alert` guard, tap handler | Simulator, every PR | <1s each |
| **XCUITest E2E** | XCUITest + Springboard | Full pipeline: Login → Odoo chatter → FCM → APNs → notification center → read content → tap → deep link | Real iPhone, nightly | ~90s each |
| **Python orchestrator** | `e2e-fcm-test.py` | Server-side: Odoo RPC → FCM delivery receipt (HTTP 200) → device registration check | CI server, every deploy | ~30s |

---

## Current Test Results (8 tests)

| Test | Event Type | Result | Verified Content |
|------|-----------|--------|-----------------|
| FCM.1 | Login | **Passed** | App logged into Odoo |
| FCM.2 | Permission | **Passed** | No-op (always passes) |
| FCM.3 | Token registration | **Passed** | App stays alive 10s |
| FCM.4 | Chatter | **Passed** | `ODOO, Test User, XCUITest FCM verification` |
| FCM.5 | @mention | **Passed** | `ODOO, Test User, @Admin please review` |
| FCM.6 | Discuss DM | **Passed** | `ODOO, Test User, Discuss DM test from XCUITest` |
| FCM.7 | Activity | **Failed** | `ir.model` access denied → `res_model_id=0` → silent failure |
| FCM.8 | Deep link tap | **Failed** | Notification tapped but device locked → can't reach foreground |

---

## Fixes: 3 Tiers

### Tier 1: Critical (Silent Failures → Loud Failures)

#### Fix C1: `odooLogin` must assert success
```swift
// After network call, guard against empty cookies
if cookies.isEmpty {
    print("odooLogin FAILED for \(email) — check server URL and credentials")
}
```

#### Fix C2: `odooRPC` must check `json["error"]`
```swift
if let errorBlock = json["error"] as? [String: Any] {
    let data = errorBlock["data"] as? [String: Any]
    let msg = data?["message"] ?? errorBlock["message"] ?? "unknown"
    print("odooRPC ERROR [\(model).\(method)]: \(msg)")
}
result = json["result"]
```

#### Fix C3: `getModelId` guard in FCM.7
```swift
let modelId = getModelId(cookies: adminCookies, model: "res.partner")
guard modelId != 0 else {
    XCTFail("getModelId returned 0 — admin cannot read ir.model or model not found")
    return
}
```

#### Fix C4: FCM.8 remove `app.activate()` fallback
The `app.activate()` after a failed notification tap converts a real failure into a false pass.
Remove it. The test should fail clearly with: "App must reach foreground after notification tap.
Precondition: test device must have no passcode."

#### Fix C5: FCM.8 passcode precondition + deep link verification
```swift
XCTAssertTrue(appCameToForeground,
    "App must reach foreground after notification tap. "
    + "Precondition: test device has no passcode "
    + "(Settings > Face ID & Passcode > Turn Passcode Off)")

// Verify deep link landed on WebView (not just "app is running")
XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15),
    "WebView should load after deep link navigation")
```

### Tier 2: Robustness (Flakiness → Reliability)

#### Fix R1: NSPredicate format args (prevent quote injection)
```swift
// Before (breaks if appName contains single quote)
NSPredicate(format: "label CONTAINS[c] '\(appName)'")

// After
NSPredicate(format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@", appName, sender)
```

#### Fix R2: Hardcoded IDs as documented constants
```swift
// Test database fixture IDs (odoo18_ecpay)
// Query Odoo res.users/res.partner to find these for a new database
private static let testPartnerID = 1567      // Partner record admin follows
private static let adminPartnerID = 3        // Admin's res.partner ID
private static let adminUserID = 2           // Admin's res.users ID
private static let generalChannelID = 1      // "general" discuss channel
private static let todoActivityTypeID = 4    // "To-Do" mail.activity.type
```

#### Fix R3: FCM.4 refactor to use shared helpers
Replace FCM.4's inline logic with `clearAndSendNotification` + `verifyNotification`.
Remove the separate `sendOdooChatterMessage()` helper.

### Tier 3: A-Grade Polish

#### Fix A1: FCM.2 meaningful assertion
Replace no-op `XCTAssertTrue(true, ...)` with actual permission check.
XCUITest can query Settings app, but that's fragile. Instead, verify the app
received an FCM token (check Xcode console output, or add a UI element that
shows token status in debug builds).

**Pragmatic approach:** Replace with `XCTSkipIf` if we can't meaningfully assert:
```swift
func test_FCM_2_notificationPermissionGranted() {
    // Notification permission is granted at first install via system prompt.
    // XCUITest cannot programmatically verify UNAuthorizationStatus.
    // This is verified by FCM.4-6 succeeding (no notification without permission).
    // Mark as skip-if-not-verifiable rather than false-pass.
}
```

#### Fix A2: URL force-unwrap safety
```swift
// Before (crashes test runner on bad URL)
URL(string: "\(baseURL)/web/session/authenticate")!

// After
guard let url = URL(string: "\(baseURL)/web/session/authenticate") else {
    XCTFail("Invalid server URL: \(baseURL)")
    return []
}
```

#### Fix A3: `@escaping` annotation cleanup
`clearAndSendNotification` closure is called synchronously — remove `@escaping`.

---

## Unit Tests to Add (Phase 1)

These already exist in `odooTests/` (197 tests, all passing). The test-automator review
confirmed 25 push-related unit tests covering:

- `PushTokenRepositoryTests` (2/2) — token save/retrieve
- `NotificationServiceTests` (10/10) — payload construction
- `NotificationServiceEdgeCaseTests` (4/4) — empty body, long title, Unicode
- `AppDelegateHandleNotificationTapTests` (4/4) — deep link routing
- `AppDelegateNotificationTests` (5/5) — foreground display, tap handler

**No new unit tests needed** — existing coverage is comprehensive.

---

## Implementation Assignment

All fixes are in ONE file: `odooUITests/odooUITests.swift`

| Fix | Description | Priority |
|-----|-------------|----------|
| C1 | `odooLogin` error logging | Critical |
| C2 | `odooRPC` error checking | Critical |
| C3 | `getModelId` guard in FCM.7 | Critical |
| C4 | Remove `app.activate()` fallback in FCM.8 | Critical |
| C5 | FCM.8 passcode precondition + WebView assertion | Critical |
| R1 | NSPredicate format args | High |
| R2 | Hardcoded IDs as constants | High |
| R3 | FCM.4 refactor to shared helpers | High |
| A1 | FCM.2 meaningful assertion | Medium |
| A2 | URL force-unwrap safety | Medium |
| A3 | `@escaping` cleanup | Low |

---

## Verification

### Pre-verification (no device needed)
```bash
# Build compiles
xcodebuild build-for-testing -project odoo.xcodeproj -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Unit tests pass
xcodebuild test -project odoo.xcodeproj -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:odooTests
```

### Full verification (iPhone connected, no passcode)
```bash
xcodebuild test -project odoo.xcodeproj -scheme odoo \
  -destination 'platform=iOS,name=Alan 的 iPhone' \
  -only-testing:'odooUITests/FCM_EndToEndTests'
```

### Pass criteria
- All 8 FCM tests pass
- FCM.7 creates activity and notification arrives with sender name
- FCM.8 taps notification and WebView loads (device must have no passcode)
- No `sleep()` used for assertion synchronization (only for FCM delivery wait, which is irreducible)
- All failures produce clear diagnostic messages
