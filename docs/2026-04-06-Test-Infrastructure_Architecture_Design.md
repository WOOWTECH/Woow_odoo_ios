# Architecture Design: Test Infrastructure & App Hooks

**Date:** 2026-04-06
**Goal:** Make all 34 skipped HIGH + MEDIUM priority XCUITests pass
**Estimated effort:** ~6 hours total

---

## Intention

All 82 UX features for the iOS Woow Tech Odoo app are fully implemented and unit-tested.
However, 34 out of 34 HIGH + MEDIUM priority XCUITests **skip at runtime** — not because
features are broken, but because the **test infrastructure is incomplete**.

The tests were written to be deterministic and self-contained, but they depend on:
1. Pre-existing test accounts on the Odoo server (none exist yet)
2. App-side debug hooks that seed known state before each test (3 hooks are missing)
3. Test configuration entries for multi-account scenarios (not in TestConfig.plist)

Without this plan, we cannot prove that the app works end-to-end on a real device or
simulator. Unit tests validate logic in isolation; XCUITests validate the full user flow.
Shipping to the App Store without passing E2E tests risks regressions that unit tests
cannot catch (navigation, WebView loading, notification tap → deep link, biometric gates).

This plan closes the gap between "tests exist" and "tests pass" by building the missing
test infrastructure — not by changing any production app code or features.

---

## Problem Statement

34 XCUITests exist but skip at runtime due to 4 root causes:

| Root Cause | Tests Affected | Fix Category |
|------------|---------------|--------------|
| No logged-in account on simulator | 16 tests | Test account + auto-login hook |
| App hooks not wired (`-ResetPINLockout`, `-AppLockEnabled NO`) | 4 tests | AppDelegate hook |
| No second test account for multi-account | 1 test | TestConfig.plist + Odoo server |
| iOS 16.4+ API (`XCUIApplication.open()`) | 6 tests | Minimum version gate (acceptable) |
| Network simulation hooks missing | 2 tests | URLProtocol injection |

---

## Component 1: Test Account Registration (Odoo Server)

### What
Create two dedicated test accounts on the Odoo server (`odoo18_ecpay` database) that XCUITests can use deterministically.

### Accounts to Create

| Key | Account 1 (Primary) | Account 2 (Switch) |
|-----|---------------------|---------------------|
| Purpose | Main login for all tests | Multi-account switch (UX-68) |
| Email | `xctest@woowtech.com` | `xctest2@woowtech.com` |
| Password | `XCTest2026!` | `XCTest2026!` |
| Display Name | `XCTest User` | `XCTest User 2` |
| Odoo Group | Internal User | Internal User |

### How to Create (via Odoo JSON-RPC)

```python
# Script: scripts/create_test_accounts.py
# Run once against the Odoo server to create both accounts.

import requests, json

SERVER = "https://preventing-weeks-cabinets-corporate.trycloudflare.com"
DB = "odoo18_ecpay"

def odoo_rpc(session, url, model, method, args=[], kwargs={}):
    return session.post(f"{SERVER}{url}", json={
        "jsonrpc": "2.0", "id": 1, "method": "call",
        "params": {"model": model, "method": method, "args": args, "kwargs": kwargs}
    }).json()

# 1. Authenticate as admin
s = requests.Session()
auth = s.post(f"{SERVER}/web/session/authenticate", json={
    "jsonrpc": "2.0", "id": 1, "method": "call",
    "params": {"db": DB, "login": "admin", "password": "admin"}
}).json()

# 2. Create test users
for login, name in [("xctest@woowtech.com", "XCTest User"),
                     ("xctest2@woowtech.com", "XCTest User 2")]:
    odoo_rpc(s, "/web/dataset/call_kw", "res.users", "create", [[{
        "login": login, "name": name, "password": "XCTest2026!",
        "groups_id": [(4, 1)]  # base.group_user (Internal User)
    }]])
```

### Why Two Accounts
- Account 1: used by all tests needing a logged-in state (UX-12, UX-13, UX-15, UX-20, UX-25, etc.)
- Account 2: used only by UX-68 (switch account test) — requires `TEST_SECOND_USER` env var

---

## Component 2: TestConfig.plist Update

### Current State
```xml
<key>SenderEmail</key>  <string>test@woowtech.com</string>
<key>SenderPass</key>    <string>test1234</string>
```

### New Keys to Add

```xml
<!-- Primary test account (used by most E2E tests) -->
<key>TestUser</key>       <string>xctest@woowtech.com</string>
<key>TestPass</key>       <string>XCTest2026!</string>

<!-- Secondary test account (used by UX-68 account switching) -->
<key>SecondUser</key>     <string>xctest2@woowtech.com</string>
<key>SecondPass</key>     <string>XCTest2026!</string>
```

### SharedTestConfig.swift Changes

Add to the `E2ETestConfig` enum:

```swift
/// Primary test user for E2E login flows.
static var testUser: String {
    ProcessInfo.processInfo.environment["TEST_USER"]
        ?? plistValue(forKey: "TestUser")
        ?? "xctest@woowtech.com"
}

static var testPass: String {
    ProcessInfo.processInfo.environment["TEST_PASS"]
        ?? plistValue(forKey: "TestPass")
        ?? "XCTest2026!"
}

/// Second test user for multi-account tests (UX-68).
static var secondUser: String {
    ProcessInfo.processInfo.environment["TEST_SECOND_USER"]
        ?? plistValue(forKey: "SecondUser")
        ?? "xctest2@woowtech.com"
}

static var secondPass: String {
    ProcessInfo.processInfo.environment["TEST_SECOND_PASS"]
        ?? plistValue(forKey: "SecondPass")
        ?? "XCTest2026!"
}
```

**Priority:** Environment variables override plist values override hardcoded defaults. This lets CI inject different credentials without modifying the plist.

---

## Component 3: AppDelegate Hook — `-ResetPINLockout`

### What
Add the missing `-ResetPINLockout YES` launch argument handler to `AppDelegate.processTestLaunchArguments()`.

### Where
`/Users/alanlin/Woow_odoo_ios/odoo/App/AppDelegate.swift` — inside `processTestLaunchArguments()`, after the `-AppLockEnabled` block (line ~84).

### Implementation

```swift
// Add after the -AppLockEnabled block:

if let lockoutIndex = args.firstIndex(of: "-ResetPINLockout"),
   args.indices.contains(lockoutIndex + 1),
   args[lockoutIndex + 1].uppercased() == "YES" {
    settingsRepo.resetFailedAttempts()
    print("[TestHook] ResetPINLockout applied: failed attempts and lockout timer cleared")
}
```

### Why
- `SettingsRepository.resetFailedAttempts()` already exists and clears both `failedPinAttempts` and `pinLockoutUntil`
- Tests UX-16 and UX-17 need clean lockout state at the start of each run
- Without this, the lockout from a previous test run persists and causes test interference

---

## Component 4: AppDelegate Hook — `-AppLockEnabled NO`

### What
Extend the existing `-AppLockEnabled` handler to support both `YES` and `NO`.

### Current Code (line 79-84)
```swift
if let lockIndex = args.firstIndex(of: "-AppLockEnabled"),
   args.indices.contains(lockIndex + 1),
   args[lockIndex + 1].uppercased() == "YES" {
    settingsRepo.setAppLock(true)
}
```

### New Code
```swift
if let lockIndex = args.firstIndex(of: "-AppLockEnabled"),
   args.indices.contains(lockIndex + 1) {
    let value = args[lockIndex + 1].uppercased()
    if value == "YES" {
        settingsRepo.setAppLock(true)
        print("[TestHook] AppLockEnabled applied: app lock is ON")
    } else if value == "NO" {
        settingsRepo.setAppLock(false)
        print("[TestHook] AppLockEnabled applied: app lock is OFF")
    }
}
```

### Why
- UX-21 (`test_UX21_givenAppLockDisabled_whenReturningFromBackground_thenNoAuthGate`) needs to guarantee app lock is OFF
- Currently the test can only hope the prior state has lock OFF, which is non-deterministic

---

## Component 5: AppDelegate Hook — `-AutoLogin`

### What
A new launch argument that automatically logs in with test credentials on launch, producing a logged-in state without requiring XCUITest to navigate the login UI.

### Why This Is the Biggest Unlock
16 tests skip because "No logged-in account found." Currently, tests call `loginWithTestCredentials()` which navigates the UI — but this only works if:
1. The server is reachable
2. The login UI is showing (not already logged in)
3. The network is fast enough for the 5-second timeout

An app-side auto-login hook is more reliable because it bypasses UI navigation and directly creates the account in Core Data + Keychain.

### Implementation

```swift
// In processTestLaunchArguments(), add:

if args.contains("-AutoLogin") {
    let serverUrl = envOrArg("-AutoLoginServer", default: "https://preventing-weeks-cabinets-corporate.trycloudflare.com")
    let database = envOrArg("-AutoLoginDatabase", default: "odoo18_ecpay")
    let username = envOrArg("-AutoLoginUser", default: "xctest@woowtech.com")
    let password = envOrArg("-AutoLoginPass", default: "XCTest2026!")

    let accountRepo = AccountRepository()
    let persistence = PersistenceController.shared
    let context = persistence.container.viewContext

    // Create account entity directly in Core Data
    let entity = OdooAccountEntity(context: context)
    entity.id = UUID()
    entity.serverUrl = serverUrl
    entity.database = database
    entity.username = username
    entity.displayName = "XCTest User"
    entity.userId = 1  // placeholder — sufficient for auth gate
    entity.isActive = true
    entity.createdAt = Date()
    try? context.save()

    // Store password in Keychain
    SecureStorage.shared.savePassword(password, serverUrl: serverUrl, username: username)

    print("[TestHook] AutoLogin applied: account \(username) created in Core Data + Keychain")
}

private func envOrArg(_ flag: String, default defaultValue: String) -> String {
    if let envVal = ProcessInfo.processInfo.environment[flag.replacingOccurrences(of: "-", with: "_")] {
        return envVal
    }
    let args = ProcessInfo.processInfo.arguments
    if let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1) {
        return args[idx + 1]
    }
    return defaultValue
}
```

### Important Caveat
This creates a **local-only** account (Core Data + Keychain) without performing a real Odoo login. The WebView will still need valid cookies to load Odoo. Two approaches:

**Option A (Recommended):** Auto-login creates the local account, then the test's `setUp` calls `loginWithTestCredentials()` via the UI. The local account makes the app skip the "first launch" flow and go straight to the auth gate or WebView. Tests that need a fully authenticated WebView still use the UI login.

**Option B (Full auto-login):** The hook performs a real `OdooAPIClient.authenticate()` call during launch. This is more complex (async in synchronous context) but produces a fully authenticated state:

```swift
if args.contains("-AutoLogin") {
    // Synchronous wrapper — acceptable only in #if DEBUG test hooks
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let client = OdooAPIClient()
        let result = await client.authenticate(
            serverUrl: serverUrl, database: database,
            username: username, password: password
        )
        if case .success(let auth) = result {
            let accountRepo = AccountRepository()
            await accountRepo.saveAccount(
                serverUrl: serverUrl, database: database,
                username: username, displayName: auth.displayName,
                userId: auth.userId, password: password,
                sessionId: auth.sessionId
            )
        }
        semaphore.signal()
    }
    semaphore.wait()
    print("[TestHook] AutoLogin applied with real authentication")
}
```

**Recommendation:** Use Option A for now — it's simpler, doesn't block the main thread, and the UI-based login is already proven to work. Option B is a future optimization.

---

## Component 6: Network Simulation Hooks (Optional — Lower Priority)

### `-SimulateTimeout YES`

Injects a `URLProtocol` subclass that delays all requests for 35 seconds (beyond the 30s timeout).

```swift
// New file: odoo/Data/API/TestURLProtocol.swift (DEBUG only)

#if DEBUG
class TimeoutURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Never call client methods — simulates infinite timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 35) { [weak self] in
            self?.client?.urlProtocol(self!, didFailWithError: URLError(.timedOut))
        }
    }
    override func stopLoading() {}
}

class NetworkErrorURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
#endif
```

### AppDelegate Wiring

```swift
if args.contains("-SimulateTimeout") {
    URLProtocol.registerClass(TimeoutURLProtocol.self)
    print("[TestHook] SimulateTimeout applied: all requests will time out")
}

if args.contains("-SimulateNetworkError") {
    URLProtocol.registerClass(NetworkErrorURLProtocol.self)
    print("[TestHook] SimulateNetworkError applied: all requests will fail")
}
```

### OdooAPIClient Change Required
The default `URLSession` init doesn't use `URLProtocol`. For registered protocols to work, the `URLSessionConfiguration` must include them:

```swift
// In OdooAPIClient.init():
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 30
// DEBUG: pick up any registered test URLProtocols
#if DEBUG
config.protocolClasses = URLProtocol.self.registeredClasses
#endif
```

**Alternative (simpler):** Tests for UX-08 and UX-09 already use `10.255.255.1` (black-hole IP) as a fallback when hooks aren't present. This works but takes 30+ seconds per test. The hook makes them instant.

---

## Component 7: Test Code Changes

### E2E_HighPriority_Tests.swift Changes

| Test | Current Skip Reason | Fix |
|------|-------------------|-----|
| UX-12 | No logged-in account | Add `-AutoLogin` to `setUp` launch args OR use `loginWithTestCredentials()` with new `E2ETestConfig.testUser` |
| UX-13 | No logged-in account | Same as UX-12 |
| UX-15 | No logged-in account + needs PIN | Add `-AutoLogin` + `-SetTestPIN 1234` + `-AppLockEnabled YES` |
| UX-20 | No logged-in account | Add `-AutoLogin` + `-AppLockEnabled YES` |
| UX-05 | Needs fresh login screen | Add `-ResetAppState` to ensure clean state |
| UX-25 | No logged-in account | `loginWithTestCredentials()` with test user |
| UX-26 | iOS 16.4+ | **Accept skip** — API limitation |
| UX-27 | iOS 16.4+ | **Accept skip** — API limitation |
| UX-28 | Server connectivity | Use test credentials; skip if server unreachable (acceptable) |
| UX-67 | Needs logged-in state for "Add Account" | `loginWithTestCredentials()` first |
| UX-68 | Needs `TEST_SECOND_USER` | Now in TestConfig.plist as `SecondUser` |
| UX-69 | Needs logged-in state | `loginWithTestCredentials()` first |

### E2E_MediumPriority_Tests.swift Changes

| Test | Current Skip Reason | Fix |
|------|-------------------|-----|
| UX-16 | `-SetTestPIN` hook check | Hook exists — remove `CommandLine.arguments` guard, use `app.launchArguments` |
| UX-17 | `-ResetPINLockout` missing | Implement hook in AppDelegate (Component 3) |
| UX-22 | `-SetTestPIN` hook check | Same as UX-16 |
| UX-64 | No logged-in account | `loginWithTestCredentials()` with test user |
| UX-65 | No logged-in account | Same |
| UX-72-74 | No account + iOS 16.4+ | Login first; **accept skip** on iOS <16.4 |
| UX-75 | iOS 16.4+ | **Accept skip** |
| UX-08 | Needs login screen | `-ResetAppState` in setUp |
| UX-09 | Needs login screen | `-ResetAppState` + optionally `-SimulateTimeout` |
| UX-10 | No logged-in account | `loginWithTestCredentials()` |
| UX-21 | No logged-in account | `loginWithTestCredentials()` + `-AppLockEnabled NO` |
| UX-30 | No logged-in account | `loginWithTestCredentials()` |
| UX-31 | Needs login screen | `-ResetAppState` |

---

## Implementation Order

| Step | Component | Effort | Unblocks |
|------|-----------|--------|----------|
| 1 | Create test accounts on Odoo server | 15 min | All login-dependent tests |
| 2 | Update TestConfig.plist + SharedTestConfig.swift | 15 min | UX-68, all tests using new creds |
| 3 | AppDelegate: `-ResetPINLockout` hook | 10 min | UX-17 |
| 4 | AppDelegate: `-AppLockEnabled NO` | 5 min | UX-21 |
| 5 | AppDelegate: `-AutoLogin` hook (Option A) | 30 min | 16 "no account" tests |
| 6 | Update E2E_HighPriority setUp methods | 1.5 hr | 12 HIGH tests |
| 7 | Update E2E_MediumPriority setUp methods | 2 hr | 22 MEDIUM tests |
| 8 | Network simulation hooks (optional) | 1 hr | UX-08, UX-09 (faster) |

**Total: ~6 hours**

---

## Expected Result After Implementation

| Category | Before | After |
|----------|--------|-------|
| Tests that PASS | ~13 | ~28 |
| Tests that SKIP (iOS 16.4+) | 6 | 6 (acceptable) |
| Tests that SKIP (no account) | 16 | 0 |
| Tests that SKIP (missing hook) | 4 | 0 |
| Tests that SKIP (network sim) | 2 | 0 |
| **Total runnable** | **~13/34** | **~28/34** |

The 6 remaining skips are iOS 16.4+ version gates — they pass on any simulator running iOS 16.4+, which is the default for Xcode 15+.

---

## File Change Summary

| File | Action | Lines Changed |
|------|--------|---------------|
| `odoo/App/AppDelegate.swift` | Edit | +25 lines (3 new hooks) |
| `odooUITests/TestConfig.plist` | Edit | +8 lines (4 new keys) |
| `odooUITests/SharedTestConfig.swift` | Edit | +20 lines (4 new properties) |
| `odooUITests/E2E_HighPriority_Tests.swift` | Edit | ~50 lines (setUp changes) |
| `odooUITests/E2E_MediumPriority_Tests.swift` | Edit | ~60 lines (setUp changes) |
| `odoo/Data/API/TestURLProtocol.swift` | New (optional) | ~30 lines |
| `scripts/create_test_accounts.py` | New | ~40 lines |

**Total: ~230 lines of changes across 7 files**
