# AI Instructions — Woow Odoo iOS App

## Project Overview

iOS port of the Woow Odoo Android companion app. Wraps Odoo ERP in WKWebView with native auth, FCM push, multi-account, biometric lock, and brand theming.

## Build Commands

```bash
# Build
xcodebuild -project odoo.xcodeproj -scheme odoo -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run unit tests
xcodebuild -project odoo.xcodeproj -scheme odoo -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:odooTests test

# Run simulator verification
python3 scripts/verify-on-simulator.py
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

## Conventions

- **All types:** `Sendable` conformance required for types crossing actor boundaries
- **Models:** Immutable (`let` properties), use copy methods for mutation
- **Naming:** `UpperCamelCase` types, `lowerCamelCase` methods, `test_methodName_givenCondition_expectedResult` for tests
- **Test files:** Named `{Milestone}_{Component}Tests.swift` (e.g., `M1_DomainModelTests.swift`)
- **Verification IDs:** `iV{nn}-M{n}` format matching milestones
- **Commits:** Verify (build + test + simulator) before committing
- **Security:** PIN hash in Keychain only, session ID in Keychain, HTTPS enforced, allowlist URL validation
- **No `Any` types** in public API — use `JsonValue` enum for heterogeneous JSON

## Reference Documents

- `docs/functional-equivalence-matrix.md` — 82 UX items, Android ↔ iOS
- Implementation plan: `/Users/alanlin/Woow_odoo_app/docs/plans/2026-03-25-ios-implementation-milestones.md`
- Android reference: `/Users/alanlin/Woow_odoo_app/`
