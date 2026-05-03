# AI Instructions — Woow Odoo iOS App

## Project Overview

iOS port of the Woow Odoo Android companion app. Wraps Odoo ERP in WKWebView with native auth, FCM push, multi-account, biometric lock, and brand theming.

## Build Commands

```bash
# Build
xcodebuild -project odoo.xcodeproj -scheme odoo -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run unit tests
xcodebuild -project odoo.xcodeproj -scheme odoo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:odooTests test

# Run simulator verification (all milestones)
python3 scripts/verify_all.py
```

## Architecture

- **Language:** Swift only
- **UI:** SwiftUI (iOS 16+)
- **Storage:** Core Data (accounts), Keychain (passwords, PIN hash, FCM token)
- **Networking:** URLSession async/await, JSON-RPC 2.0
- **Push:** Firebase Cloud Messaging (FCM bridges to APNs)
- **DI:** Protocol-based injection (no DI framework)
- **Concurrency:** Swift actors, async/await, @MainActor

## Directory Structure

```
odoo/                    # Source (Xcode target: odoo)
  App/                   # App entry point
  Domain/Models/         # OdooAccount, AuthResult, AppSettings
  Data/API/              # OdooAPIClient, JsonRpcModels
  Data/Storage/          # Core Data, Keychain (M2)
  Data/Repository/       # AccountRepository, SettingsRepository (M3+)
  Data/Push/             # DeepLinkManager, DeepLinkValidator, FCM (M6)
  UI/Login/              # LoginView, LoginViewModel (M3)
  UI/Auth/               # BiometricView, PinView (M4)
  UI/Main/               # MainView, OdooWebView (M5)
  UI/Config/             # ConfigView (M7)
  UI/Settings/           # SettingsView, ColorPicker (M7)
  UI/Theme/              # WoowColors, WoowTheme
odooTests/               # Unit tests (XCTest)
odooUITests/             # UI tests (XCUITest)
scripts/                 # Automation scripts
docs/                    # Plans, verification logs
```

## Numbering System — All IDs Must Sync

Every milestone, commit, UX item, verification check, and test maps to a consistent numbering system.

### Milestones (M1–M10)

| ID | Milestone | Status | Commits | UX Items |
|----|-----------|--------|---------|----------|
| **M1** | Project Setup + Domain Models | **DONE** | IC01, IC02 | UX-72–74, UX-76–79 |
| **M2** | Core Data + Secure Storage | **DONE** | IC02, IC03 | UX-07, UX-22 |
| **M3** | Networking + Login Flow | **DONE** | IC03, IC04 | UX-01–09 |
| **M4** | Biometric + PIN Auth Gate | **DONE** | IC05, IC06 | UX-10–24 |
| **M5** | WKWebView + Main Screen | **DONE** | IC07, IC08 | UX-25–34 |
| **M6** | Push Notifications (FCM+APNs) | **DONE** | IC09, IC10 | UX-35–46, UX-71–75 |
| **M7** | Config + Settings + Theme | **DONE** | IC11, IC12, IC13 | UX-47–57, UX-67–70 |
| **M8** | Localization + Cache + iPad | **DONE** | IC14, IC15 | UX-58–66 |
| **M9** | Unit + UI Tests | **DONE** | IC16, IC17 | — |
| **M10** | App Store Prep + TestFlight | **DONE** | IC18 | — |
| **M11** | Code Quality Improvement | **DONE** | IC19, IC20 | — |

### Commit IDs (IC01–IC18)

| ID | Description | Milestone |
|----|-------------|-----------|
| IC01 | Xcode project setup, SPM deps, Firebase config | M1 |
| IC02 | Domain models: OdooAccount, AuthResult, AppSettings | M1, M2 |
| IC03 | SecureStorage (Keychain), OdooAPIClient, AppLogger | M2, M3 |
| IC04 | Login flow: LoginView, LoginViewModel, AccountRepository | M3 |
| IC05 | Biometric + PIN: BiometricView, PinView, PinHasher | M4 |
| IC06 | Auth navigation: AuthViewModel, AppRouter, scene phase | M4 |
| IC07 | WKWebView: OdooWebView, Coordinator, cookie sync, OWL | M5 |
| IC08 | MainView with toolbar, deep link consumption, loading | M5 |
| IC09 | Push: AppDelegate FCM, NotificationService, APNs | M6 |
| IC10 | Deep link: DeepLinkManager wiring, PushTokenRepository | M6 |
| IC11 | Config screen: ConfigView, account switching, logout | M7 |
| IC12 | Settings: SettingsView, security toggles | M7 |
| IC13 | Brand: WoowTheme, ColorPickerView | M7 |
| IC14 | Localization: en, zh-Hant, zh-Hans string catalogs | M8 |
| IC15 | Cache: CacheService, WKWebsiteDataStore clearing | M8 |
| IC16 | Unit tests: all ViewModels, repositories, validators | M9 |
| IC17 | UI tests: login flow, auth, navigation, settings | M9 |
| IC18 | TestFlight build, App Store metadata prep | M10 |
| IC19 | Refactor OdooAPIClient for testability (URLProtocol injection) | M11 |
| IC20 | Extract AppDelegate.handleNotificationTap for testability | M11 |

### UX Items (UX-01–UX-82)

From `docs/functional-equivalence-matrix.md`. Every UX item maps to a milestone:

| UX Range | Category | Milestone |
|----------|----------|-----------|
| UX-01–09 | Login | M3 |
| UX-10–24 | Biometric/PIN | M4 |
| UX-25–34 | Main WebView | M5 |
| UX-35–46 | Push Notifications | M6 |
| UX-47–57 | Settings | M7 |
| UX-58–66 | Language + Cache | M8 |
| UX-67–70 | Multi-Account | M7 |
| UX-71–75 | Deep Link Security | M1 (done), M6 |
| UX-76–82 | Visual Consistency | M1 (done), M5, M7 |

### Simulator Verification IDs (iV01–iVxx)

In `scripts/verify_all.py`. Each milestone adds a section:

| V-ID Range | Milestone | What It Checks |
|------------|-----------|----------------|
| iV01–iV07 | M1 | Install, launch, lifecycle, bundle, tests, security, colors |
| iV08–iV12 | M2 | Core Data CRUD, Keychain save/load, encryption |
| iV13–iV18 | M3 | Login flow, HTTPS, error messages, account saved |
| iV19–iV24 | M4 | Biometric prompt, PIN entry, lockout, bg→fg auth |
| iV25–iV30 | M5 | WebView loads, same-host, cookie sync, deep link |
| iV31–iV36 | M6 | FCM token, push received, notification tap, grouping |
| iV37–iV42 | M7 | Settings UI, color picker, app lock toggle, accounts |
| iV43–iV48 | M8 | Language switch, cache clear, iPad layout |
| iV49–iV54 | M9 | All tests pass, XCUITest flows |
| iV55–iV58 | M10 | Archive builds, TestFlight upload |

### Cross-Reference Example

To verify "user enters wrong PIN and gets locked out":
- **UX item:** UX-17, UX-18, UX-19
- **Milestone:** M4
- **Commit:** IC05
- **Unit test:** `PinHasherTests.test_lockout_givenFiveFailures_returns30Seconds`
- **Simulator check:** iV22-M4
- **Functional equiv:** Row 17-19 in functional-equivalence-matrix.md

## Milestone Workflow (MANDATORY for every milestone)

Every milestone MUST follow these steps in order. Do NOT skip any step. Do NOT commit until ALL steps pass. This pipeline is designed to be self-executing — Claude Code can run it autonomously.

```
┌─────────────────────────────────────────────────────────────────┐
│  SELF-DEVELOPING PIPELINE (runs for every milestone)            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Step 0: CHECK DEPENDENCIES                                     │
│          → Verify all dependent milestones are DONE             │
│          → e.g., M5 requires M3 + M4 both DONE                 │
│          → If not DONE, STOP — implement dependencies first     │
│                                                                 │
│  Step 1: READ PLAN                                              │
│          → Read milestone from ios-implementation-milestones.md │
│          → Understand deliverables, work items, verification    │
│          → Cross-reference UX items from functional-equiv.md    │
│          → List all files to create/modify                      │
│                                                                 │
│  Step 2: IMPLEMENT                                              │
│          → Follow directory structure and naming conventions     │
│          → All types Sendable if crossing actor boundaries      │
│          → No Any types in public API                           │
│          → Write unit tests alongside code (not after)          │
│                                                                 │
│  Step 3: ARCHITECT REVIEW                                       │
│          → Launch code-review-ai:architect-review agent         │
│          → Fix ALL critical and high findings                   │
│          → Document accepted medium/low findings                │
│          ┌─ If architect says "wrong approach" ──→ BACK TO 1   │
│          └─ If fixes needed ──→ fix then continue               │
│                                                                 │
│  Step 4: BUILD + UNIT TEST                                      │
│          → xcodebuild build must succeed                        │
│          → xcodebuild test must pass (0 failures)               │
│          → New code must have tests (never ship untested)       │
│          → ALL previous milestone tests must still pass         │
│          ┌─ If fails ──→ fix and re-run Step 4                 │
│          └─ If pass ──→ continue                                │
│                                                                 │
│  Step 5: SIMULATOR VERIFICATION                                 │
│          → Add new iV checks to scripts/verify_all.py           │
│          → Run full verify_all.py (ALL milestones, not just new)│
│          → Install app, test launch, lifecycle, UI              │
│          → Previous milestone checks must still pass (regression)│
│          ┌─ If fails ──→ fix and go back to Step 4             │
│          └─ If pass ──→ continue                                │
│                                                                 │
│  Step 6: BUG FIX LOOP                                           │
│          → If ANY test or verification failed in Steps 4-5      │
│          → Fix the bug                                          │
│          → Go back to Step 4 (re-run ALL tests, not just fixed) │
│          → Repeat until 0 failures across everything            │
│          → Max 5 iterations — if still failing, ask user        │
│                                                                 │
│  Step 7: REVIEW TEST QUALITY                                    │
│          → verify_all.py has checks for EVERY UX item           │
│          → Unit tests cover: happy path + errors + edge cases   │
│          → Test names: test_{method}_given{X}_returns{Y}        │
│          → No lazy tests (assert true, assert not null)         │
│          → Tests verify behavior, not implementation            │
│                                                                 │
│  Step 8: SYNC ALL DOCS                                          │
│          → CLAUDE.md: milestone status PLANNED → DONE           │
│          → ios-verification-log.md: append test results         │
│          → functional-equivalence-matrix.md: mark UX items done │
│          → Commit IDs match the plan                            │
│          → Code matches docs, docs match code                   │
│                                                                 │
│  Step 9: COMMIT                                                 │
│          → Only after ALL Steps 0-8 pass                        │
│          → Message: feat(M{n}): description                     │
│          → Include: build result, test count, iV count          │
│          → Include: Co-Authored-By line                         │
│                                                                 │
│  Step 10: POST-COMMIT SANITY CHECK                              │
│          → git log — verify commit is clean                     │
│          → Re-run verify_all.py one more time                   │
│          → If fails, revert and go back to Step 6               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Pipeline Guardrails

**Never commit with:**
- ❌ Failing tests (unit or simulator)
- ❌ Unreviewed code (skipped architect review)
- ❌ Missing iV checks in verify_all.py for this milestone's UX items
- ❌ Docs out of sync with code
- ❌ UX items not covered by tests
- ❌ Regression — previous milestones broken

**Escalate to user when:**
- ⚠️ Architect review says "wrong approach" (Step 3)
- ⚠️ Bug fix loop exceeds 5 iterations (Step 6)
- ⚠️ Platform limitation blocks a UX item (document in functional-equiv.md)
- ⚠️ Dependency on user action (Apple Developer account, Firebase setup, etc.)

---

## Conventions

- **All types:** `Sendable` conformance required for types crossing actor boundaries
- **Models:** Immutable (`let` properties), use copy methods for mutation
- **Naming:** `UpperCamelCase` types, `lowerCamelCase` methods
- **Test naming:** `test_{method}_given{Condition}_returns{Expected}` (e.g., `test_isValid_givenJavascript_returnsFalse`)
- **Test files:** Named by component (e.g., `DomainModelTests.swift`, `OdooAPIClientTests.swift`). All in `odooTests/`.
- **Verification script:** `scripts/verify_all.py` — cumulative, adds sections per milestone
- **Verification IDs:** `iV{nn}-M{n}` format, ranges reserved per milestone (see table above)
- **Commits:** Must pass build + unit tests + `verify_all.py` before committing
- **Commit messages:** `feat(M{n}): description` or `fix(M{n}): description` or `test(M{n}): description`
- **Security:** PIN hash in Keychain only, session ID in Keychain, HTTPS enforced, allowlist URL validation
- **No `Any` types** in public API — use `JsonValue` enum for heterogeneous JSON

## Reference Documents

| Document | Location | Content |
|----------|----------|---------|
| Functional equivalence | `docs/functional-equivalence-matrix.md` | 82 UX items, Android ↔ iOS |
| Implementation milestones | `docs/2026-03-25-ios-implementation-milestones.md` | M1–M10, Mermaid diagrams |
| Porting plan | `docs/2026-03-25-ios-porting-plan.md` | Architecture mapping, decisions |
| Verification log | `docs/ios-verification-log.md` | All simulator test results |
| Android reference | `/Users/alanlin/Woow_odoo_app/` | Source of truth for feature parity |

---

## Debug Test Hooks — Naming, Gating & Registry (MANDATORY)

App Store Review Guideline **2.3.1** prohibits hidden/dormant/undocumented
features in shipping binaries. To make this enforceable by CI rather than
by code review, ALL debug-only env vars, launch arguments, and Info.plist
overrides MUST follow these rules.

### Required prefixes

Every debug-only key MUST start with one of two prefixes:

- `WOOW_TEST_*` — runtime test hooks (e.g. `WOOW_TEST_FORCE_BIOMETRIC`,
  `WOOW_TEST_FORCE_PIN`, `WOOW_TEST_AUTOTAP`, `WOOW_TEST_THEME_COLOR`)
- `WOOW_SEED_*` — pre-seeded test fixtures (e.g. `WOOW_SEED_ACCOUNT`)

NO other prefix is permitted (`DEBUG_*`, `INTERNAL_*`, `QA_*`, ad-hoc
names like `ODOO_TUNNEL`, etc.).

### Required gating

Every read of a `WOOW_TEST_*` / `WOOW_SEED_*` key MUST be gated behind
`TestHookGate.testHooksEnabled` (`odoo/App/TestHookGate.swift`). The gate
is a belt-and-suspenders check: `#if DEBUG` AND the `-WoowTestRunner`
launch argument. Either alone is insufficient.

```swift
// REQUIRED
guard TestHookGate.testHooksEnabled else { return }
if let value = ProcessInfo.processInfo.environment["WOOW_TEST_FORCE_PIN"] {
    applyDebugSeed(pin: value)
}

// FORBIDDEN — bare #if DEBUG with no runtime gate
#if DEBUG
if let value = ProcessInfo.processInfo.environment["WOOW_TEST_FORCE_PIN"] {
    applyDebugSeed(pin: value)
}
#endif
```

### Required registry — `scripts/audit_test_hook_naming.sh`

Naming convention alone is not sufficient. The audit script holds an
explicit registry (`KNOWN_HOOKS`) listing every hook that exists. The
script enforces TWO directions:

1. **Source → registry**: greps source for any `WOOW_TEST_*` /
   `WOOW_SEED_*` reference and FAILS if it is not in `KNOWN_HOOKS`.
   This catches "someone added a new hook but forgot to register it".
2. **Registry → release binary**: at archive time
   (`scripts/audit_release_archive.sh`) greps the signed IPA for every
   string in `KNOWN_HOOKS` and FAILS if any are present. This catches
   "a debug-only code path leaked into the production binary".

Together the two directions form a closed loop: every hook is known,
every known hook is gated, every gated hook is absent from Release.

### When you add a new hook — checklist

1. **Name** it `WOOW_TEST_<purpose>` or `WOOW_SEED_<purpose>` — never any
   other prefix.
2. **Gate** every read behind `guard TestHookGate.testHooksEnabled else { ... }`.
3. **Register** the exact key in the `KNOWN_HOOKS` array at the top of
   `scripts/audit_test_hook_naming.sh`. Without this step the
   source-side audit blocks your PR.
4. **Test** — add an inertness test in `odooTests/TestHookGateTest.swift`
   asserting the hook is a no-op when the gate returns false.
5. **XCUITest** target MUST set `-WoowTestRunner` in
   `XCUIApplication.launchArguments` (the standard test setUp helper
   already does this — do not bypass it).

### Why a registry instead of a wildcard?

A pure prefix wildcard (`WOOW_TEST_|WOOW_SEED_`) would catch leaks of
known hooks but would silently let an attacker add a new hook in a PR
without anyone noticing — the wildcard would just absorb it. The
registry forces every new hook to surface in a script diff, which is
the part a human reviewer actually reads.

### Why this rule exists

The 2026-05-02 adversarial review found `WOOW_SEED_ACCOUNT` and
`WOOW_TEST_AUTOTAP` un-gated, after the 2026-04-28 hardening had already
gated 4 sibling hooks. The fix-by-fix review caught it, but a registered
+ gated audit catches it at commit time.

---

## XCUITest Development Process (MANDATORY)

These rules apply whenever writing or modifying XCUITests, especially those that interact with Springboard, the notification center, or any system UI.

### Core Rule: Analyze Before You Code

**Never write a test interaction against UI you have not observed.**

Before implementing any test step that taps, swipes, or queries a system screen:

1. Add a temporary element dump to capture what is actually on screen.
2. Run the dump.
3. Read the output.
4. Write the interaction based on what the dump shows.
5. Remove the dump code once the test passes.

Skipping this step and guessing element positions or identifiers is prohibited.

### Fail → Analyze → Fix Cycle (REQUIRED after every test failure)

Do NOT retry the same approach after a failure. Follow this cycle without exception:

```
Step 1: Test fails
Step 2: Insert element dump at the point of failure
         XCTContext.runActivity(named: "Dump screen") { _ in
             print(XCUIApplication().debugDescription)
             let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
             print(springboard.debugDescription)
         }
Step 3: Run the test — read the full dump output
Step 4: Identify the actual element label, identifier, or position from the dump
Step 5: Write the correct interaction using what the dump revealed
Step 6: Run the test again — if it passes, remove the dump code
Step 7: If it still fails, repeat from Step 2 with more context captured
```

Do not proceed past Step 3 without actually reading the dump output. Guessing after a failure is a process violation.

### Notification Center — Search Strategy (REQUIRED order)

Notifications can appear in many states: at the top, at the bottom, grouped, collapsed under a Focus mode banner, or hidden until the user scrolls. Never assume a fixed position.

Always attempt strategies in this order, logging which one succeeds:

```swift
// Strategy 1: Direct search — notification already visible
if springboard.otherElements["NotificationShortLookView"].firstMatch.waitForExistence(timeout: 3) {
    print("[NotifStrategy] Found via direct search")
    // interact
}
// Strategy 2: Expand a notification group
else if springboard.otherElements["NotificationGroupView"].firstMatch.exists {
    springboard.otherElements["NotificationGroupView"].firstMatch.tap()
    print("[NotifStrategy] Expanded group")
    // search again
}
// Strategy 3: Dismiss Focus mode banner if present
else if springboard.buttons["Open"].exists || springboard.staticTexts["Focus"].exists {
    // handle focus dismissal
    print("[NotifStrategy] Dismissed Focus banner")
}
// Strategy 4: Swipe up from bottom to reveal notification
else {
    springboard.swipeUp()
    print("[NotifStrategy] Swiped up to reveal")
    // search again
}
```

If none of the four strategies finds the notification, capture a screenshot and the full element dump before failing the test — do not silently assert false.

### Screenshot Capture on Failure (REQUIRED)

Every test that touches system UI must attach a screenshot on failure:

```swift
let screenshot = XCUIScreen.main.screenshot()
let attachment = XCTAttachment(screenshot: screenshot)
attachment.lifetime = .keepAlways
add(attachment)
```

Place this inside any `XCTFail` or `guard` failure path so the CI artifact always contains visual evidence.

### Prohibited Patterns

- Copying a swipe or tap from a previous test without running a dump on the current screen first.
- Retrying an identical approach more than once after a failure.
- Using hardcoded element indices (e.g., `buttons.element(boundBy: 2)`) without dump confirmation.
- Silently swallowing a `waitForExistence` timeout without capturing state.

### Debug Dump Removal

Debug dumps are temporary. Once a test passes reliably:
- Remove all `print(app.debugDescription)` and `print(springboard.debugDescription)` calls.
- Keep only the `[NotifStrategy]` log lines — they are useful for CI triage and are not debug noise.

### Test Configuration — Single Source of Truth (MANDATORY)

Test configuration (server URL, database, credentials, etc.) MUST be read from
`SharedTestConfig` (which reads `odooUITests/TestConfig.plist`, with env-var
override). Do not introduce ad-hoc `ProcessInfo.processInfo.environment["..."]`
lookups in test helpers or test cases.

**Required:**
```swift
// In a test helper or test case:
let url = "https://\(SharedTestConfig.serverURL)"
let db  = SharedTestConfig.database
let user = SharedTestConfig.adminUser
```

**Forbidden:**
```swift
// Do NOT add new env-var keys for test config:
let raw = ProcessInfo.processInfo.environment["ODOO_TUNNEL"] ?? "..."
let db  = ProcessInfo.processInfo.environment["ODOO_DB"]    ?? "..."
```

**Why:**
- Single source of truth — when the dev tunnel rotates, you edit one file (`TestConfig.plist`).
- CI override path already exists — `SharedTestConfig` reads `TEST_SERVER_URL`,
  `TEST_DB`, `TEST_ADMIN_USER`, `TEST_ADMIN_PASS`, etc. before falling back to
  the plist. CI sets these env vars; local dev edits the plist.
- Test plans (`*.xctestplan`) MUST NOT hardcode environment-specific values
  (tunnel URLs, simulator UDIDs, machine paths). Keep test plans portable —
  only generic flags like `RUN_LOCATION_E2E=1` belong there.

**If you genuinely need a new test-config key**, add it to `SharedTestConfig`
(plist key + env override + default fallback) — do NOT bypass it.

This rule exists because a previous PR introduced `ODOO_TUNNEL` and
`SIMCTL_UDID` env vars hardcoded into a test plan, which broke for everyone
else and rotted within hours of the next tunnel restart.

---

## Development Workflow (MANDATORY)

### Plan → Implement → Test → Commit

Every feature or fix follows this cycle:

```
1. PLAN    — Write <Date>-<Title>_Implementation_Plan.md + <Date>-<Title>_Test_Plan.md
2. COMMIT  — Commit the plan docs (before any code changes)
3. IMPLEMENT — Write the code per the plan
4. TEST    — Run unit tests + E2E tests per the test plan
5. If tests FAIL:
   a. Analyze the failure (follow Fail → Analyze → Fix cycle)
   b. Update the plan if the approach was wrong
   c. Modify the implementation
   d. Re-test until ALL criteria pass
6. COMMIT  — Commit the working code with test results
7. PUSH    — Push to GitHub
```

Do NOT skip the plan step. Do NOT commit code that hasn't been tested.

### Document Naming Convention

All plan documents in `docs/` follow this format:

```
<YYYY-MM-DD>-<Title-In-Kebab-Case>_Implementation_Plan.md
<YYYY-MM-DD>-<Title-In-Kebab-Case>_Test_Plan.md
```

Examples:
- `2026-04-05-P0-P1-Gap-Fix_Implementation_Plan.md`
- `2026-04-05-P0-P1-Gap-Fix_Test_Plan.md`
- `2026-04-05-Auto-Login-Deep-Link_Implementation_Plan.md`

The `_Implementation_Plan` and `_Test_Plan` suffixes are mandatory. Each feature should have both.

---

## Localization Rules (MANDATORY)

### String Handling
- **All user-visible strings** must be in `Localizable.strings` (en, zh-Hans, zh-Hant)
- SwiftUI `Text("Key")`, `Label("Key", ...)`, `Section("Key")` auto-match Localizable.strings keys
- Use the **English text as the key** (not snake_case): `"Visit Website" = "访问网站";`
- **Never** leave zh-Hans/zh-Hant translations as English copies — provide real translations
- URLs and brand names (Odoo, WoowTech) stay in English across all locales

### Production Checklist (before every commit with UI changes)
- [ ] All new strings added to all 3 Localizable.strings files
- [ ] zh-Hans has Simplified Chinese translations
- [ ] zh-Hant has Traditional Chinese translations
- [ ] Decorative images have `.accessibilityHidden(true)`
- [ ] External URL constants extracted (not inline in views)
- [ ] Dark mode tested (use `.foregroundStyle(.primary/.secondary)`, not hardcoded colors)

---

## Constants & Testability

- Extract URLs, email addresses, and display strings into `enum Constants` or dedicated `enum SettingsConstants`
- ViewModel properties (`appVersion`, `currentLanguageDisplayName`) must be testable — no inline `Bundle.main` calls in views
- Use protocol-based DI for repositories so ViewModels are unit-testable with mocks
