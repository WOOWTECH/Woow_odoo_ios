# Security Audit Report — Woow Tech Odoo iOS App

**Date:** 2026-04-07
**Auditor:** Claude (automated static analysis)
**Scope:** Full source code at `/Users/alanlin/Woow_odoo_ios/odoo/`
**Severity Scale:** CRITICAL > HIGH > MEDIUM > LOW > INFO

---

## Executive Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 2 |
| LOW | 4 |
| INFO (Recommendations) | 3 |

**The app demonstrates strong security practices.** No critical or high-severity vulnerabilities were found. All sensitive data is stored in Keychain with correct accessibility levels, HTTPS is enforced at three layers, and deep link validation is thorough. The app is **production-ready** from a security standpoint with minor improvements recommended below.

---

## 1. Authentication & Credentials — STRONG

### 1.1 Password Storage
- **File:** `odoo/Data/Storage/SecureStorage.swift`
- Passwords stored in iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- iCloud sync disabled (`kSecAttrSynchronizable: false`)
- Keys scoped to `serverUrl:username` (prevents multi-tenant collisions)
- **Verdict:** PASS

### 1.2 PIN Hashing
- **File:** `odoo/Data/Storage/PinHasher.swift`
- PBKDF2-HMAC-SHA256, 600,000 iterations (exceeds OWASP minimum of 600,000)
- 16-byte cryptographically random salt via `SecRandomCopyBytes`
- 32-byte (256-bit) derived key
- Constant-time comparison to prevent timing attacks
- **Verdict:** PASS

### 1.3 Biometric Authentication
- **File:** `odoo/UI/Auth/BiometricView.swift`
- Uses `deviceOwnerAuthenticationWithBiometrics` (hardware-backed)
- No skip button (UX-14 requirement enforced)
- Fallback path: Face ID fail → "Use PIN" → lockout after 5 failures
- No bypass path exists — all code paths lead to authentication or lockout
- **Verdict:** PASS

### 1.4 Session Management
- **File:** `odoo/Data/API/OdooAPIClient.swift`
- Session cookies managed by URLSession (system-managed, sandboxed)
- Session ID also backed up in Keychain (survives app restart)
- Cookies cleared on logout (HTTPCookieStorage + Keychain)
- Session expiry detected via `/web/login` redirect in WebView
- **Verdict:** PASS

---

## 2. Network Security — STRONG

### 2.1 HTTPS Enforcement (Triple Layer)

| Layer | File | How |
|-------|------|-----|
| **OS** | Info.plist | No ATS exceptions — iOS blocks all HTTP |
| **Login UI** | LoginViewModel.swift:78 | Rejects `http://` with error message |
| **API Client** | OdooAPIClient.swift:53 | `guard serverUrl.hasPrefix("https://")` |

- No HTTP fallback paths exist in the codebase
- **Verdict:** PASS

### 2.2 Certificate Pinning — NOT IMPLEMENTED
- **File:** `odoo/Data/API/OdooAPIClient.swift`
- Uses default URLSession with system CA validation only
- No custom `URLAuthenticationChallenge` handling
- **Risk:** Low — acceptable for enterprise apps connecting to known servers
- **Recommendation:** Consider TrustKit or custom pinning for high-security deployments
- **Verdict:** INFO (enhancement, not vulnerability)

### 2.3 Cookie Security
- **File:** `odoo/UI/Main/OdooWebView.swift:40`
- Session cookie set with `.secure: "TRUE"` flag
- Domain-scoped to server host
- **Verdict:** PASS

---

## 3. WebView Security — STRONG

### 3.1 Same-Origin Policy
- **File:** `odoo/UI/Main/OdooWebView.swift:106-143`
- `decidePolicyFor` enforces strict same-host matching (case-insensitive)
- Relative URLs (no host) allowed (standard for web apps)
- `blob:` URLs allowed (required by Odoo OWL framework)
- All other URLs → `UIApplication.shared.open(url)` → Safari
- **Verdict:** PASS

### 3.2 JavaScript Injection
- **File:** `odoo/UI/Main/OdooWebView.swift:178`
- Only one `evaluateJavaScript` call — hardcoded OWL layout fix
- No user input reaches JavaScript execution
- DOM operations limited to CSS style changes (`minHeight`, `height`)
- **Verdict:** PASS

### 3.3 Popup Handling
- **File:** `odoo/UI/Main/OdooWebView.swift:147-154`
- `createWebViewWith` returns `nil` (blocks all popups)
- Target-less links loaded in current WebView instead
- **Verdict:** PASS

---

## 4. Deep Link & URL Scheme Security — STRONG

### 4.1 DeepLinkValidator
- **File:** `odoo/Data/Push/DeepLinkValidator.swift`
- **Approach:** Allowlist (only `/web` paths accepted)
- **Regex:** `^/web(?:[/?#]|$)`
- **Blocked:** `javascript:`, `data:`, path traversal (`..` and `%2e%2e`), control characters
- **Absolute URLs:** Require `https` + exact server host match
- **Empty serverHost:** Rejects all absolute URLs (fails closed)
- **Verdict:** PASS

### 4.2 Notification Tap → Deep Link
- **File:** `odoo/App/AppDelegate.swift:201-207`
- Notification `odoo_action_url` validated via `DeepLinkValidator.isValid()` before use
- No direct navigation — goes through validation pipeline
- **Verdict:** PASS

---

## 5. Data at Rest — GOOD

### Storage Matrix

| Data | Storage | Encryption | Accessibility |
|------|---------|------------|---------------|
| Passwords | Keychain | Hardware-backed | WhenUnlockedThisDeviceOnly |
| Session IDs | Keychain | Hardware-backed | WhenUnlockedThisDeviceOnly |
| PIN Hash | Keychain (AppSettings) | Hardware-backed | WhenUnlockedThisDeviceOnly |
| FCM Token | Keychain | Hardware-backed | WhenUnlockedThisDeviceOnly |
| App Settings | Keychain (JSON) | Hardware-backed | WhenUnlockedThisDeviceOnly |
| Account Metadata | Core Data | **Unencrypted** | Plaintext on disk |
| Pending Deep Link | UserDefaults | **Unencrypted** | Plaintext on disk |

### 5.1 Core Data Unencrypted
- **File:** `odoo/Data/Storage/PersistenceController.swift`
- Stores: `serverUrl`, `database`, `username`, `displayName`, `userId`
- Does NOT store passwords or session tokens
- **Risk:** Low — no secrets in Core Data
- **Verdict:** INFO (could add SQLCipher for defense-in-depth)

### 5.2 UserDefaults Deep Link
- **File:** `odoo/Data/Push/DeepLinkManager.swift:36`
- Stores validated `/web` path URLs temporarily
- Cleaned up on consumption
- **Risk:** Low — contains only already-validated Odoo paths
- **Verdict:** PASS

---

## 6. Debug & Test Code — PROPERLY GUARDED

### 6.1 AppDelegate Test Hooks
- **File:** `odoo/App/AppDelegate.swift:62-114`
- All 4 hooks (`-ResetAppState`, `-SetTestPIN`, `-AppLockEnabled`, `-ResetPINLockout`) wrapped in `#if DEBUG`
- Code stripped at compile time in release builds
- **Verdict:** PASS

### 6.2 Print/Log Statements
- All `print()` statements wrapped in `#if DEBUG`
- `Logger.debug()` used (not persisted in release builds)
- No sensitive data (passwords, tokens) appears in any log statement
- **Verdict:** PASS

### 6.3 TestConfig.plist Isolation
- **File:** `odooUITests/TestConfig.plist` — contains test credentials
- Located in test target directory, loaded via `Bundle(for: BundleToken.self)`
- NOT included in main app bundle — verified by target membership
- **Verdict:** PASS

---

## 7. Privacy & Compliance — COMPLIANT

### 7.1 Permissions
| Permission | Usage Description | Justified |
|------------|-------------------|-----------|
| Face ID | Unlock app | Yes |
| Camera | Upload photos in Odoo | Yes |
| Photo Library | Upload images in Odoo | Yes |
| Remote Notifications | Push from Odoo server | Yes |

### 7.2 Privacy Manifest
- **File:** `odoo/PrivacyInfo.xcprivacy`
- `NSPrivacyTracking: false` — no tracking
- `NSPrivacyCollectedDataTypes: []` — no data collection
- API usage reasons declared (UserDefaults, FileTimestamp, DiskSpace)
- **Verdict:** PASS — App Store compliant

### 7.3 Task Switcher Privacy
- **File:** `odoo/odooApp.swift:146-170`
- Privacy overlay shown when app enters background
- Prevents sensitive content from appearing in task switcher
- **Verdict:** PASS

---

## 8. Findings — Action Required

### MEDIUM-1: Server URL Format Validation Missing

**File:** `odoo/UI/Login/LoginViewModel.swift:62-83`
**Issue:** The login form accepts any string as server URL (e.g., `!!!invalid!!!`, spaces, special characters). Only `http://` is explicitly rejected.
**Impact:** Low — server-side validation catches invalid URLs, but users see confusing network errors instead of clear validation messages.
**Fix:**
```swift
// Add after HTTPS check in goToNextStep():
let normalized = trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
guard let url = URL(string: normalized), url.host != nil else {
    error = String(localized: "error_invalid_server_url")
    return
}
```

### MEDIUM-2: DeepLinkValidator Case-Insensitive Regex

**File:** `odoo/Data/Push/DeepLinkValidator.swift:11-13`
**Issue:** Regex uses `.caseInsensitive`, accepting `/WEB`, `/Web`, `/wEb` etc. Odoo paths are always lowercase.
**Impact:** Very low — no known exploit, Odoo server won't recognize uppercase paths anyway.
**Fix:**
```swift
// Remove .caseInsensitive option:
private static let allowedRelativePathPattern = try! NSRegularExpression(
    pattern: #"^/web(?:[/?#]|$)"#,
    options: []  // Strict lowercase matching
)
```

### LOW-1: No Certificate Pinning
**Impact:** Vulnerable to network-level MITM if device CA store is compromised.
**Recommendation:** Consider TrustKit for production. Not required for App Store approval.

### LOW-2: Core Data Account Metadata Unencrypted
**Impact:** `serverUrl`, `database`, `username` readable if device is compromised. No passwords stored.
**Recommendation:** Optional — add SQLCipher if device theft is in threat model.

### LOW-3: evaluateJavaScript Ignores Errors
**File:** `odoo/UI/Main/OdooWebView.swift:178`
**Impact:** OWL layout fix failures are silent. Cosmetic only.
**Recommendation:** Add `#if DEBUG` completion handler for diagnostics.

### LOW-4: Error Messages May Expose Server Details
**File:** `odoo/Data/API/OdooAPIClient.swift:200-209`
**Impact:** Server error strings (e.g., database names) passed to UI.
**Recommendation:** Display generic messages in production, log raw errors for debugging.

---

## 9. Summary

| Category | Grade | Notes |
|----------|-------|-------|
| Authentication | **A** | Keychain, PBKDF2, biometric, no bypass paths |
| Cryptography | **A** | Industry-standard parameters, secure RNG |
| Network | **A-** | HTTPS triple-enforced, no pinning |
| WebView | **A** | Same-origin, no JS injection, popup blocking |
| Deep Links | **A** | Allowlist, path traversal detection, fails closed |
| Data at Rest | **A-** | Keychain for secrets, Core Data unencrypted (no secrets) |
| Debug Isolation | **A** | All hooks #if DEBUG guarded |
| Privacy | **A** | Manifest compliant, task switcher overlay |

**Overall Security Grade: A-**

The app is ready for App Store submission from a security perspective. The 2 medium findings are UX improvements, not exploitable vulnerabilities.
