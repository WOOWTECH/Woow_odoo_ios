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
