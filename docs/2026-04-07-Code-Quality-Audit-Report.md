# Code Quality Audit Report — Woow Tech Odoo iOS App

**Date:** 2026-04-07
**Scope:** All 35 Swift files in `odoo/` (4,011 lines of production code)
**Companion:** `2026-04-07-Security-Audit-Report.md` (fix together)

---

## Executive Summary

| Severity | Count | Category |
|----------|-------|----------|
| HIGH | 5 | Business logic in views, force unwraps |
| MEDIUM | 24 | Hardcoded strings, missing previews, duplication, silent errors |
| LOW | 14 | Magic numbers, naming, DispatchQueue patterns |

**Overall Quality Grade: B+**

Architecture is clean (MVVM, Repository pattern, proper DI). Main issues are localization gaps, missing previews, and some business logic leaking into views.

---

## 1. Architecture & MVVM — Grade: A-

### What's Good
- All ViewModels marked `@MainActor` and use `@Published`
- No ViewModel imports SwiftUI (clean separation)
- Repository pattern consistent: `AccountRepository`, `SettingsRepository`, `CacheService`
- Protocol-based abstractions: `AccountRepositoryProtocol`, `SettingsRepositoryProtocol`, `SecureStorageProtocol`
- Clean dependency flow: UI → ViewModel → Repository → Storage/API (no circular deps)
- Feature-based directory structure (not layer-based)

### Findings

#### HIGH-Q1: Business Logic in PinView
**File:** `odoo/UI/Auth/PinView.swift:139-163`
**Issue:** PIN verification, lockout checking, error state management, and timer logic all live in the view instead of ViewModel.
**Fix:** Move `onNumberTap()`, `checkLockout()`, `startLockoutTimer()` logic into `AuthViewModel`. View should only call `authViewModel.enterDigit("1")`.

#### HIGH-Q2: Business Logic in PinSetupView
**File:** `odoo/UI/Auth/PinSetupView.swift:123-157`
**Issue:** `handlePinComplete()` contains multi-step PIN setup flow (new → confirm → mismatch handling). Should be in `SettingsViewModel`.
**Fix:** Extract `PinSetupViewModel` or add PIN setup flow to `SettingsViewModel`.

#### MEDIUM-Q1: SettingsViewModel Uses Singleton Directly
**File:** `odoo/UI/Settings/SettingsViewModel.swift:29`
**Issue:** `SecureStorage.shared` used directly instead of injected dependency. Breaks testability.
**Fix:** Inject `SecureStorageProtocol` via init parameter with default.

#### MEDIUM-Q2: WoowTheme Uses Singletons
**File:** `odoo/UI/Theme/WoowTheme.swift:22,34,41`
**Issue:** Calls `SettingsRepository()` and `SecureStorage.shared` directly.
**Fix:** Inject dependencies or make theme read from an `@EnvironmentObject`.

---

## 2. SwiftUI Best Practices — Grade: B

### What's Good
- State hoisting in LoginView (stateful wrapper + stateless content)
- `@Preview` exists in LoginView.swift
- WoowColors design system used for primary colors

### Findings

#### MEDIUM-Q3: Missing @Preview Functions (6 views)

| File | View | Priority |
|------|------|----------|
| `UI/Auth/PinView.swift` | PinView | High — complex UI |
| `UI/Auth/BiometricView.swift` | BiometricView | High — multi-state |
| `UI/Settings/SettingsView.swift` | SettingsView | High — many sections |
| `UI/Settings/ConfigView.swift` | ConfigView | Medium |
| `UI/Settings/ColorPickerView.swift` | ColorPickerView | Medium |
| `UI/Auth/PinSetupView.swift` | PinSetupView | Medium |

**Fix:** Add `@Preview` with mock/stub ViewModels for each.

#### MEDIUM-Q4: Hardcoded Colors Outside Design System

| File | Line | Hardcoded Color | Should Use |
|------|------|-----------------|------------|
| `UI/Auth/PinView.swift` | 46 | `.gray.opacity(0.4)` | `WoowColors.lightGray` |
| `UI/Auth/BiometricView.swift` | 40 | `Color.red.opacity(0.85)` | Design system error color |
| `UI/Auth/PinView.swift` | 59 | `.red` | Design system error color |
| `UI/Auth/PinSetupView.swift` | 90 | `Color(.systemGray6)` | `WoowColors` equivalent |

**Fix:** Add error/warning colors to `WoowColors` and use them consistently.

---

## 3. String Localization — Grade: C+

### What's Good
- `String(localized:)` used correctly in many places (LoginViewModel, PinHasher lockout messages)
- Localizable strings exist for en, zh-Hans, zh-Hant

### Findings

#### MEDIUM-Q5: Hardcoded English Strings (Not Localized)

| File | Line | String | Fix |
|------|------|--------|-----|
| `UI/Auth/BiometricView.swift` | 26 | `"Biometric Login"` | `String(localized: "biometric_login_title")` |
| `UI/Auth/BiometricView.swift` | 30 | `"Use Face ID or Touch ID to unlock"` | `String(localized: "biometric_subtitle")` |
| `UI/Auth/BiometricView.swift` | 63 | `"Use PIN"` | `String(localized: "use_pin_button")` |
| `UI/Auth/PinView.swift` | 33 | `"Enter PIN"` | `String(localized: "enter_pin_title")` |
| `UI/Auth/PinView.swift` | 37 | `"Enter your PIN to unlock"` | `String(localized: "enter_pin_subtitle")` |
| `UI/Settings/ConfigView.swift` | 81 | `"Configuration"` | `String(localized: "configuration_title")` |
| `UI/Main/MainView.swift` | 37 | `"WoowTech Odoo"` | `String(localized: "app_title")` |
| `UI/Settings/ColorPickerView.swift` | 18 | `"Preset Colors"` | `String(localized: "preset_colors")` |
| `UI/Settings/ColorPickerView.swift` | 27 | `"Accent"` | `String(localized: "accent_colors")` |
| `UI/Settings/ColorPickerView.swift` | 35 | `"Custom Color"` | `String(localized: "custom_color")` |
| `UI/Auth/PinSetupView.swift` | 140 | `"Incorrect PIN"` | `String(localized: "incorrect_pin")` |
| `UI/Auth/PinSetupView.swift` | 151 | `"PINs don't match"` | `String(localized: "pins_dont_match")` |

**Impact:** Chinese-speaking users see English text in auth and settings screens.
**Priority:** HIGH for release — these are user-facing strings.

---

## 4. Error Handling — Grade: B-

### What's Good
- OdooAPIClient maps errors to typed `AuthResult` enum
- LoginViewModel shows user-facing error messages
- PIN lockout errors displayed in UI

### Findings

#### MEDIUM-Q6: Silenced Errors

| File | Line | Operation | Issue |
|------|------|-----------|-------|
| `App/AppDelegate.swift` | 26 | Notification permission | Error callback ignored |
| `Data/Push/NotificationService.swift` | 56-60 | Show notification | Error logged DEBUG only |
| `Data/Push/PushTokenRepository.swift` | 56-60 | Token registration | Fails silently in release |
| `Data/Push/PushTokenRepository.swift` | 82-84 | FCM unregister | Error ignored |
| `Data/Repository/AccountRepository.swift` | 208-211 | FCM unregister on logout | Ignored |
| `Data/Repository/CacheService.swift` | 10-13 | File deletion | `try?` swallows errors |

**Fix:** At minimum, log errors with `os.Logger` at `.error` level (not just `#if DEBUG`). For user-affecting operations (notification permission, cache clear), show feedback.

#### HIGH-Q3: Force Unwraps That Can Crash

| File | Line | Expression | Risk |
|------|------|------------|------|
| `Data/Push/DeepLinkValidator.swift` | 11 | `try! NSRegularExpression(...)` | Low — regex is compile-time constant |
| `UI/Theme/WoowColors.swift` | 49-60 | Multiple force unwraps in hex parsing | Medium — malformed hex crashes |
| `Data/Storage/PersistenceController.swift` | 50 | `fatalError()` in DEBUG | Low — only in debug |

**Fix for WoowColors:** Replace force unwraps with `guard let` + fallback color:
```swift
static func fromHex(_ hex: String) -> Color {
    guard let scanner = Scanner(string: hex),
          scanner.scanHexInt64(&rgb) else {
        return .gray // fallback
    }
}
```

---

## 5. Code Duplication — Grade: B

### Findings

#### MEDIUM-Q7: PIN Number Pad Duplicated
**Files:** `UI/Auth/PinView.swift:91-107` and `UI/Auth/PinSetupView.swift:81-120`
**Issue:** Both files implement identical 3x3+0+delete number pad UI.
**Fix:** Extract `NumberPadView` component:
```swift
struct NumberPadView: View {
    let onNumberTap: (String) -> Void
    let onDelete: () -> Void
    // ... shared UI
}
```

#### MEDIUM-Q8: Error Banner Repeated 3x
**Files:** `BiometricView.swift:34-42`, `LoginView.swift:41-52`, `PinView.swift:59-64`
**Issue:** Red error message box with identical styling repeated in 3 views.
**Fix:** Extract `ErrorBannerView(message: String)` component.

#### MEDIUM-Q9: HTTPS Prefix Logic Repeated 3x
**Files:**
- `AccountRepository.swift:43-45`
- `LoginViewModel.swift:153-154`
- `OdooAccount.swift:41-47`

**Issue:** Logic to add `https://` prefix if missing is duplicated.
**Fix:** Centralize as `String` extension:
```swift
extension String {
    var ensureHTTPS: String {
        if lowercased().hasPrefix("https://") { return self }
        return "https://\(self)"
    }
}
```

---

## 6. Magic Numbers & Constants — Grade: B-

### Findings

#### LOW-Q1: Unnamed Constants

| File | Line | Value | Suggested Name |
|------|------|-------|----------------|
| `PinHasher.swift` | 17-22 | `[30, 300, 1800, 3600]` | `lockoutDurations` (already named in array, but individual values undocumented) |
| `PinHasher.swift` | 24 | `5` | `attemptsPerLockoutTier` |
| `AuthViewModel.swift` | 37 | `5` | `maxAttemptsBeforeLockout` — duplicates PinHasher constant |
| `CacheService.swift` | 45-47 | `1024`, `1024*1024` | `bytesPerKB`, `bytesPerMB` |
| `PinView.swift` | 17 | `6` | `maxPinLength` — also in PinSetupView:23 (duplicated) |
| `OdooWebView.swift` | 159-176 | `100`, `500`, `1000` (ms) | `owlResizeDelays` |
| `BiometricView.swift` | 100 | `0.3` | `animationDuration` |

**Fix:** Extract to file-level constants or a dedicated `Constants` enum per feature.

---

## 7. Concurrency — Grade: B+

### What's Good
- All ViewModels marked `@MainActor`
- `OdooAPIClient` is an `actor` (proper isolation)
- `@unchecked Sendable` used correctly with documentation

### Findings

#### MEDIUM-Q10: DispatchQueue Instead of Modern Concurrency

| File | Line | Pattern | Fix |
|------|------|---------|-----|
| `BiometricView.swift` | 106 | `DispatchQueue.main.async` | Already in `@MainActor` context — remove wrapper |
| `PinView.swift` | 153 | `DispatchQueue.main.asyncAfter(deadline: .now() + 0.3)` | `Task { try? await Task.sleep(for: .milliseconds(300)) }` |

#### LOW-Q2: Blocking Main Thread
**File:** `Data/Repository/CacheService.swift:9-13`
**Issue:** `clearAppCache()` performs synchronous file deletion on caller's thread.
**Fix:** Make `async` and dispatch to `.global()`:
```swift
func clearAppCache() async {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            // file operations
            cont.resume()
        }
    }
}
```

---

## 8. Function Size & View Complexity — Grade: B

### Findings

#### LOW-Q3: Large Views That Should Be Split

| File | Lines | Issue | Fix |
|------|-------|-------|-----|
| `SettingsView.swift` | 231 | 6 sections in single body | Extract `AppearanceSection`, `SecuritySection`, `DataSection`, etc. |
| `LoginView.swift` | 52 in body | Conditional step rendering | Extract `ServerInfoStepView`, `CredentialsStepView` |
| `odooApp.swift` | 175 | AppRootView has 8+ nesting levels | Extract authenticated/unauthenticated sub-views |

---

## 9. Naming & Documentation — Grade: A

### What's Good
- All file names match content
- All public functions documented with doc comments
- Comments explain "why" not just "what"
- Porting origin noted (e.g., "Ported from Android: BiometricScreen.kt")

### Findings

#### LOW-Q4: Minor Naming Issues

| File | Line | Current | Suggested |
|------|------|---------|-----------|
| `AppDelegate.swift` | 175 | `if let k = key as? String` | `keyString` |
| `OdooAccountEntity.swift` | 6-14 | All properties `public` | Should be `internal` (Core Data detail) |

#### LOW-Q5: Missing Doc Comments

| File | Function | Priority |
|------|----------|----------|
| `CacheService.swift:29` | `calculateCacheSize()` | Low |
| `CacheService.swift:42` | `formatSize()` | Low |
| `ColorPickerView.swift:73` | `colorSwatch(hex:)` | Low |

---

## 10. File Organization — Grade: A

### What's Good
- Feature-based structure: `UI/Login/`, `UI/Auth/`, `UI/Settings/`, `UI/Main/`
- Cross-cutting concerns properly separated: `Data/Repository/`, `Data/Storage/`, `Data/API/`
- No misplaced files
- No files over 300 lines
- No circular dependencies
- No unused imports

---

## Prioritized Fix Plan

### Phase 1: Before Release (HIGH + critical MEDIUM)

| # | Finding | File(s) | Effort | Impact |
|---|---------|---------|--------|--------|
| 1 | **Localize hardcoded strings** | 6 files, ~12 strings | 1 hr | User-facing — Chinese users see English |
| 2 | **Fix WoowColors force unwraps** | WoowColors.swift | 15 min | Prevents potential crash |
| 3 | **Extract NumberPadView** | PinView + PinSetupView | 30 min | Removes duplication |
| 4 | **Extract ErrorBannerView** | 3 files | 20 min | Removes duplication |
| 5 | **Centralize HTTPS prefix** | 3 files | 10 min | Single source of truth |

### Phase 2: Post-Release Refactor

| # | Finding | File(s) | Effort | Impact |
|---|---------|---------|--------|--------|
| 6 | Move PIN logic to ViewModel | PinView, PinSetupView | 1.5 hr | Architecture purity |
| 7 | Add @Preview to 6 views | 6 files | 1 hr | Developer experience |
| 8 | Split SettingsView into sections | SettingsView.swift | 45 min | Readability |
| 9 | Replace DispatchQueue patterns | BiometricView, PinView | 15 min | Modern concurrency |
| 10 | Add error feedback for silent failures | 4 files | 1 hr | User experience |
| 11 | Extract magic numbers to constants | 5 files | 30 min | Maintainability |
| 12 | Inject deps in SettingsViewModel/WoowTheme | 2 files | 30 min | Testability |

### Total Estimated Effort
- **Phase 1:** ~2.5 hours
- **Phase 2:** ~5.5 hours
- **Grand Total:** ~8 hours

---

## Comparison with Security Audit

| Area | Security Grade | Quality Grade | Combined Action |
|------|---------------|---------------|-----------------|
| Authentication | A | A- | Minor: move PIN logic to ViewModel |
| Network | A- | A | No action needed |
| WebView | A | B+ | Add design system colors |
| Deep Links | A | A | Remove case-insensitive regex flag |
| Data Storage | A- | A | No action needed |
| UI/Strings | N/A | C+ | **Priority: localize 12 strings** |
| Error Handling | N/A | B- | Add error logging in release |
| Code Structure | N/A | B+ | Extract shared components |

---

## Conclusion

The codebase is well-architected with clean MVVM separation, proper dependency injection, and feature-based organization. The main gaps are:

1. **String localization** — 12 hardcoded English strings in auth/settings views (highest priority for Chinese-speaking users)
2. **Code duplication** — PIN pad and error banner UI repeated across views
3. **Missing previews** — 6 views lack @Preview functions
4. **Business logic in views** — PinView and PinSetupView contain verification logic

None of these are blockers for App Store submission, but Phase 1 items (especially localization) should be addressed before release.
