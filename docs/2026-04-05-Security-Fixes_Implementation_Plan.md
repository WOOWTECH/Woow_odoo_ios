# Security Fixes Implementation Plan — H1-H6

**Date:** 2026-04-05
**Scope:** Six high-priority security and functionality fixes for the WoowTech Odoo iOS app
**Total estimated effort:** ~10 hours
**Implementation order:** H1 → H6 → H2 → H3 → H4 → H5 (dependencies explained per fix)

---

## Overview

| Fix | Issue | Severity | Effort | Files Changed |
|-----|-------|----------|--------|---------------|
| H1 | DispatchSemaphore deadlock | Critical — app freeze | 2h | `AccountRepository.swift`, `MainViewModel.swift` |
| H2 | DeepLinkValidator bypass via empty serverHost | High — URL injection | 1h | `AppDelegate.swift`, `odooApp.swift`, `DeepLinkValidator.swift` |
| H3 | Session cookie in plaintext HTTPCookieStorage | High — session hijack | 3h | `OdooAPIClient.swift`, `SecureStorage.swift`, `OdooWebView.swift`, `AccountRepository.swift` |
| H4 | No privacy overlay on app backgrounding | High — data leakage | 1h | `odooApp.swift` |
| H5 | Theme mode persisted but never applied | Medium — broken UX | 1h | `odooApp.swift` |
| H6 | Keychain password key collision across servers | High — credential loss | 2h | `SecureStorage.swift`, `AccountRepository.swift` |

---

## H1: DispatchSemaphore Deadlock in AccountRepository

### Problem Analysis

**File:** `/Users/alanlin/Woow_odoo_ios/odoo/Data/Repository/AccountRepository.swift` (lines 196-207)

`AccountRepository.getSessionId(for:)` is declared as a synchronous function but internally spins up a `Task` to call `apiClient.getSessionId(for:)` (which is on the `actor OdooAPIClient`) and then blocks the calling thread with `DispatchSemaphore.wait()`.

The call chain is:

```
MainViewModel.init() [MainActor]
  -> loadActiveAccount() [MainActor]
    -> accountRepository.getSessionId(for:) [MainActor — synchronous]
      -> DispatchSemaphore.wait() [BLOCKS the main thread]
        -> Task { await apiClient.getSessionId(...) } [needs to hop back — deadlock]
```

`OdooAPIClient` is an `actor`. When the Task inside `getSessionId` tries to run, it needs to resume on the actor's executor. However, the `DispatchSemaphore.wait()` call has already pinned the main thread (on which `@MainActor` is running), creating a deadlock. In practice the app survives because `HTTPCookieStorage.shared.cookies(for:)` is synchronous and the actor hop completes before the semaphore deadline on fast devices — but this is a race condition, not correct behavior. It will fail under load, on slow devices, or when the Swift concurrency runtime tightens its scheduling.

### Security Rationale

A deadlock on the main thread produces an ANR-equivalent (iOS watchdog kills the app after a few seconds of main-thread block). Beyond the UX impact, a frozen app in a state where the session cookie has not been validated yet could allow an attacker with access to the device to inspect in-memory session data before the app enforces its auth gate.

### Fix: Convert `getSessionId` to `async`

The `OdooAPIClient.getSessionId(for:)` method (line 161-167 of `OdooAPIClient.swift`) reads directly from `HTTPCookieStorage.shared` — it is already synchronous inside the actor and does not need the `Task` wrapper at all. The fix is two-part:

**Part 1 — AccountRepository.swift:** Remove the semaphore entirely. Because `HTTPCookieStorage.shared.cookies(for:)` is a synchronous, thread-safe API call, expose a direct synchronous path. The actor isolation of `OdooAPIClient` is only needed for mutable state; `HTTPCookieStorage` is a system-owned singleton and can be accessed from any thread.

Replace lines 196-207:

```swift
// BEFORE (deadlock-prone)
func getSessionId(for serverUrl: String) -> String? {
    let semaphore = DispatchSemaphore(value: 0)
    var sessionId: String?
    Task {
        sessionId = await apiClient.getSessionId(for: serverUrl)
        semaphore.signal()
    }
    semaphore.wait()
    return sessionId
}

// AFTER (direct read — no concurrency needed)
func getSessionId(for serverUrl: String) -> String? {
    guard let url = URL(string: serverUrl),
          let cookies = HTTPCookieStorage.shared.cookies(for: url) else {
        return nil
    }
    return cookies.first(where: { $0.name == "session_id" })?.value
}
```

This is safe because:
- `HTTPCookieStorage.shared` is documented as thread-safe by Apple.
- The actor isolation on `OdooAPIClient` protects the actor's own mutable state (`requestId`), not `HTTPCookieStorage`.
- This removes the `AccountRepositoryProtocol.getSessionId` signature dependency on `OdooAPIClient.getSessionId`, decoupling the layers correctly.

**Part 2 — AccountRepositoryProtocol:** The protocol signature stays synchronous (`-> String?`) because the implementation is now truly synchronous. No callers need to change. `MainViewModel.loadActiveAccount()` continues to call it as-is.

**Part 3 — OdooAPIClient.getSessionId:** The actor method can remain for internal use during `authenticate()` (line 83 of `OdooAPIClient.swift`). No change needed there.

### Files to Change

| File | Lines | Change |
|------|-------|--------|
| `odoo/Data/Repository/AccountRepository.swift` | 196-207 | Replace semaphore block with direct `HTTPCookieStorage` read |

### Test Verification

After the fix, `MainViewModel.init()` on the main actor will call `getSessionId` synchronously with no thread-blocking. Verify with:
1. A unit test that calls `AccountRepository().getSessionId(for: "https://demo.odoo.com")` from the main actor without deadlock.
2. Thread Sanitizer (TSAN) should show zero data races on `getSessionId`.

---

## H6: Keychain Password Key Collision Across Servers

**Note: Fix H6 before H3 because H3 adds a second Keychain key type (`session_`) that uses the same key-construction pattern. Establishing the correct key format first means H3 starts clean.**

### Problem Analysis

**File:** `/Users/alanlin/Woow_odoo_ios/odoo/Data/Storage/SecureStorage.swift` (line 27)

Current key construction:

```swift
func savePassword(accountId: String, password: String) {
    save(key: "pwd_\(accountId)", value: password)
}
```

`accountId` is the Odoo username (e.g., `"admin"`). If the same username exists on two different Odoo servers (e.g., `https://company-a.odoo.com` and `https://company-b.odoo.com`), both accounts map to Keychain key `pwd_admin`. The second `savePassword` call overwrites the first with `SecItemUpdate`. The result: the user switches back to company-A, `getPassword(accountId:)` returns company-B's password, the re-authentication attempt fails (wrong password), and `switchAccount` returns `false`.

This is not theoretical — any multi-tenant Odoo deployment assigns `admin` to every database. The auto-login plan explicitly calls this out under "Multi-Account Scalability": "needs `pwd_{serverUrl}_{username}`".

### Security Rationale

Credential confusion between accounts on different servers can cause authentication failures (loss of access) or, in the worst case, inadvertently submit one server's password to another server during re-authentication. It also violates the principle of key uniqueness: two logically distinct credentials must not share a storage slot.

### Fix: Change Key Format + Migrate Existing Data

**New key format:** `pwd_{serverHost}_{username}`

Using `serverHost` (the hostname only, e.g., `company-a.odoo.com`) rather than the full URL avoids embedding `://` and path components in the Keychain account attribute, which is cleaner. The hostname is unique enough to disambiguate servers.

**Part 1 — Update SecureStorage public API**

The current protocol and class methods take only `accountId: String`. They need a second parameter for server scope. Because `SecureStorageProtocol` is used by `AccountRepository`, both must be updated together.

```swift
// BEFORE
protocol SecureStorageProtocol: Sendable {
    func savePassword(accountId: String, password: String)
    func getPassword(accountId: String) -> String?
    func deletePassword(accountId: String)
}

// AFTER
protocol SecureStorageProtocol: Sendable {
    func savePassword(serverUrl: String, username: String, password: String)
    func getPassword(serverUrl: String, username: String) -> String?
    func deletePassword(serverUrl: String, username: String)
}
```

The implementation converts `serverUrl` to a host-only key component:

```swift
private func passwordKey(serverUrl: String, username: String) -> String {
    let host = URL(string: serverUrl)?.host ?? serverUrl
    return "pwd_\(host)_\(username)"
}

func savePassword(serverUrl: String, username: String, password: String) {
    save(key: passwordKey(serverUrl: serverUrl, username: username), value: password)
}

func getPassword(serverUrl: String, username: String) -> String? {
    get(key: passwordKey(serverUrl: serverUrl, username: username))
}

func deletePassword(serverUrl: String, username: String) {
    delete(key: passwordKey(serverUrl: serverUrl, username: username))
}
```

**Part 2 — Migration on first launch**

Existing users have passwords stored under `pwd_{username}`. On first launch after the update, attempt to migrate each known account's old key to the new key format. Add a migration method called once from `AppRootViewModel` or `AccountRepository.init()`:

```swift
/// Migrates legacy Keychain keys (pwd_{username}) to scoped keys (pwd_{host}_{username}).
/// Safe to call multiple times — already-migrated entries are skipped because the
/// old key no longer exists after the first successful migration.
func migratePasswordKeys(accounts: [OdooAccount]) {
    for account in accounts {
        let legacyKey = "pwd_\(account.username)"
        let newKey = passwordKey(serverUrl: account.serverUrl, username: account.username)

        // Skip if already migrated (new key exists) or nothing to migrate (old key absent)
        guard get(key: newKey) == nil,
              let existingPassword = get(key: legacyKey) else { continue }

        save(key: newKey, value: existingPassword)
        delete(key: legacyKey)
    }
}
```

**Part 3 — Update all callers in AccountRepository.swift**

Every call to `secureStorage.savePassword`, `getPassword`, `deletePassword` must be updated to pass both `serverUrl` and `username`. The `OdooAccount` domain model already carries both, so all call sites have the information available:

| Line | Old call | New call |
|------|----------|----------|
| Line 80 | `savePassword(accountId: username, ...)` | `savePassword(serverUrl: fullUrl, username: username, ...)` |
| Line 109 | `getPassword(accountId: account.username)` | `getPassword(serverUrl: account.serverUrl, username: account.username)` |
| Line 149 | `deletePassword(accountId: account.username)` | `deletePassword(serverUrl: account.serverUrl ?? "", username: account.username)` |
| Line 167 | `deletePassword(accountId: entity.username)` | `deletePassword(serverUrl: entity.serverUrl ?? "", username: entity.username)` |

### Files to Change

| File | Change |
|------|--------|
| `odoo/Data/Storage/SecureStorage.swift` | Add `passwordKey(serverUrl:username:)`, update 3 public methods, add `migratePasswordKeys(accounts:)` |
| `odoo/Data/Repository/AccountRepository.swift` | Update 4 call sites; call `migratePasswordKeys` in `init` or a dedicated bootstrap method |

---

## H2: DeepLinkValidator Bypass via Empty serverHost

### Problem Analysis

**Files:**
- `/Users/alanlin/Woow_odoo_ios/odoo/App/AppDelegate.swift` (line 126)
- `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` (line 32)
- `/Users/alanlin/Woow_odoo_ios/odoo/Data/Push/DeepLinkValidator.swift`

There are two distinct vulnerabilities:

**Vulnerability 1 — Empty serverHost makes absolute URL validation meaningless**

`DeepLinkValidator.isValid(url:serverHost:)` validates absolute URLs by comparing `urlHost` against `serverHost`. When `serverHost` is `""`, the comparison `urlHost.caseInsensitiveCompare("")` always returns `.orderedDescending` for any real host, so absolute URLs are always rejected. This sounds safe but it is not: the relative path branch runs first.

**Vulnerability 2 — The `/web` prefix check is exploited by the short-circuit in AppDelegate**

`AppDelegate.handleNotificationTap` (line 126):

```swift
if actionUrl.hasPrefix("/web") || DeepLinkValidator.isValid(url: actionUrl, serverHost: "") {
    DeepLinkManager.shared.setPending(actionUrl)
}
```

Because the `||` short-circuits, **any** URL starting with `/web` is unconditionally accepted without ever calling `DeepLinkValidator`. A malicious push notification with `odoo_action_url = "/web../../../../etc/passwd"` or `"/web@evil.com"` would be accepted and stored as a pending deep link. When the WebView consumes it, it would construct a full URL by prepending the server base, but the path traversal or host-override could escape the intended origin depending on how `OdooWebView` builds the final URL.

The validator itself also has an overly broad allowlist: `trimmed.hasPrefix("/web")` allows `/website/shop`, `/webapi/...`, `/web/../admin`, etc. The intended allowlist is Odoo's standard paths: `/web`, `/web#action=...`, `/web/login`.

**Vulnerability 3 — odooApp.swift passes empty serverHost to a different validator call**

`odooApp.handleIncomingURL` (line 32) also passes `serverHost: ""`. For custom URL scheme deep links (`woowodoo://`), this means any relative `/web*` path from any source is accepted without verifying it targets the user's actual server.

### Security Rationale

The primary risk is pushing an attacker-controlled URL into the WebView navigation stack, enabling cross-origin navigation or path traversal within the Odoo deployment. Secondary risk: storing attacker-controlled strings in `DeepLinkManager` that persist across sessions.

### Fix

**Part 1 — Tighten the `/web` allowlist in DeepLinkValidator**

Replace the broad `hasPrefix("/web")` with a strict regex matching only the canonical Odoo web paths:

```swift
// Strict allowlist for Odoo relative deep links.
// Matches: /web, /web/, /web#..., /web?..., /web/login, /web/login?...
// Rejects: /web/../, /website/, /webapi/, /web@evil.com
private static let allowedRelativePathPattern = try! NSRegularExpression(
    pattern: #"^/web(?:[/?#]|$)"#,
    options: .caseInsensitive
)

static func isValid(url: String, serverHost: String) -> Bool {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    // Reject control characters (newline injection, header injection)
    if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
        return false
    }

    // Reject path traversal sequences before any other check
    if trimmed.contains("..") || trimmed.contains("%2e%2e") || trimmed.contains("%2E%2E") {
        return false
    }

    // Allow only canonical Odoo relative paths
    let range = NSRange(trimmed.startIndex..., in: trimmed)
    if allowedRelativePathPattern.firstMatch(in: trimmed, range: range) != nil {
        return true
    }

    // Absolute URLs: require https and same host (serverHost must not be empty)
    guard !serverHost.isEmpty,
          let parsed = URL(string: trimmed),
          let scheme = parsed.scheme?.lowercased(),
          scheme == "https",
          let urlHost = parsed.host else {
        return false
    }
    return urlHost.caseInsensitiveCompare(serverHost) == .orderedSame
}
```

Key changes:
- Adds `..` path traversal rejection before any branch executes.
- Replaces `hasPrefix("/web")` with a regex requiring `/web` to be followed by `/`, `?`, `#`, or end of string.
- Adds `guard !serverHost.isEmpty` so that absolute URL validation correctly rejects all absolute URLs when serverHost is unknown (rather than silently allowing none while the relative-path branch remains wide open).

**Part 2 — Pass actual serverHost in AppDelegate**

`AppDelegate` needs access to the active account's server URL. The cleanest approach without introducing a dependency on the full DI stack in AppDelegate is to read it directly from `AccountRepository` (which reads Core Data synchronously):

```swift
@MainActor
func handleNotificationTap(userInfo: [AnyHashable: Any]) {
    guard let actionUrl = userInfo["odoo_action_url"] as? String else { return }

    let serverHost = AccountRepository().getActiveAccount()?.serverHost ?? ""

    // Do not use short-circuit: always run full validator, never bypass with hasPrefix
    if DeepLinkValidator.isValid(url: actionUrl, serverHost: serverHost) {
        DeepLinkManager.shared.setPending(actionUrl)
    }
}
```

Note: The `||` short-circuit is removed entirely. The validator now handles both the `/web` prefix case and the absolute URL case internally.

**Part 3 — Pass actual serverHost in odooApp.swift**

```swift
private func handleIncomingURL(_ url: URL) {
    guard url.scheme == "woowodoo" else { return }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value else {
        return
    }
    let serverHost = AccountRepository().getActiveAccount()?.serverHost ?? ""
    if DeepLinkValidator.isValid(url: urlParam, serverHost: serverHost) {
        DeepLinkManager.shared.setPending(urlParam)
    }
}
```

**Part 4 — Ensure OdooAccount exposes serverHost**

The `OdooAccount` domain model needs a computed `serverHost` property if it does not already exist:

```swift
var serverHost: String {
    URL(string: serverUrl)?.host ?? ""
}
```

### Files to Change

| File | Change |
|------|--------|
| `odoo/Data/Push/DeepLinkValidator.swift` | Add `allowedRelativePathPattern`, add `..` check, tighten `/web` check, add `!serverHost.isEmpty` guard |
| `odoo/App/AppDelegate.swift` | Line 126: remove `||` short-circuit, pass real `serverHost` |
| `odoo/odooApp.swift` | Line 32: pass real `serverHost` |
| `odoo/Domain/OdooAccount.swift` (or equivalent model file) | Add `var serverHost: String` computed property if absent |

---

## H3: Session Cookie in Plaintext HTTPCookieStorage

### Problem Analysis

**Files:**
- `/Users/alanlin/Woow_odoo_ios/odoo/Data/API/OdooAPIClient.swift` (lines 160-175)
- `/Users/alanlin/Woow_odoo_ios/odoo/UI/Main/OdooWebView.swift` (line 36)

`OdooAPIClient` uses `URLSessionConfiguration.default` with `httpCookieStorage = .shared`. After a successful authentication, the Odoo server sets a `session_id` cookie. iOS persists `HTTPCookieStorage.shared` to `Library/Cookies/Cookies.binarycookies` on disk. This file:

- Is **not encrypted** — it uses standard filesystem storage with no `NSFileProtection` beyond the system default (`NSFileProtectionCompleteUntilFirstUserAuthentication`).
- Is **included in iTunes/Finder backups** by default unless explicitly excluded.
- Is **readable on jailbroken devices** without any additional privilege.
- Is **readable via MDM-managed device backup extraction** tools used in enterprise forensics.

For a business-facing Odoo app handling invoices, HR data, and sales records, session hijacking via cookie file extraction is a realistic threat in enterprise device management scenarios.

### Security Rationale

The `session_id` cookie is functionally equivalent to a password — whoever holds it can perform any action the user can perform in Odoo until the session expires. Storing it in the Keychain (which uses hardware-backed encryption on devices with Secure Enclave) provides `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` protection: the value is decrypted only by the device's hardware key, is excluded from backups, and cannot be extracted even from a jailbroken device without the hardware key.

### Fix Architecture

The approach is to treat `HTTPCookieStorage.shared` as a cache only (used by URLSession for network requests) and maintain a Keychain-backed authoritative copy of the `session_id` that is synced back to the WKWebView cookie store on each session restore.

**Part 1 — Add session_id methods to SecureStorage**

```swift
// In SecureStorage.swift
// Key format: session_{host}_{username} — scoped same as password keys (H6)
private func sessionKey(serverUrl: String, username: String) -> String {
    let host = URL(string: serverUrl)?.host ?? serverUrl
    return "session_\(host)_\(username)"
}

/// Saves the Odoo session_id cookie value to Keychain for a specific account.
func saveSessionId(serverUrl: String, username: String, sessionId: String) {
    save(key: sessionKey(serverUrl: serverUrl, username: username), value: sessionId)
}

/// Retrieves the stored session_id for an account.
func getSessionId(serverUrl: String, username: String) -> String? {
    get(key: sessionKey(serverUrl: serverUrl, username: username))
}

/// Deletes the session_id for an account (call on logout).
func deleteSessionId(serverUrl: String, username: String) {
    delete(key: sessionKey(serverUrl: serverUrl, username: username))
}
```

**Part 2 — Persist session_id to Keychain after authentication**

In `AccountRepository.authenticate(...)` after a successful `apiClient.authenticate(...)`, extract and store the session cookie:

```swift
if case .success(let auth) = result {
    // ... existing Core Data save logic ...

    // Persist password (already exists)
    secureStorage.savePassword(serverUrl: fullUrl, username: username, password: password)

    // Persist session_id to Keychain — prevents cookie file exposure on disk
    if !auth.sessionId.isEmpty {
        secureStorage.saveSessionId(serverUrl: fullUrl, username: username, sessionId: auth.sessionId)
    }
}
```

**Part 3 — Restore session to WKWebView cookie store on app launch**

`OdooWebView` currently loads the WebView and relies on `HTTPCookieStorage.shared` being populated. Instead, inject the session cookie from Keychain directly into the `WKWebsiteDataStore` cookie store before navigation begins:

```swift
// In OdooWebView or MainViewModel.loadActiveAccount()
func restoreSessionCookie(for account: OdooAccount, webView: WKWebView) {
    guard let sessionId = secureStorage.getSessionId(
        serverUrl: account.serverUrl,
        username: account.username
    ),
    let serverUrl = URL(string: account.serverUrl) else { return }

    let cookie = HTTPCookie(properties: [
        .name: "session_id",
        .value: sessionId,
        .domain: serverUrl.host ?? "",
        .path: "/",
        .secure: true,
        .sameSitePolicy: "Lax"
    ])

    guard let cookie else { return }

    webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
        // Cookie is now in the WKWebView ephemeral store — navigate
    }
}
```

**Part 4 — Intercept session_id updates**

When the user interacts with the WebView, the Odoo server may refresh the `session_id`. Intercept this via `WKHTTPCookieStoreObserver`:

```swift
// In OdooWebView or a new SessionCookieObserver class
class SessionCookieObserver: NSObject, WKHTTPCookieStoreObserver {
    private let secureStorage: SecureStorage
    private let account: OdooAccount

    init(secureStorage: SecureStorage, account: OdooAccount) {
        self.secureStorage = secureStorage
        self.account = account
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { cookies in
            if let sessionCookie = cookies.first(where: { $0.name == "session_id" }) {
                self.secureStorage.saveSessionId(
                    serverUrl: self.account.serverUrl,
                    username: self.account.username,
                    sessionId: sessionCookie.value
                )
            }
        }
    }
}
```

**Part 5 — Clear session_id on logout**

In `AccountRepository.logout(accountId:)`, add deletion of the Keychain session alongside the existing cookie clear:

```swift
// After existing clearCookies call:
if let account = account?.toDomainModel() {
    secureStorage.deleteSessionId(serverUrl: account.serverUrl, username: account.username)
}
```

**Part 6 — Exclude Cookies.binarycookies from backup (defense in depth)**

Even with Keychain storage, add backup exclusion as a defense-in-depth measure:

```swift
// Call once in AppDelegate.application(_:didFinishLaunchingWithOptions:)
private func excludeCookieFileFromBackup() {
    guard var cookieUrl = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
    cookieUrl.appendPathComponent("Cookies/Cookies.binarycookies")
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try? cookieUrl.setResourceValues(resourceValues)
}
```

### Files to Change

| File | Change |
|------|--------|
| `odoo/Data/Storage/SecureStorage.swift` | Add `sessionKey(serverUrl:username:)`, `saveSessionId`, `getSessionId`, `deleteSessionId` |
| `odoo/Data/Repository/AccountRepository.swift` | Persist session after auth; delete session on logout |
| `odoo/UI/Main/OdooWebView.swift` | Add `restoreSessionCookie` before navigation; add `SessionCookieObserver` |
| `odoo/App/AppDelegate.swift` | Add `excludeCookieFileFromBackup()` call |

---

## H4: No Privacy Overlay on App Backgrounding

### Problem Analysis

**File:** `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` (lines 91-96)

When the user presses the home button or app-switches, iOS captures a screenshot of the current view to display in the task switcher. This screenshot is stored at `Library/Caches/Snapshots/` and is visible to anyone who opens the task switcher on the device.

The current `onChange(of: scenePhase)` handler only calls `authViewModel.onAppBackgrounded()` and resets `showPin = false`. It does not add any visual overlay. The WKWebView showing Odoo business data (invoices, CRM pipelines, HR records, payroll) is captured in full fidelity.

The current code:

```swift
.onChange(of: scenePhase) { newPhase in
    if newPhase == .background {
        authViewModel.onAppBackgrounded()
        showPin = false
    }
}
```

### Security Rationale

Enterprise Odoo data is confidential. Employees routinely handle salary data, customer contact details, deal values, and inventory in the Odoo interface. A task-switcher screenshot of this data, visible to a colleague who picks up the device, is a genuine privacy incident. This is classified High for enterprise deployment — equivalent to leaving a confidential document visible on a shared screen.

### Fix

Add a `@State var showPrivacyOverlay: Bool` flag and overlay a full-screen opaque view when the app is not active. The overlay must appear on `.inactive` (not just `.background`) because iOS captures the screenshot during the transition to inactive, before the app reaches the background phase.

**In AppRootView, add the state variable and modify the body:**

```swift
struct AppRootView: View {
    @StateObject private var rootViewModel = AppRootViewModel()
    @StateObject private var authViewModel = AuthViewModel()
    @State private var showPin = false
    @State private var showPrivacyOverlay = false          // ADD THIS
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            // ... existing switch on rootViewModel.launchState ...
        }
        .overlay {                                          // ADD THIS BLOCK
            if showPrivacyOverlay {
                PrivacyOverlayView()
            }
        }
        .task {
            rootViewModel.checkSession()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .inactive, .background:                   // COVER BOTH PHASES
                showPrivacyOverlay = true
                if newPhase == .background {
                    authViewModel.onAppBackgrounded()
                    showPin = false
                }
            case .active:
                showPrivacyOverlay = false                 // REMOVE ON RETURN
            @unknown default:
                break
            }
        }
    }
}
```

**Add PrivacyOverlayView as a private struct in odooApp.swift:**

```swift
private struct PrivacyOverlayView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("Woow Odoo")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
```

Design rationale for the overlay:
- `Color(.systemBackground)` adapts to dark/light mode automatically, providing a neutral, non-jarring cover.
- A branded lock icon and app name give a professional appearance in the task switcher rather than a blank screen, which can alarm users.
- The overlay is removed on `.active` — the instant the user returns to the app, the content is visible again (there is no delay that would interfere with the biometric/PIN prompt that already appears via `authViewModel`).

### Files to Change

| File | Change |
|------|--------|
| `odoo/odooApp.swift` | Add `@State var showPrivacyOverlay`, add `.overlay { PrivacyOverlayView() }`, expand `onChange` to cover `.inactive`, add `PrivacyOverlayView` struct |

---

## H5: Theme Mode Not Applied to UI

### Problem Analysis

**Files:**
- `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift`
- `/Users/alanlin/Woow_odoo_ios/odoo/UI/Theme/WoowTheme.swift`

`WoowTheme.themeMode` is an `@Published var themeMode: ThemeMode = .system`. `SettingsViewModel.updateThemeMode(_:)` calls `theme.setThemeMode(mode)` which updates `themeMode` and persists it to Keychain. However, **nothing in the view hierarchy observes `WoowTheme.themeMode` and applies it as a `.preferredColorScheme()` modifier**. The `@Published` property change fires but no view is subscribed to react to it.

`ThemeMode` is assumed to have (at minimum) `.system`, `.light`, `.dark` cases.

### Security Rationale

This is primarily a functionality bug rather than a security issue, but it is classified H5 in the security plan because: (1) users who select dark mode may be doing so for reduced screen visibility in sensitive contexts (reducing shoulder-surfing); (2) broken settings erode user trust in the app's security controls overall. An app where one setting visibly does nothing makes users doubt whether security settings (biometric, PIN, app lock) are actually working.

### Fix

`AppRootView` must observe `WoowTheme.shared` and apply `.preferredColorScheme()` based on `themeMode`. The `WoowTheme` instance needs to be injected as a `@StateObject` or `@ObservedObject` at the root level.

**In `odooApp.swift`, inject `WoowTheme` into `AppRootView`:**

```swift
struct AppRootView: View {
    @StateObject private var rootViewModel = AppRootViewModel()
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var theme = WoowTheme.shared     // ADD THIS (ObservableObject)
    @State private var showPin = false
    @State private var showPrivacyOverlay = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            // ... existing content unchanged ...
        }
        .overlay { /* H4 privacy overlay */ }
        .preferredColorScheme(theme.themeMode.colorScheme) // ADD THIS
        .task { rootViewModel.checkSession() }
        .onChange(of: scenePhase) { /* ... */ }
    }
}
```

**Add `colorScheme` computed property to `ThemeMode`:**

`ThemeMode` is likely an enum. Add an extension (or add it to the enum definition if owned by this module):

```swift
extension ThemeMode {
    /// Maps the user's theme preference to a SwiftUI ColorScheme.
    /// Returns nil for .system so iOS uses the system setting naturally.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
```

`preferredColorScheme(nil)` is the correct way to opt into system behavior — SwiftUI treats `nil` as "follow system," which is the intended behavior for `.system` mode.

**Why `@StateObject` for `WoowTheme.shared` works here:**

`@StateObject` takes a closure that is called once to create the object. Passing `.shared` means the app root and the `SettingsViewModel` reference the same instance. When `SettingsViewModel.updateThemeMode(_:)` calls `theme.setThemeMode(mode)`, it updates `themeMode` on the same `WoowTheme` instance that `AppRootView` is observing — `@Published` fires `objectWillChange`, causing `AppRootView.body` to recompute, and `.preferredColorScheme(theme.themeMode.colorScheme)` applies the new value.

Note: The existing singleton (`WoowTheme.shared`) and dual-write path between `SettingsViewModel` and `WoowTheme` are identified as L7 (architectural debt). This H5 fix works correctly with the current singleton pattern without requiring the L7 refactor.

### Files to Change

| File | Change |
|------|--------|
| `odoo/odooApp.swift` | Add `@StateObject private var theme = WoowTheme.shared`; add `.preferredColorScheme(theme.themeMode.colorScheme)` modifier |
| `odoo/UI/Theme/ThemeMode.swift` (or wherever `ThemeMode` is defined) | Add `var colorScheme: ColorScheme?` computed property |

---

## Implementation Order and Dependencies

```
H1 (remove deadlock)              — no dependencies, fix first
H6 (Keychain key format)          — no dependencies on H1-H5; fix before H3
H2 (DeepLinkValidator)            — depends on OdooAccount.serverHost (check model first)
H3 (session cookie to Keychain)   — depends on H6 key format being established
H4 (privacy overlay)              — no dependencies; can be done in parallel with H2/H3
H5 (theme mode)                   — no dependencies; can be done in parallel with H2/H3
```

The recommended implementation sequence for a single developer is:

1. **H1** (2h): Remove the semaphore — immediately eliminates the freeze risk. Tests pass with no behavioral change since `HTTPCookieStorage` is already synchronous.
2. **H6** (2h): Rekeying Keychain entries before H3 adds new Keychain keys prevents key-format inconsistency between password and session entries.
3. **H2** (1h): Tighten the validator and wire real serverHost into call sites.
4. **H3** (3h): Keychain-backed session storage, WebView cookie injection, observer.
5. **H4** (1h): Privacy overlay — cosmetic but high-visibility; easy confidence boost.
6. **H5** (1h): Wire `.preferredColorScheme` — also cosmetic but breaks a user-facing promise.

---

## Cross-Fix Interaction Map

| Fix | Touches | Interaction |
|-----|---------|-------------|
| H1 | `AccountRepository.getSessionId` | H3 also modifies session retrieval path — ensure H3 does not reintroduce a `Task`-wrapped read |
| H6 | `SecureStorage` password key format | H3 uses the same key-construction helper (`sessionKey` mirrors `passwordKey`) — define the helper once |
| H2 | `DeepLinkValidator`, `AppDelegate`, `odooApp` | H4 modifies `odooApp.swift` `.onChange` — apply both changes in the same PR to avoid merge conflicts |
| H3 | `OdooWebView`, `AccountRepository`, `SecureStorage` | H6 changes `deletePassword` signature — H3's logout change must use the new H6 signature |
| H4 | `odooApp.swift` `AppRootView` | H5 also adds to `AppRootView` — implement both in the same file edit to avoid structural conflict |
| H5 | `AppRootView`, `ThemeMode` | Independent of H1-H4 at the code level |

---

## Files Modified Summary

| File | H1 | H2 | H3 | H4 | H5 | H6 |
|------|----|----|----|----|----|----|
| `odoo/Data/Repository/AccountRepository.swift` | Yes | | Yes | | | Yes |
| `odoo/Data/Storage/SecureStorage.swift` | | | Yes | | | Yes |
| `odoo/Data/Push/DeepLinkValidator.swift` | | Yes | | | | |
| `odoo/App/AppDelegate.swift` | | Yes | Yes | | | |
| `odoo/odooApp.swift` | | Yes | | Yes | Yes | |
| `odoo/UI/Main/OdooWebView.swift` | | | Yes | | | |
| `odoo/UI/Theme/ThemeMode.swift` | | | | | Yes | |
| `odoo/Domain/OdooAccount.swift` | | Yes | | | | |

---

## Test Cases Per Fix

### H1 Tests

- `AccountRepositoryTests.test_getSessionId_doesNotDeadlock_whenCalledFromMainActor()` — call from `@MainActor` context, assert returns within 100ms
- `AccountRepositoryTests.test_getSessionId_returnsNil_whenNoCookieExists()`
- `AccountRepositoryTests.test_getSessionId_returnsValue_whenCookiePresent()`

### H2 Tests

- `DeepLinkValidatorTests.test_rejectsWebPathWithDotDot()` — `/web/../admin` must be rejected
- `DeepLinkValidatorTests.test_rejectsWebPathWithAtSign()` — `/web@evil.com` must be rejected
- `DeepLinkValidatorTests.test_acceptsCanonicalWebPath()` — `/web`, `/web/`, `/web#action=1`, `/web?debug=1`
- `DeepLinkValidatorTests.test_rejectsAbsoluteUrl_whenServerHostEmpty()` — `serverHost: ""` must reject absolute URLs
- `DeepLinkValidatorTests.test_rejectsWebsitePath()` — `/website/shop` must be rejected (not a canonical Odoo web path)
- `AppDelegateTests.test_handleNotificationTap_doesNotSetPending_forMaliciousWebPath()`

### H3 Tests

- `SecureStorageTests.test_saveSessionId_andRetrieve()`
- `SecureStorageTests.test_deleteSessionId_removesFromKeychain()`
- `AccountRepositoryTests.test_authenticate_savesSessionIdToKeychain()`
- `AccountRepositoryTests.test_logout_deletesSessionIdFromKeychain()`

### H4 Tests

- `AppRootViewTests.test_privacyOverlay_appearsOnInactivePhase()` — snapshot test showing overlay
- `AppRootViewTests.test_privacyOverlay_disappearsOnActivePhase()`

### H5 Tests

- `AppRootViewTests.test_preferredColorScheme_dark_whenThemeModeDark()`
- `AppRootViewTests.test_preferredColorScheme_nil_whenThemeModeSystem()`
- `ThemeModeTests.test_colorScheme_returnsCorrectMapping()`

### H6 Tests

- `SecureStorageTests.test_passwordKey_isUniqueAcrossServers()` — `pwd_server-a.odoo.com_admin` != `pwd_server-b.odoo.com_admin`
- `SecureStorageTests.test_migratePasswordKeys_copiesLegacyKey_andDeletesOld()`
- `SecureStorageTests.test_migratePasswordKeys_isIdempotent()` — call twice, no duplication
- `AccountRepositoryTests.test_switchAccount_usesServerScopedPassword()`
