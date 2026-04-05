# Comprehensive Remaining Work Audit -- WoowTech Odoo iOS App

**Date:** 2026-04-05
**Auditor:** Claude Code (automated source-level verification)
**Method:** Cross-referenced M1-M10 milestone plans, 82-item functional-equivalence matrix, auto-login plan (S1-S7), and actual iOS source code in `/Users/alanlin/Woow_odoo_ios/odoo/`

---

## Executive Summary

The functional-equivalence matrix claims 82/82 items DONE. **This is inaccurate.** Source-level verification reveals **24 distinct work items** across blockers, high-priority, medium, and low categories. The most critical findings are:

1. **Config screen is built but not wired** -- menu button in MainView is a no-op
2. **All UI strings are hardcoded English** -- localization files exist but are never referenced
3. **DispatchSemaphore deadlock** still present in production code
4. **DeepLinkValidator bypass** still exploitable (empty serverHost)
5. **No PrivacyInfo.xcprivacy** -- Apple will reject the binary
6. **No app icon images** -- AppIcon.appiconset has the manifest but zero PNG files
7. **No privacy overlay on app backgrounding** -- WebView content visible in task switcher
8. **No AppRouter** -- navigation is ad-hoc, not the planned AppRoute enum
9. **Theme mode (dark/light) is persisted but never applied** -- no `preferredColorScheme` modifier
10. **Remember Me checkbox exists in ViewModel but not in LoginView UI**

---

## BLOCKERS (Must Fix Before App Store Submission)

### B1: PrivacyInfo.xcprivacy Missing

- **What:** Apple requires a privacy manifest since Spring 2024. M1 plan explicitly lists it. File does not exist anywhere in the project.
- **Files:** Need to create `odoo/PrivacyInfo.xcprivacy`
- **Impact:** App Store Connect will reject the binary upload.
- **Plan doc:** M1 milestone (line ~274), M10 milestone (line ~753)
- **Effort:** 30 minutes
- **Details:** Must declare UserDefaults API usage (C617.1), Keychain access, and any required reason API categories.

### B2: App Icon Images Missing

- **What:** `Assets.xcassets/AppIcon.appiconset/Contents.json` defines three slots (light, dark, tinted) but contains zero actual PNG files. The `"filename"` key is absent from all entries.
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/Assets.xcassets/AppIcon.appiconset/`
- **Impact:** App Store requires a 1024x1024 app icon. TestFlight will show a blank grid icon.
- **Plan doc:** M10 milestone (line ~738)
- **Effort:** 1 hour (design + export + configure)

### B3: Info.plist Missing Required Keys

- **What:** The following keys are planned in M1 but absent from `Info.plist`:
  - `NSFaceIDUsageDescription` -- required for Face ID; app will crash on first biometric prompt without it
  - `NSCameraUsageDescription` -- required if WebView can use camera (file upload)
  - `NSPhotoLibraryUsageDescription` -- required if WebView can access photos
  - `CFBundleLocalizations` -- required for per-app language switching (iOS 16+); without this, the language option will not appear in iOS Settings > Apps > Woow Odoo
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/Info.plist`
- **Impact:** App crash on Face ID. App Store rejection for missing usage descriptions. Language switching silently broken.
- **Plan doc:** M1 milestone (line ~267), M8 milestone (line ~649)
- **Effort:** 15 minutes

### B4: Config Screen Not Wired (Menu Button is No-Op)

- **What:** `odooApp.swift` line 77-78 contains a comment `// Will navigate to Config in M7` inside the `onMenuClick` closure. The closure body is empty. `ConfigView.swift` and `ConfigViewModel.swift` exist and are fully implemented, but there is no navigation path to reach them from MainView.
- **Files:**
  - `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` (line 77-78)
  - `/Users/alanlin/Woow_odoo_ios/odoo/UI/Config/ConfigView.swift` (exists, not navigable)
  - `/Users/alanlin/Woow_odoo_ios/odoo/UI/Settings/SettingsView.swift` (exists, not navigable)
- **Impact:** Users cannot access Settings, account switching, logout, theme, security, or any configuration. The app is effectively a login-only WebView wrapper with no settings access.
- **Plan doc:** M7 milestone
- **Effort:** 2-3 hours (need NavigationStack/sheet integration from AppRootView through MainView to ConfigView to SettingsView)

### B5: All UI Strings Hardcoded -- Localization Files Not Used

- **What:** Three `Localizable.strings` files exist (`en.lproj`, `zh-Hans.lproj`, `zh-Hant.lproj`) with 67 keys. However, **zero** references to `String(localized:)`, `NSLocalizedString()`, or `LocalizedStringKey` exist in any Swift source file. Every displayed string is a hardcoded English literal (e.g., `Text("Settings")`, `Text("WoowTech Odoo")`, `error = "Server URL is required"`).
- **Files:** All View and ViewModel files under `/Users/alanlin/Woow_odoo_ios/odoo/UI/`
- **Impact:** The app will always display English regardless of system language. This breaks UX-58 through UX-62 (language switching). The matrix claims 5/5 DONE -- this is false.
- **Plan doc:** M8 milestone (line ~641)
- **Effort:** 4-6 hours (audit all ~100+ string literals across 15+ files, replace with localized keys, verify zh-Hans and zh-Hant coverage)

---

## HIGH PRIORITY (Must Fix Before Public Beta)

### H1: DispatchSemaphore Deadlock in AccountRepository (S1)

- **What:** `AccountRepository.getSessionId(for:)` at line 196-207 uses `DispatchSemaphore` to synchronously wait for an `async` `Task`. If called from the main thread (which it is -- `MainViewModel.loadActiveAccount()` calls it), this **will deadlock** because the Task needs the main thread to complete, but the semaphore is blocking it.
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/Data/Repository/AccountRepository.swift` (lines 196-207)
- **Impact:** App freeze on any account load. Currently "works" only because the Task happens to complete before the main thread blocks, but this is a race condition that will fail under load or on slower devices.
- **Plan doc:** Auto-login plan S1 (severity: Critical)
- **Effort:** 1 hour (convert to `async`, propagate async to `MainViewModel`)

### H2: DeepLinkValidator Bypass via Empty serverHost (S2)

- **What:** `DeepLinkValidator.isValid(url:serverHost:)` is called with `serverHost: ""` in three locations:
  - `odooApp.swift` line 32
  - `AppDelegate.swift` line 126
  - The validator's same-host check (`urlHost.caseInsensitiveCompare(serverHost)`) will fail for any absolute URL when serverHost is empty, which is the correct defensive behavior. However, the `AppDelegate` line 126 has a short-circuit: `actionUrl.hasPrefix("/web") || DeepLinkValidator.isValid(...)` which means ANY URL starting with `/web` bypasses validation entirely, including `/web@evil.com` or `/web\ninjected-header`. The validator itself allows all `/web*` prefixes too (documented in test line 118: `/website/shop` is accepted).
- **Files:**
  - `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` (line 32)
  - `/Users/alanlin/Woow_odoo_ios/odoo/App/AppDelegate.swift` (line 126)
  - `/Users/alanlin/Woow_odoo_ios/odoo/Data/Push/DeepLinkValidator.swift`
- **Impact:** Malicious push notification could inject a URL like `/web/../../../admin` or leverage the overly broad `/web*` prefix matching.
- **Plan doc:** Auto-login plan S2 (severity: High)
- **Effort:** 2 hours (add strict regex allowlist for `/web#action=...` patterns, pass actual serverHost from active account)

### H3: Session Cookie in Plaintext HTTPCookieStorage (S3)

- **What:** The Odoo `session_id` cookie is stored in iOS's `HTTPCookieStorage.shared`, which persists cookies to the unencrypted file `Cookies.binarycookies` on disk. This file is accessible to anyone with physical access to a jailbroken device or an iTunes backup.
- **Files:**
  - `/Users/alanlin/Woow_odoo_ios/odoo/Data/API/OdooAPIClient.swift` (lines 160-175)
  - `/Users/alanlin/Woow_odoo_ios/odoo/UI/Main/OdooWebView.swift` (line 36)
- **Impact:** Session hijacking risk on compromised devices.
- **Plan doc:** Auto-login plan S3 (severity: High)
- **Effort:** 3 hours (migrate session_id to Keychain, sync to WKWebView ephemeral cookie store)

### H4: No Privacy Overlay on App Backgrounding (S5)

- **What:** When the user switches apps, iOS captures a screenshot of the current screen for the task switcher. The WebView showing Odoo data (potentially containing sensitive business data like invoices, contacts, salaries) is fully visible. No blur/overlay is applied on `sceneWillResignActive` or `.background` phase.
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` (`.onChange(of: scenePhase)` only resets auth state, does not add visual overlay)
- **Impact:** Sensitive Odoo data visible in iOS task switcher to anyone who can see the screen.
- **Plan doc:** Auto-login plan S5 (severity: Medium, but I'm elevating to High for enterprise use)
- **Effort:** 1 hour (add a privacy overlay view that appears when `scenePhase == .background` or `.inactive`)

### H5: Theme Mode Not Applied to UI

- **What:** `WoowTheme` persists `themeMode` (system/light/dark) and `SettingsView` lets users toggle it, but **no `.preferredColorScheme()` modifier** is applied anywhere in the view hierarchy. The app always follows the system setting regardless of the user's choice.
- **Files:**
  - `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` -- no `.preferredColorScheme` on root view
  - `/Users/alanlin/Woow_odoo_ios/odoo/UI/Theme/WoowTheme.swift` -- stores `themeMode` but nothing reads it for rendering
- **Impact:** UX-53 (theme mode switching) is broken. User selects "Dark" but nothing changes.
- **Plan doc:** M7 milestone
- **Effort:** 30 minutes (add `.preferredColorScheme` computed from `WoowTheme.themeMode` on the root view)

### H6: Keychain Password Key Not Scoped to Server (Multi-Account Bug)

- **What:** `SecureStorage.savePassword(accountId:)` uses key `pwd_{username}`. If user "admin" exists on two different Odoo servers, they share the same Keychain key and one overwrites the other.
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/Data/Storage/SecureStorage.swift` (line 27: `save(key: "pwd_\(accountId)")`)
- **Impact:** Multi-account users lose passwords when switching between servers with the same username.
- **Plan doc:** Auto-login plan "Multi-Account Scalability" section (explicitly noted: needs `pwd_{serverUrl}_{username}`)
- **Effort:** 1 hour (change key format, migrate existing keys)

---

## MEDIUM PRIORITY (Feature Completeness)

### M1: AppRouter / Navigation Architecture Missing

- **What:** M4 milestone plans an `AppRouter.swift` with `NavigationPath`, `AppRoute` enum (`.splash`, `.login`, `.auth`, `.pin`, `.main`, `.config`, `.settings`), and proper navigation stack management. This was never implemented. Instead, navigation is done via ad-hoc `@State` booleans and closures. The app has no navigation graph.
- **Files:** No `AppRouter.swift` exists. Navigation is scattered across `odooApp.swift` with inline closure callbacks.
- **Impact:** No back-stack management, no deep link routing through navigation, no testable navigation.
- **Plan doc:** M4 milestone (line ~411-414)
- **Effort:** 4-6 hours

### M2: Remember Me Checkbox Not in UI

- **What:** `LoginViewModel` has `@Published var rememberMe: Bool = true` but `LoginView.swift` has no Toggle/Checkbox for it. The value is always `true` and never user-controllable.
- **Files:**
  - `/Users/alanlin/Woow_odoo_ios/odoo/UI/Login/LoginViewModel.swift` (line 21)
  - `/Users/alanlin/Woow_odoo_ios/odoo/UI/Login/LoginView.swift` (no reference to rememberMe)
- **Impact:** UX-07 ("Check Remember Me -- Password saved encrypted") is partially broken. Password is always saved, user cannot opt out.
- **Plan doc:** Functional-equivalence matrix UX-07
- **Effort:** 30 minutes

### M3: Core Data Not Encrypted at Rest (S4)

- **What:** The Core Data persistent store uses default `NSPersistentContainer` with no file protection. `NSFileProtectionCompleteUntilFirstUserAuthentication` is not set.
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/Data/Storage/PersistenceController.swift`
- **Impact:** Account data (server URL, database, username, display name) readable from unencrypted SQLite file on jailbroken device.
- **Plan doc:** Auto-login plan S4 (severity: Medium)
- **Effort:** 30 minutes

### M4: Deep Link Lost on Session Expiry (S6)

- **What:** If a deep link URL is pending and the session expires, `consume()` clears the URL, then the app routes to LoginView. The deep link is lost. The auto-login plan notes this as S6 and recommends re-enqueuing the URL before routing to login.
- **Files:**
  - `/Users/alanlin/Woow_odoo_ios/odoo/Data/Push/DeepLinkManager.swift`
  - `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` (session expiry handler)
- **Impact:** User taps notification, session has expired, logs in again, but the deep link target is gone.
- **Plan doc:** Auto-login plan S6 (severity: Medium)
- **Effort:** 30 minutes

### M5: `.task` Cancellation on Background During Splash (S7)

- **What:** If the user backgrounds the app during the splash/loading state, the `.task` modifier in `AppRootView` may be cancelled, leaving `launchState` stuck at `.loading` forever. No retry or `onChange(of: scenePhase)` guard exists.
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` (line 88-89)
- **Impact:** Edge case: app stuck on spinner if backgrounded at exactly the wrong moment.
- **Plan doc:** Auto-login plan S7 (severity: Low, but I'm raising it because it causes permanent freeze)
- **Effort:** 15 minutes

### M6: AppLogger Not Implemented

- **What:** M1 milestone plans `AppLogger.swift` using `os.Logger` with subsystem-based logging and privacy-safe release builds. File does not exist. Debug logging uses raw `print()` statements guarded by `#if DEBUG`. Production builds have no structured logging at all.
- **Files:** No `AppLogger.swift` exists. `print()` calls in 8+ files.
- **Impact:** No production diagnostics. No structured log categories. No privacy annotation for logs.
- **Plan doc:** M1 milestone (line ~271)
- **Effort:** 2 hours (create AppLogger, replace all print() calls)

### M7: iPad Polish Absent

- **What:** M8 plans iPad-specific layout work including `NavigationSplitView` for Config, wider layouts, landscape testing, and split-view multitasking support. The only iPad accommodation in the codebase is `LoginView`'s `.frame(maxWidth: 500)`. No `horizontalSizeClass`, `NavigationSplitView`, or iPad-specific code exists anywhere.
- **Files:** All UI files -- only one iPad mention in `/Users/alanlin/Woow_odoo_ios/odoo/UI/Login/LoginView.swift` (line 51)
- **Impact:** ConfigView, SettingsView, BiometricView, PinView will render full-width on 13" iPad with no adaptive layout.
- **Plan doc:** M8 milestone (line ~656-661)
- **Effort:** 4-6 hours

### M8: No Launch Screen

- **What:** No `LaunchScreen.storyboard` or `Launch Screen.storyboard` file exists. No SwiftUI launch screen configuration in Info.plist. iOS will show a white/black screen during app launch.
- **Files:** None found
- **Impact:** Poor first impression. Professional apps should have a branded launch screen.
- **Plan doc:** Not explicitly in milestones but standard for M10 App Store prep.
- **Effort:** 1 hour

---

## LOW PRIORITY (Polish)

### L1: Test Coverage Gap -- 238 vs 120+ Target

- **What:** M9 targets 120+ unit tests. Current count across all test files is 238 (`func test` matches), so the count target is met. However, several planned test classes are missing:
  - `SettingsViewModelTests` -- only 7 tests in `SettingsGapTests.swift`, not the planned 15
  - `SettingsRepositoryTests` -- no dedicated file (some coverage in `MissingTests.swift`)
  - `CacheServiceTests` -- no dedicated file
  - `PushTokenRepositoryTests` -- no dedicated file
  - `WoowColorsTests` -- no dedicated file
  - `NotificationServiceTests` -- no dedicated file
  - XCUITest count: 36 (`func test` matches), but no structured test plan file
- **Files:** `/Users/alanlin/Woow_odoo_ios/odooTests/`
- **Impact:** Missing coverage for push, cache, colors, and settings repository.
- **Plan doc:** M9 milestone (line ~686-698)
- **Effort:** 4-6 hours

### L2: MainPlaceholderView Still in Production Code

- **What:** `odooApp.swift` contains `MainPlaceholderView` (lines 101-117), a development placeholder from before M5 was implemented. It includes text "WKWebView will be here in M5". Dead code that should be removed.
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` (lines 101-117)
- **Impact:** Dead code, no functional impact.
- **Effort:** 5 minutes

### L3: No App Store Screenshots

- **What:** M10 requires screenshots for iPhone 6.9", 6.7", and iPad 13". No screenshot files or fastlane snapshot configuration exists.
- **Plan doc:** M10 milestone (line ~739-743)
- **Effort:** 2-3 hours

### L4: No App Review Notes Document

- **What:** M10 requires a document listing native features to avoid Apple's 4.2 rejection ("minimum functionality" for WebView wrappers). No such document exists.
- **Plan doc:** M10 milestone (line ~744-747)
- **Effort:** 1 hour

### L5: No Fastlane Setup

- **What:** M10 lists fastlane as optional but recommended for CI/CD automation.
- **Plan doc:** M10 milestone (line ~757-759)
- **Effort:** 2-3 hours

### L6: DeepLinkManager Uses Singleton Pattern

- **What:** `DeepLinkManager.shared` is a singleton, making it difficult to test in isolation and violating the auto-login plan's note that multi-account needs `(accountId, url)` tuple storage.
- **Files:** `/Users/alanlin/Woow_odoo_ios/odoo/Data/Push/DeepLinkManager.swift`
- **Impact:** Architectural debt. Tests work around it with injected `UserDefaults`.
- **Effort:** 1 hour

### L7: WoowTheme Uses Singleton Pattern

- **What:** `WoowTheme.shared` with internal `SettingsRepository()` is not injectable. `SettingsViewModel` also creates its own `WoowTheme` reference, creating dual-write paths for theme settings.
- **Files:**
  - `/Users/alanlin/Woow_odoo_ios/odoo/UI/Theme/WoowTheme.swift` (line 7, 12-13)
  - `/Users/alanlin/Woow_odoo_ios/odoo/UI/Settings/SettingsViewModel.swift` (line 29-30 writes directly to `SecureStorage.shared`)
- **Impact:** Theme settings can get out of sync between `WoowTheme` and `SettingsViewModel`.
- **Effort:** 2 hours

---

## Summary Table

| Priority | Count | Estimated Total Effort |
|----------|-------|----------------------|
| **Blocker** | 5 | ~9 hours |
| **High** | 6 | ~8.5 hours |
| **Medium** | 8 | ~13.5 hours |
| **Low** | 7 | ~13 hours |
| **Total** | **26** | **~44 hours** |

---

## Functional-Equivalence Matrix Corrections

The matrix claims 82/82 DONE. Based on source verification, the following items are **NOT actually DONE**:

| UX # | Claimed Status | Actual Status | Reason |
|------|---------------|---------------|--------|
| UX-07 | DONE | PARTIAL | Remember Me toggle not in UI |
| UX-30 | DONE | **BROKEN** | Menu button is a no-op (Config not wired) |
| UX-34 | DONE | NOT DONE | No iPad layout work beyond maxWidth on LoginView |
| UX-47-57 | DONE | **UNREACHABLE** | Settings screen exists but cannot be navigated to |
| UX-53 | DONE | **BROKEN** | Dark/Light mode preference not applied |
| UX-58-62 | DONE | **NOT DONE** | Localization files exist but are never referenced; all strings hardcoded English |
| UX-63-66 | DONE | **UNREACHABLE** | Cache clearing UI exists but cannot be navigated to |
| UX-67-70 | DONE | **UNREACHABLE** | Config screen exists but cannot be navigated to |
| UX-82 | DONE | **UNREACHABLE** | Settings section order correct but screen unreachable |

**Corrected score: ~60/82 actually functional** (22 items either broken, unreachable, or not implemented).

---

## Recommended Implementation Order

### Phase 1: Blockers (before any TestFlight build)
1. B3 -- Add missing Info.plist keys (15 min)
2. B1 -- Create PrivacyInfo.xcprivacy (30 min)
3. B2 -- Add app icon PNGs (1 hr)
4. B4 -- Wire Config/Settings navigation (2-3 hrs)
5. B5 -- Wire localization strings (4-6 hrs)

### Phase 2: Security Hardening (before public beta)
1. H1 -- Fix DispatchSemaphore deadlock (1 hr)
2. H2 -- Fix DeepLinkValidator bypass (2 hrs)
3. H4 -- Add privacy overlay (1 hr)
4. H5 -- Apply theme mode to UI (30 min)
5. H6 -- Scope Keychain keys to server (1 hr)

### Phase 3: Feature Completeness
1. M1 -- AppRouter navigation architecture (4-6 hrs)
2. M2 -- Remember Me toggle (30 min)
3. M3 -- Core Data file protection (30 min)
4. M4-M5 -- Deep link edge cases (45 min)
5. M6 -- AppLogger (2 hrs)
6. M7 -- iPad polish (4-6 hrs)
7. M8 -- Launch screen (1 hr)
8. H3 -- Session cookie to Keychain (3 hrs, can defer)

### Phase 4: App Store Prep
1. L3 -- Screenshots (2-3 hrs)
2. L4 -- App Review Notes (1 hr)
3. L1 -- Test coverage gaps (4-6 hrs)
4. L2 -- Remove dead code (5 min)

---

## Files Referenced in This Audit

| File | Issues |
|------|--------|
| `odoo/odooApp.swift` | B4 (Config not wired), H5 (theme mode), H4 (no overlay), M5 (task cancel), L2 (dead code) |
| `odoo/Info.plist` | B3 (missing keys) |
| `odoo/Assets.xcassets/AppIcon.appiconset/` | B2 (no PNGs) |
| `odoo/UI/Login/LoginView.swift` | B5 (hardcoded strings), M2 (no Remember Me) |
| `odoo/UI/Login/LoginViewModel.swift` | B5 (hardcoded errors) |
| `odoo/UI/Config/ConfigView.swift` | B4 (exists but unreachable), B5 (hardcoded strings) |
| `odoo/UI/Settings/SettingsView.swift` | B4 (unreachable), B5 (hardcoded strings) |
| `odoo/UI/Settings/SettingsViewModel.swift` | L7 (dual-write theme) |
| `odoo/UI/Main/MainView.swift` | B4 (onMenuClick is no-op), B5 (hardcoded strings) |
| `odoo/UI/Main/MainViewModel.swift` | H1 (calls deadlocking getSessionId) |
| `odoo/UI/Auth/BiometricView.swift` | B5 (hardcoded strings) |
| `odoo/UI/Auth/PinView.swift` | B5 (hardcoded strings) |
| `odoo/Data/Repository/AccountRepository.swift` | H1 (DispatchSemaphore deadlock) |
| `odoo/Data/Push/DeepLinkValidator.swift` | H2 (overly broad /web* prefix) |
| `odoo/Data/Push/DeepLinkManager.swift` | M4 (lost on expiry), L6 (singleton) |
| `odoo/Data/API/OdooAPIClient.swift` | H3 (plaintext cookies) |
| `odoo/Data/Storage/SecureStorage.swift` | H6 (key collision) |
| `odoo/Data/Storage/PersistenceController.swift` | M3 (no file protection) |
| `odoo/UI/Theme/WoowTheme.swift` | H5 (mode not applied), L7 (singleton) |
| `odoo/App/AppDelegate.swift` | H2 (bypass in line 126) |
| `odoo/Resources/en.lproj/Localizable.strings` | B5 (exists but unused) |
| `odoo/Resources/zh-Hans.lproj/Localizable.strings` | B5 (exists but unused) |
| `odoo/Resources/zh-Hant.lproj/Localizable.strings` | B5 (exists but unused) |
