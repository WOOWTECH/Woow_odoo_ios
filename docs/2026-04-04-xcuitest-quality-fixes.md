# XCUITest Quality Fixes — FCM E2E Tests

**Date:** 2026-04-04
**Status:** Planned
**Grade Before:** C+ (test-automator review)
**Target Grade:** B+

---

## Current Test Results (8 tests)

| Test | Event Type | Result | Issue |
|------|-----------|--------|-------|
| FCM.1 | Login | **Passed** | — |
| FCM.2 | Notification permission | **Passed** | No-op test (always passes) |
| FCM.3 | Token registration | **Passed** | — |
| FCM.4 | Chatter notification | **Passed** | `ODOO, Test User, XCUITest FCM verification` |
| FCM.5 | @mention | **Passed** | `ODOO, Test User, @Admin please review` |
| FCM.6 | Discuss DM | **Passed** | `ODOO, Test User, Discuss DM test from XCUITest` |
| FCM.7 | Activity assigned | **Failed** | `ir.model` access denied for test user → `res_model_id=0` → silent failure |
| FCM.8 | Deep link tap | **Failed** | Notification tapped but device locked → app can't reach foreground |

---

## Critical Fixes (Must Do)

### Fix 1: `odooLogin` must assert success

**Problem:** Returns empty `[]` on failure, no error logged. Tests pass vacuously.

**Fix:** Add guard + log error response body.
```swift
// After dataTask completes, check for empty cookies
guard !cookies.isEmpty else {
    print("odooLogin FAILED for \(email)")
    return []
}
```

### Fix 2: `odooRPC` must check `json["error"]`

**Problem:** Odoo returns `{"error": {...}}` for failures but `odooRPC` only reads `json["result"]`. Errors are silently swallowed.

**Fix:** Log error block when present.
```swift
if let errorBlock = json["error"] as? [String: Any] {
    let msg = (errorBlock["data"] as? [String: Any])?["message"] ?? errorBlock["message"]
    print("odooRPC ERROR [\(model).\(method)]: \(msg ?? "unknown")")
}
```

### Fix 3: `getModelId` returning 0 must fail the test

**Problem:** `modelId=0` is silently passed to `mail.activity.create`, which fails with a DB constraint error. No notification is sent. Test fails with unhelpful "notification not found".

**Fix:** Add `guard modelId != 0` in FCM.7 before calling `clearAndSendNotification`.

### Fix 4: FCM.8 remove `app.activate()` fallback

**Problem:** After notification tap fails to bring app to foreground (because device is locked), `app.activate()` forces it to foreground. Test then asserts `app.state == .runningForeground` which is trivially true — but the deep link was never processed.

**Fix:** Remove the fallback. Add precondition comment: "test device must have no passcode". Assert WebView loads after tap (not just app state).

### Fix 5: FCM.8 passcode precondition

**Problem:** Tapping a notification on iOS lock screen requires Face ID/passcode. XCUITest can't unlock the device.

**Fix:** Document precondition: "Settings → Face ID & Passcode → Turn Passcode Off" on test device. Add clear error message in assertion.

---

## High Priority Fixes

### Fix 6: NSPredicate string interpolation → format args

**Problem:** `"label CONTAINS[c] '\(appName)'"` breaks if `appName` contains a single quote.

**Fix:** Use `NSPredicate(format: "label CONTAINS[c] %@", appName)`.

### Fix 7: Hardcoded IDs as constants

**Problem:** `1567`, `[3]`, `2`, `1` scattered throughout. New database = all tests break.

**Fix:** Add constants at top of class with documentation:
```swift
// Test database fixture IDs (odoo18_ecpay)
private static let testPartnerID = 1567      // Partner record admin follows
private static let adminPartnerID = 3        // Admin's res.partner ID
private static let adminUserID = 2           // Admin's res.users ID
private static let generalChannelID = 1      // "general" discuss channel
private static let todoActivityTypeID = 4    // "To-Do" mail.activity.type
```

### Fix 8: FCM.4 should use `clearAndSendNotification`

**Problem:** FCM.4 uses separate `sendOdooChatterMessage()` helper which duplicates login logic. Inconsistent with FCM.5-7.

**Fix:** Refactor FCM.4 to use `clearAndSendNotification` + `verifyNotification`. Remove `sendOdooChatterMessage()`.

---

## Implementation Assignment

| Fix # | Agent | File |
|-------|-------|------|
| 1-8 | test-automator | `odooUITests/odooUITests.swift` |

No Odoo backend or iOS app changes needed — all fixes are in the XCUITest file only.

---

## Verification

After implementation, run:
```bash
xcodebuild test -project odoo.xcodeproj -scheme odoo \
  -destination 'platform=iOS,name=Alan 的 iPhone' \
  -only-testing:'odooUITests/FCM_EndToEndTests' \
  -allowProvisioningUpdates
```

**Pass criteria:** All 8 tests pass. FCM.7 creates activity and receives notification. FCM.8 passes on device with no passcode (or is skipped with documented reason).
