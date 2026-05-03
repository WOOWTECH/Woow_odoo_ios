# App Store Readiness — Fixing Plan

> **Date**: 2026-05-02
> **Source**: adversarial-review findings 2026-05-02 (HIGH × 7, MED × 6, LOW × 11)
> **Goal**: pass Apple App Store Review on first submission, with the
> binary correctly functioning in BOTH Debug AND Release configurations.

---

## 0. Why this plan exists

The 2026-04-28 theme-color hardening pass solved a bounded scope (theme
reactivity + 4 of the test hooks). A follow-up adversarial audit of the
**whole codebase** against App Store Review Guidelines surfaced 24
additional findings, including:

- 2 ship-stoppers (entitlement misconfig, missing account-deletion UI)
- 2 un-gated test hooks identical in class to the ones we just fixed
- ~~1 Privacy-Manifest gap that fails App Store Connect upload validation~~ — withdrawn after verification; see H4
- 7 mid-severity items that risk "Metadata Rejected" on submission 2

This plan sequences all 24 findings into 4 phases, codifies the fix for
each, lists the test that proves the fix, and adds a **dual-build
verification gate** so Release builds are exercised in CI alongside
Debug.

---

## 1. Phase ordering & dependency

```
Phase 1 (HIGH — ship-stoppers)
  ↓
Phase 2 (MED — before TestFlight beta)
  ↓
Phase 3 (LOW — before App Store submission)
  ↓
Phase 4 (Release-build verification — gate that prevents regression)
```

Phases 1 and 4 must complete before submission. Phases 2 and 3 are
"strongly recommended" and ordered by risk-of-rejection.

Each phase ends with a single CI gate: ALL prior tests pass + the new
phase's tests pass + audit script clean.

---

## 2. Phase 1 — HIGH (must-fix before any submission)

| # | Finding | Fix | File(s) touched | Test |
|---|---|---|---|---|
| H1 | `aps-environment=development` in entitlements → no FCM in production | Use **two** entitlements files: `odoo.entitlements` (debug) → `development`, `odoo.production.entitlements` → `production`. Wire via build configuration in `project.pbxproj` so Debug uses dev APNs and Release uses prod APNs. | `odoo/odoo.entitlements`, NEW `odoo/odoo.production.entitlements`, `odoo.xcodeproj/project.pbxproj` | New CI step: `xcodebuild archive -configuration Release` then `codesign -d --entitlements - <ipa>` and grep for `aps-environment=production`. Manual: send a real APNs push to a TestFlight build and confirm receipt. |
| H2 | `WOOW_SEED_ACCOUNT` test hook in `AppDelegate.swift:110` is NOT gated | Gate behind `TestHookGate.testHooksEnabled`. Same belt-and-suspenders pattern as `WOOW_TEST_FORCE_*` (DEBUG build + `-WoowTestRunner` launch arg). | `odoo/App/AppDelegate.swift` | Extend `TestHookGateTest` with `test_seedAccount_isInert_withoutMarker` — launch app process WITH `WOOW_SEED_ACCOUNT` env but WITHOUT `-WoowTestRunner`, assert no account is created. |
| H3 | `WOOW_TEST_AUTOTAP` JS-injection hook in `OdooWebView.swift:243` is NOT gated | Gate behind `TestHookGate.testHooksEnabled`. The handler currently injects arbitrary JS into the WebView based on an env var — equivalent to RCE if a Debug binary ships. | `odoo/UI/Main/OdooWebView.swift` | New unit test verifying the auto-tap injection no-ops when `testHooksEnabled` returns false. Plus existing `E2E_LocationClockInTests` already exercises the positive path under the gated flag. |
| H4 | ~~`NSPrivacyAccessedAPIType` missing entry for **Keychain** (CA92.1 reason)~~ **WITHDRAWN — finding was incorrect.** Apple's `NSPrivacyAccessedAPITypes` only accepts a fixed list of categories (`UserDefaults`, `DiskSpace`, `FileTimestamp`, `SystemBootTime`, `ActiveKeyboards`). Keychain is NOT on that list — it is a security primitive, not a Required-Reason API. The CA92.1 reason code in the original finding is the UserDefaults reason, suggesting the reviewer conflated the two. The existing `PrivacyInfo.xcprivacy` correctly lists only the categories the app actually uses. | n/a | n/a | n/a |
| H5 | `javaScriptCanOpenWindowsAutomatically=true` allows uncontrolled popups | Set to `false`. The `WKUIDelegate.webView(_:createWebViewWith:)` already exists at `OdooWebView.swift:221` — change it to load any `target=_blank` link in the SAME WebView (`webView.load(navigationAction.request)`) rather than spawning a new window. | `odoo/UI/Main/OdooWebView.swift` | New unit test: configure the helper, simulate a `_blank` navigation, assert the URL was loaded in the original web view. Manual on-device: tap any external link in Odoo's chatter and confirm it opens the same window (or a controlled `SFSafariViewController` for off-domain). |
| H6 | `ITSAppUsesNonExemptEncryption` missing → blocks TestFlight uploads | Add `<key>ITSAppUsesNonExemptEncryption</key><false/>` to `Info.plist`. The app uses standard HTTPS (TLS via `URLSession`) which is exempt under US BIS. | `odoo/Info.plist` | TestFlight upload should no longer prompt for export-compliance form. |
| H7 | ~~No account-deletion CTA → Apple Guideline 5.1.1(v) auto-rejection~~ **WITHDRAWN — finding was incorrect.** 5.1.1(v) only triggers "if your app supports account creation". This app has no signup flow: `LoginView` requires existing Odoo credentials provisioned by the user's admin; `AccountRepository` has no `createUser`/`signUp` method. Reactivate this finding ONLY if a signup affordance is added to the app or if the bundled Odoo deployment exposes public signup via the post-auth WebView. | n/a | n/a | n/a |

**Phase 1 acceptance criteria**: 7 fixes land + 7 tests pass + Release-build CI gate (Phase 4) green.

---

## 3. Phase 2 — MED (before TestFlight beta)

| # | Finding | Fix | File(s) | Test |
|---|---|---|---|---|
| M1 | `UIBackgroundModes=remote-notification` declared but no proof-of-use | Either implement `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` to do meaningful work (e.g., refresh attendance state on silent push), or remove the entry. Removing is safer if silent-push is not actually a feature. | `odoo/Info.plist`, optionally `odoo/App/AppDelegate.swift` | New unit test if implementing: send a mock silent push, verify the handler runs. If removing: existing FCM tests must still pass (they use UI-visible push, not silent push). |
| M2 | Custom URL scheme `woowodoo://` with no validation | Add `DeepLinkValidator` mirroring the Android side. Validate scheme, host, path against an allow-list before any side effect. Wire into `AppDelegate.application(_:open:options:)`. | NEW `odoo/Data/DeepLink/DeepLinkValidator.swift`, `odoo/App/AppDelegate.swift` | Port Android's `DeepLinkValidatorTest` — 13 cases including `javascript:`, `data:`, malformed schemes, host mismatches. |
| M3 | PII leakage in `print` statements (APNs token, FCM token, usernames, server URLs) | Replace all production `print` with `os.Logger` and use `.private` interpolation for PII. Build a tiny `Log.swift` wrapper so the conversion is consistent. | `odoo/App/AppDelegate.swift:220,312`, `odoo/Data/Repository/AccountRepository.swift:136`, `odoo/Data/Push/PushTokenRepository.swift:58,79,83`, plus any future call sites | New audit script `scripts/audit_pii_logging.sh` greps for `print(.*(token\|cookie\|password\|email))` in production source and fails CI. Adversarial review will recheck. |
| M4 | Firebase 11.15.0 may carry CVEs; pin is from April 2026 | Bump to latest Firebase 11.x.y as of submission date. Run `./scripts/verify_all.py` after to ensure no breaking API change. | `odoo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Existing FCM-flow XCUITest must still pass after the bump. Document Firebase version in `docs/dependencies.md`. |
| M5 | No SSL pinning → mis-issued cert enables session hijack | Implement `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)` that validates the server's leaf cert SHA-256 against a pinned set per configured Odoo host. Allow override via debug build for self-signed dev tunnels. | NEW `odoo/Data/Network/SSLPinning.swift`, wired into `OdooJsonRpcClient` | Unit test with mock URLSession: valid cert → request succeeds; bogus cert → fails. Document the threat-model decision in the security plan if NOT implemented. |
| M6 | Race condition: `WoowTheme.setPrimaryColor` and `SettingsViewModel.updateThemeColor` both write to Keychain via `SecureStorage.saveSettings` with no lock | Single-writer rule: `SettingsViewModel.updateThemeColor` should ONLY call `theme.setPrimaryColor(hex:)` and let `WoowTheme` own the persistence. Remove the duplicate `SecureStorage.saveSettings(settings)` from the ViewModel. | `odoo/UI/Settings/SettingsViewModel.swift:39-42` | New unit test: call `updateThemeColor` 100 times in rapid succession from `Task` blocks, verify the final stored value equals the last call's input (no torn writes). |

**Phase 2 acceptance criteria**: 6 fixes + 6 tests + audit scripts green + manual TestFlight build sent to internal testers.

---

## 4. Phase 3 — LOW (before App Store submission)

| # | Finding | Fix | File(s) | Test |
|---|---|---|---|---|
| L1 | `NSPhotoLibraryAddUsageDescription` missing | Add the description string. Required if the app ever writes a photo back. | `odoo/Info.plist` | Manual: write a test screenshot to library on a device build and verify no silent failure. |
| L2 | `NSMicrophoneUsageDescription` missing | Add OR explicitly block WebView mic access via `WKWebView.configuration.preferences.setValue(false, forKey: "mediaCaptureRequiresSecureConnection")` and a custom `WKUIDelegate` rejection. | `odoo/Info.plist` OR `odoo/UI/Main/OdooWebView.swift` | Manual: trigger Discuss voice-message in WebView, confirm graceful denial or successful prompt. |
| L3 | `NSPrivacyTrackingDomains` empty but `google-ads-on-device-conversion` SDK is present | Audit if the SDK is actually initialized anywhere. If not used: remove from `Package.resolved`. If used: declare its tracking domains in the manifest. | `odoo.xcodeproj/.../Package.resolved`, possibly `PrivacyInfo.xcprivacy` | Manual code review of all `import GoogleAdsOnDevice...` references. |
| L4 | Brand assets — verify icon has no alpha, launch screen is storyboard | Audit `Assets.xcassets/AppIcon.appiconset/Contents.json` and `LaunchScreen.storyboard`. Ensure 1024×1024 icon is RGB (no alpha channel). | `odoo/Assets.xcassets/AppIcon.appiconset/`, `odoo/LaunchScreen.storyboard` | Run `sips -g hasAlpha icon-1024.png` — must return `no`. |
| L5 | Localization gaps in `print` warnings, `[TestHook]` strings | Acceptable as console-only — document the policy in CLAUDE.md so future code doesn't surface these to the user. | `CLAUDE.md` | Code-review checklist item; no automated test. |
| L6 | App Privacy Report (App Store Connect form) not pre-filled | Write `docs/app-store-connect-privacy-answers.md` that maps each `PrivacyInfo.xcprivacy` collected-data-type to the App Store Connect questionnaire answers. Reduces submission friction. | NEW `docs/app-store-connect-privacy-answers.md` | None — documentation artifact. |
| L7 | `TestConfig.plist` could be accidentally added to release bundle in future | Build-phase script that fails if `TestConfig.plist` ends up in `Build/Products/Release-iphoneos/odoo.app/`. | `odoo.xcodeproj/project.pbxproj` (new Run Script Phase), NEW `scripts/check_release_bundle_contents.sh` | The script itself fails CI if a future commit adds the file to the wrong target. |
| L8 | VoiceOver: `line.3.horizontal` SF Symbol has no explicit accessibility label | Add `.accessibilityLabel("Menu")` to the menu button in `MainView.swift`. | `odoo/UI/Main/MainView.swift` | Existing XCUITest `app.buttons["Menu"]` would now find it; add an explicit assertion. |
| L9 | Privacy overlay (`H4 showPrivacyOverlay`) flips on `.background`, but iOS snapshots in `.inactive` | Move the overlay flip to the `.inactive` scenePhase handler. | `odoo/odooApp.swift` | New XCUITest: trigger background, screenshot the App Switcher snapshot, verify overlay is visible (or use `XCUIDevice.shared.press(.home)` and inspect the screenshot the OS captured). |
| L10 | `@MainActor WoowTheme` may not compile under Swift 6 strict concurrency if any background thread reads it | Audit all readers of `WoowTheme.shared.*`. Currently all are SwiftUI views (main-actor by default). Document the constraint. | Audit + comment in `WoowTheme.swift` | Compile under Swift 6 mode (`-strict-concurrency=complete`) and verify zero diagnostics in user code. |
| L11 | Keychain entries lack explicit `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` for security-critical items (PIN hash, FCM token) | Audit `SecureStorage.swift` and add the attribute for PIN hash, FCM token, and session cookies. Less-sensitive items (theme color) can stay default. | `odoo/Data/Storage/SecureStorage.swift` | Unit test: save a value with the strict attribute, lock the device (simulator equivalent), verify retrieval fails until unlocked. |

**Phase 3 acceptance criteria**: 11 fixes + audit script `audit_release_bundle_contents.sh` green + privacy-answers doc complete.

---

## 5. Phase 4 — Release-build verification (the gate that prevents regression)

The current CI runs only the Debug configuration. The test hooks
(`TestHookGate.testHooksEnabled`) are designed to be inert in Release —
but **this is unverified**. A bug in the gate, or a missed hook, would
silently ship.

### 5.1 New CI matrix

Add a parallel Release-build job to the existing CI:

```yaml
strategy:
  matrix:
    config: [Debug, Release]

steps:
  - xcodebuild build -configuration ${{ matrix.config }} -scheme odoo
  - xcodebuild test -configuration ${{ matrix.config }} -scheme odoo \
      -only-testing:odooTests/TestHookGateTest \
      -only-testing:odooTests/WoowThemeReactivityTest \
      -only-testing:odooTests/WoowThemeValidationTest
  # XCUITests still run only on Debug (Release builds aren't installable
  # in the simulator with the dev profile). Production-side hooks are
  # unit-tested in both configs.
```

### 5.2 New unit test asserting Release-mode inertness

```swift
// odooTests/ReleaseInertnessTest.swift  (NEW)
final class ReleaseInertnessTest: XCTestCase {
    /// In Release builds, `testHooksEnabled` MUST be false regardless of
    /// the launch arg. Compile-time guard via `#if !DEBUG`.
    func test_testHooksEnabled_isFalseInReleaseBuild() {
        #if DEBUG
        throw XCTSkip("This test is meaningful only in Release builds")
        #else
        // Even if a malicious caller could set the marker, gate stays false.
        // (Cannot actually mutate ProcessInfo.arguments at runtime in Swift,
        // so this is a compile-and-link verification — if `#if DEBUG` is
        // ever inverted, this test fails to compile.)
        XCTAssertFalse(TestHookGate.testHooksEnabled)
        #endif
    }
}
```

### 5.3 Static audits — source registry + release archive

Two scripts share a single source-of-truth registry, `KNOWN_HOOKS`,
listing every debug-only env var / launch arg the project recognises.

**`scripts/audit_test_hook_naming.sh`** (runs in CI on every PR):

```bash
# Source-side audit. Greps the swift source for any WOOW_TEST_* /
# WOOW_SEED_* reference and FAILS if it is not in KNOWN_HOOKS — i.e.,
# a contributor added a new hook but forgot to register it here.
KNOWN_HOOKS=(
  "WOOW_TEST_THEME_COLOR"
  "WOOW_TEST_FORCE_BIOMETRIC"
  "WOOW_TEST_FORCE_PIN"
  "WOOW_TEST_AUTOTAP"
  "WOOW_SEED_ACCOUNT"
  # When you add a new hook, register it here. Per CLAUDE.md
  # § "Debug Test Hooks — Naming, Gating & Registry (MANDATORY)".
)
# Implementation: extract every WOOW_TEST_*/WOOW_SEED_* token from
# `odoo/` source, diff against KNOWN_HOOKS, fail on mismatch in either
# direction. Also fails if a reference is not within a
# `TestHookGate.testHooksEnabled` guarded block (best-effort grep).
```

**`scripts/audit_release_archive.sh`** (runs at archive time, last gate
before TestFlight upload):

```bash
# Binary-side audit. Reads the SAME KNOWN_HOOKS list (sourced from a
# shared file so the two scripts cannot drift) and FAILS if any of
# those strings appear in the signed Release IPA — meaning a debug-only
# path leaked into production.
xcodebuild archive -configuration Release ...
unzip the .ipa
for hook in "${KNOWN_HOOKS[@]}"; do
    strings odoo.app/odoo | grep -q "$hook" \
        && { echo "FAIL: '$hook' present in release binary"; exit 1; }
done
```

The two scripts together form a closed loop:

- Source-side: every hook is registered → no silent additions in PRs.
- Binary-side: every registered hook is absent from Release → no
  silent leaks at ship time.

A new hook with a non-conforming prefix (e.g. `DEBUG_X`) is caught by
the source audit's prefix sweep — that auxiliary check rejects any
`ProcessInfo.processInfo.environment[...]` lookup whose key does NOT
start with `WOOW_TEST_` or `WOOW_SEED_`.

### 5.4 Manual smoke test on a Release-signed Ad-Hoc build

Before TestFlight submission, build a Release-configured Ad-Hoc IPA,
install on a device, and verify:

- Launch with NO env vars / launch args → app behaves as a normal user would see (default theme, no auth pre-seed)
- Settings → pick a color → tap Apply → header changes (proves the
  reactivity fix works in Release, not just Debug)
- Background + foreground → privacy overlay visible in App Switcher
- Receive a real FCM push from Odoo chatter → notification appears
  (proves the production APNs entitlement + register-on-login chain)

---

## 6. Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Apple changes Privacy Manifest requirements between this fix and submission | LOW | Subscribe to Apple Developer Updates; re-validate `PrivacyInfo.xcprivacy` 1 week before submission |
| Firebase 11.x.y bump introduces breaking API change | MED | Pin to a tested version; do the bump in a dedicated PR with full E2E re-run |
| Dev tunnel URL leaks into Release build via `TestConfig.plist` | LOW (with L7 build-phase check) | The Phase 3 build-phase script enforces this |
| New finding emerges from Apple's automated security scan | MED | Plan §4.4 manual smoke test on Ad-Hoc build catches most pre-submission |
| The H1 entitlement split is misconfigured and Release uses dev APNs | MED | Phase 4 archive-audit script greps the signed IPA for `aps-environment=production` |

---

## 7. Effort estimate

| Phase | Items | Effort |
|---|---|---|
| Phase 1 (HIGH) | 7 | ~2 days |
| Phase 2 (MED) | 6 | ~2 days |
| Phase 3 (LOW) | 11 | ~2 days |
| Phase 4 (Release verification) | 4 sub-items | ~1 day |
| **Total** | **24 + 4** | **~7 working days** |

Phases 1 and 4 are blocking; Phases 2 and 3 are recommended but not
blocking for first submission.

---

## 8. What's explicitly OUT of scope

- iOS-side equivalent of the Android FCM register-on-login bug
  (separate ticket — different feature)
- Migration to `@EnvironmentObject` from 8 `@ObservedObject` sites
  (premature optimization; current pattern works)
- Test-order randomization CI guard (broader infra change; tracked as
  separate ticket)
- Migrating the entire test suite to Swift Testing (`@Test`) macros
  (separate cleanup PR after first ship)
- Refactoring `TestConfig.plist` to use `.env.test` like Android
  (separate cleanup PR; the build-phase script in L7 protects ship-time
  even without this refactor)

---

## 9. Acceptance — go/no-go before submission

**MUST be true before tapping "Submit for Review" in App Store Connect**:

- [ ] All 7 Phase-1 fixes land
- [ ] All Phase-1 tests pass on Debug AND Release builds
- [ ] `scripts/audit_release_archive.sh` returns 0
- [ ] `scripts/audit_theme_color_usage.sh` returns 0
- [ ] `scripts/audit_pii_logging.sh` returns 0
- [ ] Manual Ad-Hoc smoke test (§5.4) passes on a real device
- [ ] App Store Connect Privacy questionnaire answers match
  `PrivacyInfo.xcprivacy` (per `docs/app-store-connect-privacy-answers.md`)
- [ ] TestFlight beta has been live ≥48 hours with no critical reports
- [ ] Adversarial-review pass returns "no NEW findings beyond
  documented out-of-scope items"

**Phase 2 is strongly recommended; Phase 3 is desirable but not
blocking.**
