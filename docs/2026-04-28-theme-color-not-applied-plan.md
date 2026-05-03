# iOS Theme Color Not Applied — Bug Fix Plan

> **Date:** 2026-04-28
> **Severity:** MED — visible UX bug. User picks a color in Settings → Theme Color, taps Apply, **nothing visibly changes**. The preview circle inside the Settings row updates, but the actual header (showing "WoowTech Odoo") and other native chrome stay the original brand blue.
> **Found by:** User report on real device.
> **Scope:** iOS only. Android already correctly observes the theme.

---

## 1. The bug

### Symptom

Open Settings → Theme Color → tap a non-blue color → tap Apply → return to the previous screen → header is still the same purple/blue. The only thing that changes is the small swatch circle inside the Settings row.

### Root cause

`WoowTheme.shared.primaryColor` is correctly mutated and persisted by
`SettingsViewModel.updateThemeColor`. But **no SwiftUI view reads
`theme.primaryColor` to drive any visible UI surface**. Specifically:

- `MainView.swift:60` hardcodes `.toolbarBackground(WoowColors.primaryBlue, …)`
- `LoginView.swift:31, 111, 123` use `WoowColors.primaryBlue`
- `SettingsView.swift:66` uses `WoowColors.primaryBlue`
- `ConfigView.swift:27` uses `WoowColors.primaryBlue`
- `BiometricView.swift:22, 54` use `WoowColors.primaryBlue`
- `PinView.swift:46, 50` use `WoowColors.primaryBlue`

`WoowColors.primaryBlue` is a static constant in `WoowColors.swift`. It does
NOT update when the user picks a new color. The user-picked color is held
in `WoowTheme.shared.primaryColor` (the `@Published` reactive property) but
nobody observes it.

### Why the small swatch DOES update

`SettingsView` line 25 reads `Color(hex: viewModel.settings.themeColor)` —
not the static constant — so the preview circle inside the row reflects
the new value. That's the only place the user's pick is visible.

---

## 2. The fix

Replace every hardcoded `WoowColors.primaryBlue` reference in the user-
visible chrome with `theme.primaryColor` from `WoowTheme.shared`, and
declare an `@ObservedObject` on each owning view so SwiftUI re-renders
when the published color changes.

### Files to modify

| File | Lines | Replace `WoowColors.primaryBlue` with `theme.primaryColor` |
|---|---|---|
| `MainView.swift` | 60 | toolbar background — **the user's primary visible header** |
| `LoginView.swift` | 31, 111, 123 | logo tint, button tint, link foreground |
| `SettingsView.swift` | 66 | section icon foreground |
| `ConfigView.swift` | 27 | profile bubble background (with opacity) |
| `BiometricView.swift` | 22, 54 | icon, button tint |
| `PinView.swift` | 46, 50 | PIN-dot fill + stroke |

### Why this scope (8 sites)

A `WoowColors.primaryBlue` reference outside the user's visible UI
surface (e.g., a `let defaultPrimary = WoowColors.primaryBlue` in a
testing file) would be left alone. All 8 sites listed above are user-
visible chrome. Replacing the constant in `WoowColors.swift` itself is
NOT viable because:
- The static constant is the **default** for `AppSettings.themeColor`
  (`#6183FC`)
- Mutating a `static let` is impossible
- Some views (PinView's stroke/fill) treat the color as a value, not as
  a reactive binding — converting them to observe is the correct fix

### Pattern applied per file

```swift
struct WhateverView: View {
    @ObservedObject private var theme = WoowTheme.shared    // ← add

    var body: some View {
        ...
        .someModifier(theme.primaryColor)                   // ← was WoowColors.primaryBlue
    }
}
```

### Why `@ObservedObject`, not `@StateObject`

`WoowTheme` is a singleton (`static let shared`). Each view should
**observe** the shared instance, not own a fresh one. `@StateObject`
would create a new instance per view, breaking the reactive link.

---

## 3. Out of scope (intentional)

These do NOT change in this PR:

- **`WoowColors.primaryBlue` constant itself** stays — it's the default
  for first-launch and used by Theme/Settings as a fallback.
- **`AppSettings.themeColor` default** stays `#6183FC`.
- **`BiometricView` / `PinView` color values** for read-only auth chrome
  could arguably stay static (they appear briefly during login). But
  for consistency and so the user's preference is honored everywhere,
  they're included.
- **WebView CSS** is server-side (Odoo OWL theme). The native fix
  doesn't and shouldn't touch this.

---

## 4. Tests

Per CLAUDE.md "Source code change → ALL tests must pass" rule:

| Suite | What it covers | Expected |
|---|---|---|
| `xcodebuild test -scheme odoo` (unit) | All existing iOS unit tests | All PASS, no new failures |
| iOS `E2E_LocationClockInTests` (UI) | Real-device E2E (verified previously) | PASS unchanged |
| Manual on-device | Settings → Theme Color → pick red → tap Apply → header turns red | Verified |
| Manual on-device | Restart app, header retains the picked color | Verified |

### New unit test

Add `WoowThemeReactiveTest.swift` (1 test) that asserts
`WoowTheme.shared.primaryColor` is `@Published` and emits a change when
`setPrimaryColor(hex:)` is called. This guards the contract that the
chrome relies on.

```swift
@MainActor
final class WoowThemeReactiveTest: XCTestCase {
    func test_setPrimaryColor_publishesChange() async {
        let theme = WoowTheme.shared
        let original = theme.primaryColor
        defer { theme.setPrimaryColor(hex: "#6183FC") } // restore
        var observedCount = 0
        let cancellable = theme.$primaryColor.dropFirst().sink { _ in
            observedCount += 1
        }
        theme.setPrimaryColor(hex: "#FF0000")
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(observedCount, 1)
        cancellable.cancel()
    }
}
```

---

## 5. Risk assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| Color contrast issue (user picks unreadable color) | LOW | Theme presets are pre-vetted; HEX input shows preview before Apply |
| Existing tests reference `WoowColors.primaryBlue` and break when color changes mid-test | LOW | Tests typically don't change theme; if any do, they reset in tearDown |
| Toolbar text becomes unreadable on a light user-picked color | MED | `toolbarColorScheme(.dark, …)` keeps text white. May need to switch to `.light` if user picks light color — defer to follow-up |

---

## 6. Implementation order

1. ✅ This plan doc lands first (per CLAUDE.md "Plan → Implement → Test → Commit")
2. Apply the 8-site replacement in one focused commit
3. Add `WoowThemeReactiveTest.swift`
4. Run iOS unit tests via `xcodebuild test`
5. Manual on-device verification — pick a non-blue color, confirm header turns to that color
6. Commit + push to iOS branch (`feature/location-permission` or new branch?)

**Note on branch**: the iOS PR #1 (`feature/location-permission`) is already open. This bug is unrelated to location, so should arguably land on a separate branch + PR. Decision pending user input.

---

## 7. App Store Compliance Hardening (added after adversarial review)

The initial fix passed visual verification but the adversarial review
flagged 14+ issues against Apple App Store Review Guidelines and OWASP
MASVS. The compliance hardening lands in the same commit:

### 7.1 — Guideline 2.3.1 (Hidden, dormant, undocumented features)

**Risk:** debug test hooks (`WOOW_TEST_THEME_COLOR`,
`WOOW_TEST_FORCE_BIOMETRIC`, `WOOW_TEST_FORCE_PIN`) are guarded only by
`#if DEBUG`. A misconfigured CI archive that ships a Debug binary would
leak auth-bypass into TestFlight.

**Fix:** new `TestHookGate` adds a runtime second-factor —
`-WoowTestRunner` launch argument. `testHooksEnabled` returns `true`
ONLY when both `#if DEBUG` AND the launch arg are present. XCUITest
target sets the arg in every `XCUIApplication.launchArguments`;
production launches never include it. Even a Debug archive that ships
will not respond to the env vars.

**Test:** `TestHookGateTest` asserts the marker symbol is stable and
`testHooksEnabled` is `false` from the unit-test process (which doesn't
set the marker).

### 7.2 — Guideline 4.0 / WCAG 2.1 SC 1.4.3 (Contrast)

**Risk:** the toolbar text was hardcoded `.dark` (white text). Picking
a light theme color (yellow, cream) makes title and hamburger icon
invisible.

**Fix:** new `WoowTheme.toolbarTextScheme` computed property samples the
chosen color's WCAG relative luminance and returns `.dark` (white text)
or `.light` (black text) to maintain ≥4.5:1 contrast. `MainView`'s
`.toolbarColorScheme` modifier now consumes this instead of a literal.

**Test:** `WoowThemeValidationTest` covers light/dark/threshold cases.

### 7.3 — Hex input validation (defense-in-depth)

**Risk:** `Color(hex:)` silently returns black/transparent on malformed
input. The picker's free-form HEX field could ship invisible UI.

**Fix:** `WoowTheme.isValidHex` strict parser; `setPrimaryColor` now
returns `Bool` and rejects malformed input without mutating state. The
saved-settings load path (`init`) also validates and falls back to
`AppSettings.defaultThemeColor` if storage is corrupted.

**Test:** `WoowThemeValidationTest.test_setPrimaryColor_rejectsInvalidHexAndReturnsFalse`
+ 5 `isValidHex` cases.

### 7.4 — Loud override warning (developer ergonomics)

**Risk:** a developer who left `WOOW_TEST_THEME_COLOR` in their Xcode
scheme env vars would see the override silently — masking real bugs in
"why isn't my saved color showing".

**Fix:** `WoowTheme.init` now `print`s a `⚠️ [TestHook]` warning
explicitly stating the override is active. Easy to grep in Xcode console.

### 7.5 — Thread affinity (`@Published` from background thread)

**Risk:** `WoowTheme` was a non-isolated class with `@Published`
properties. iOS 16+ emits "Publishing changes from background threads
is not allowed" runtime warnings if any caller mutates from a non-main
context.

**Fix:** `@MainActor` annotation on `WoowTheme`. Compile-time guarantee.

### 7.6 — Cold-start performance

**Risk:** `WOOW_TEST_FORCE_PIN` ran PBKDF2 (600k iterations, ~2-3s) on
every debug app launch with the env var set.

**Fix:** `applyDebugAuthSeeding` now calls `verifyPin(pin)` first; the
expensive `setPin` path is skipped if the same PIN is already stored.

### 7.7 — Stub account cleanup

**Risk:** the seeded stub account used `https://stub.example.com` (a
real domain owned by IANA). Network leak risk if the stub account is
ever queried.

**Fix:** changed to `https://stub.example.invalid` (RFC 2606 reserved
TLD that DNS guarantees never resolves). Eliminates leak surface.

### 7.8 — Audit script broadened

**Risk:** the original audit only matched the literal `WoowColors.primaryBlue`.
Future brand additions or asset-catalog references would slip through.

**Fix:** pattern now matches `WoowColors.<anyIdent>` AND
`Color("<anyIdent>")` with explicit allowlist for `brandColors` /
`accentColors` arrays consumed by the picker UI itself.

### 7.9 — Out of scope (deferred, documented)

These adversarial-review findings were assessed as out of scope for
this PR but remain in the follow-up backlog:

| Finding | Why deferred |
|---|---|
| `TestConfig.plist` checks credentials into git | Pre-existing pattern across the entire test suite; refactoring requires a CI-secret-injection design separate from this PR |
| Migrate 8 `@ObservedObject` sites to single `@EnvironmentObject` | Premature optimization; current pattern works correctly and the perf cost is sub-millisecond |
| Pixel-sampling assertion in XCUITest screenshots | Useful but adds tooling complexity; visual review by humans remains acceptable for now |
| Test-order randomization CI guard | Broader test-infra change; requires Xcode 16 settings change at the test plan level |
| iOS-side equivalent of Android FCM register-on-login | Separate ticket — different feature, different scope |

---

## 8. Acceptance criteria

- After picking and applying a non-default color, the **header bar** in
  `MainView` shows the picked color.
- After picking and applying a non-default color, the **login screen
  logo accent** uses the picked color.
- After app restart, the picked color persists (already worked
  pre-fix — persistence wasn't the bug).
- All existing unit tests pass.
- New `WoowThemeReactiveTest` passes.
