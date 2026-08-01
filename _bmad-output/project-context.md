---
project_name: 'Woow Odoo iOS'
user_name: 'alanlin'
date: '2026-08-01'
scope: 'worktrees/ios (github.com/WOOWTECH/Woow_odoo_ios) — the iOS app only'
supersedes: 'project-context.md dated 2026-05-04/2026-05-10 (28 claims contradicted by code)'
source: '_bmad-output/gpc-input/ios-dossier.md (verified 2026-07-28) + direct re-verification 2026-08-01'
sections_completed:
  ['technology_stack', 'language_rules', 'framework_rules', 'testing_rules', 'quality_rules', 'workflow_rules', 'critical']
status: 'complete'
optimized_for_llm: true
---

# Project Context for AI Agents — Woow Odoo iOS

_Critical rules and patterns for implementing code in `worktrees/ios`. Focus is on unobvious details agents get wrong. Every claim here was read out of the code, not out of the docs — where CLAUDE.md and the code disagree, this file follows the code and says so._

**Anchor policy:** cite files and symbol names, not line numbers. Line numbers in this repo drift by 6–15 lines per release. If you need an exact site, grep for the symbol.

---

## Technology Stack & Versions

Read from `odoo.xcodeproj/project.pbxproj`, not from docs:

- **Swift 5.0** (`SWIFT_VERSION = 5.0` in all 6 build configurations). **Not** Swift 6. No `SWIFT_STRICT_CONCURRENCY` setting exists anywhere.
- **iOS 16.0 deployment target** (`IPHONEOS_DEPLOYMENT_TARGET = 16.0`), `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone + iPad).
- **Xcode 16 project format** — `objectVersion = 77`, `LastUpgradeCheck = 1640`.
- **SwiftUI** for all UI. **WKWebView** hosts the Odoo web app.
- **Storage:** Core Data (`NSPersistentContainer`, store `"WoowOdoo"`) + Keychain (`SecItem*`, service `io.woowtech.odoo.keychain`). `UserDefaults` is used by `DeepLinkManager` only.
- **Networking:** `URLSession` async/await + hand-rolled **JSON-RPC 2.0**. No Alamofire/Moya.
- **Push:** Firebase iOS SDK, SPM, `upToNextMajorVersion` from 11.0.0. **Only `FirebaseMessaging` is linked.** `Package.resolved` is **gitignored** — the version is not pinned in the repo (locally untracked at `odoo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, currently firebase-ios-sdk 11.15.0). A fresh clone is not reproducible.
- **Dependency manager:** SPM only, exactly one package. No CocoaPods/Carthage/`Package.swift`.
- **Tests:** **XCTest only** (39 test files `import XCTest`; **0** files `import Testing`). See Testing Rules — this is a compile-blocking constraint.
- **Frameworks imported in source:** SwiftUI, WebKit, CoreData, Security, LocalAuthentication, CoreLocation, CommonCrypto, `os`, Combine, UIKit, **UserNotifications**, **FirebaseCore** (`AppDelegate` imports FirebaseCore even though only the FirebaseMessaging product is linked — it resolves transitively; swapping the SPM product breaks `AppDelegate`).
- **Bundle ID** `io.woowtech.odoo` (`.odooTests`, `.odooUITests`) · **URL scheme** `woowodoo://` · **Team** `W4UWZ8NP2P`.
- **Version:** `MARKETING_VERSION = 1.0` / `CURRENT_PROJECT_VERSION = 1` in every configuration — never bumped, no tags, no changelog. **There is no release process; do not assume one.**
- **Privacy manifest** `odoo/PrivacyInfo.xcprivacy`: declares `NSPrivacyCollectedDataTypePreciseLocation` (linked=false, tracking=false, AppFunctionality) **and three `NSPrivacyAccessedAPITypes`** — UserDefaults `CA92.1`, FileTimestamp `C617.1`, DiskSpace `E174.1`.
- **Per-configuration entitlements:** Debug → `odoo/odoo.entitlements` (`aps-environment = development`); Release → `odoo/odoo-Release.entitlements` (`aps-environment = production`). They are independent files — a new entitlement must be added to both.
- **No CI.** No `.github/`, no git hooks beyond Git's samples. See Workflow Rules for the one automated gate that does exist.

---

## Critical Implementation Rules

### Build-System Rules (read these first — they decide whether your code compiles)

**B1. Never hand-edit `project.pbxproj` to add a file.**
All three targets use Xcode 16 **`PBXFileSystemSynchronizedRootGroup`**. A `.swift` file is a member of a target purely by living under `odoo/`, `odooTests/`, or `odooUITests/`. There is **no `PBXBuildFile` entry, no Sources build-phase list** to update — and there is no way to exclude a file by editing the pbxproj either. The **only** membership exception declared in the project file is `odoo/Info.plist`. Same mechanism is why `PrivacyInfo.xcprivacy`, `Localizable.strings`, `geolocation_shim.js` and `TestConfig.plist` appear nowhere by name in the pbxproj.
→ To create a file: write it to the right directory. Done.
→ To keep a file out of Release: wrap the **entire file** in `#if DEBUG` (the pattern used by `SeededAccount.swift`, `E2EWebViewProbe.swift`, `TestNotificationTapInjector.swift`). Target membership cannot do it.

**B2. XCTest only — `@Test` / `#expect` will not compile.**
Zero files import swift-testing, there is no swift-testing dependency, and `SWIFT_VERSION = 5.0`. Write `XCTestCase` subclasses with `XCTAssert*`. Use `@testable import odoo`.

**B3. iOS 16 API ceiling.** `.onChange(of:) { newValue in }` — the **single-parameter** iOS 16 closure. The iOS 17 two-parameter form does not compile against the 16.0 deployment target. `NavigationStack` only; `NavigationView` appears zero times. iOS 17-only APIs must be `if #available` guarded (see `WKWebsiteDataStore(forIdentifier:)` in `OdooWebView`).

---

### Language-Specific (Swift) Rules

**Concurrency / isolation**
- **`@MainActor` at the TYPE level** on every ViewModel (`AuthViewModel`, `MainViewModel`, `AppRootViewModel`, `ConfigViewModel`, `LoginViewModel`), on `DeepLinkManager`, and on `WoowTheme` (documented as required: `@Published` mutation off-main triggers SwiftUI's background-publish warning). Never property-level.
- **Actors for shared mutable state, not class+lock**: `OdooAPIClient`, `SessionReauthenticator`, `TokenRegistrationGate` are `actor`s.
- **`SettingsRepository` and `SecureStorage` are synchronous, non-isolated, main-actor-called.** They are **not** actors and **not** async. New code must not `await` them, and must not make them async (see C12 — the main-thread hazard).
- `nonisolated` is used deliberately where the underlying API is already thread-safe (`OdooAPIClient.getSessionId(for:)`, because `HTTPCookieStorage` is).
- `MainActor.assumeIsolated { }` is the idiom for hopping back inside a non-async callback.
- **`@unchecked Sendable` has exactly three production sites**: `PersistenceController` (`NSPersistentContainer` isn't Sendable), `AccountRepository`, `ReloginSignal` (guards state with `NSLock`). Do not add a fourth to silence a warning — fix the mutability. Protocols crossing actor boundaries are `Sendable`: `AccountRepositoryProtocol`, `SecureStorageProtocol`, `SessionAuthenticating`, `ReloginSignaling`.

**Purity and shape**
- **Pure decision logic goes in FREE FUNCTIONS or caseless `enum` namespaces at file scope — not methods, not ViewModel members.** In force: `resolveAuthAction(...)` and `isPinLockedOut(...)`/`pinLockoutRemainingSeconds(...)` are top-level `func`s; `NotificationDeepLinkRouter`, `DeepLinkValidator`, `PinHasher`, `SessionExpiry`, `AppLogger`, `TestHookGate` are caseless enums. Do **not** wrap new pure logic in a class.
- **State is modelled as `Equatable` enums with associated values** — `AppLockUIState`, `AuthAction`, `BiometricOutcome`, `NotificationDeepLinkRouter.Decision`, `NavigationDecision`, `DeepLinkApplyPlan`. This is what makes them assertable with one `XCTAssertEqual`; keep it.
- **Domain models are only PARTLY immutable.** `OdooAccount` is all-`let` with a defaulted memberwise init — genuinely immutable. **`AppSettings` is all-`var`**, and the project's mutation idiom is read-mutate-write: `var s = secureStorage.getSettings(); s.x = y; secureStorage.saveSettings(s)`. Do not "fix" `AppSettings` to `let`; do not assume immutability project-wide.
- Optional `Decodable` fields that must survive an older payload are declared `var … = nil`, not `let`, so the synthesized memberwise init keeps them optional (`SeededAccount` documents this).
- **Exactly one `try!` in the app target** — `DeepLinkValidator` (static regex), carrying `// swiftlint:disable:this force_try`. Do not add a second.

**Logging**
- `AppLogger` (`odoo/App/AppLogger.swift`) exposes 9 `os.Logger` categories on subsystem `io.woowtech.odoo`: `auth, network, push, webview, settings, theme, lifecycle, location, data`.
- **Privacy is enforced by omission:** no `privacy:` argument means `.private` (redacted in Release). `privacy: .public` is used only for booleans, integers, system error strings, and non-secret identifiers. Never mark a server URL, username, session id, token, or PIN public.
- **Known deviation:** `OdooAPIClient` creates its own tenth logger, `Logger(subsystem: "io.woowtech.odoo", category: "API")`, outside `AppLogger`. New network code should use `AppLogger.network`; don't be surprised by the existing one.
- `print()` survives only inside `#if DEBUG` test-hook paths. Zero production-path `print()`.

**Localization — TWO key styles coexist and both are correct**
- Three **legacy `.lproj/Localizable.strings`** files: `odoo/Resources/{en,zh-Hans,zh-Hant}.lproj/`. Each is **142 lines / 107 keys** and they must stay identical in key set. `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` is set but **there is no `.xcstrings` catalog** — do not create one ad hoc; do not migrate without a decision.
- Of the 107 keys, **42 are symbolic snake_case** (`error_network`, `biometric_reason`, `enter_pin_title`, `lockout_timer_%lld`, `logout_confirm_message`, `account_switched_to`, …) and the rest are English-text-as-key (`"Login" = "Login";`). **New error/system strings follow the symbolic style**; SwiftUI-literal UI text follows English-as-key. Format specifiers (`%lld`, `%@`) are part of the KEY.
- Call style is `String(localized: "key")`. Format strings: `String(format: String(localized: "lockout_timer_%lld"), remaining)`.
- **Adding one user-facing string means editing all three files with real translations.** Never ship an English copy in a Chinese file. Brand names (Odoo, WoowTech) stay romanized in all locales. Nothing enforces this — it is a review-time obligation.

---

### Framework / Architecture Rules

**Layering.** `odoo/App/` (AppDelegate, AppLogger, TestHookGate, DEBUG probes) · `odoo/Data/{API,Location,Push,Repository,Storage}` · `odoo/Domain/Models` · `odoo/UI/{App,Auth,Common,Config,Login,Main,Settings,Theme}`. ViewModels live under `UI/<feature>/`, not a `ViewModels/` folder.
**`odooApp.swift` is at the TARGET ROOT** — `odoo/odooApp.swift`, **not** `odoo/UI/App/`. `odoo/UI/App/` contains exactly one file, `AppRootViewModel.swift`.

**Dependency injection — constructor defaults, no container.** Every injectable type takes collaborators as init parameters *with production defaults*, so `Foo()` works in the app and `Foo(dep: fake)` works in tests. Examples: `AuthViewModel(settingsRepository:authenticator:)`, `AppRootViewModel(accountRepository:pushTokenRepository:reauthenticator:)`, `DeepLinkManager(defaults:)`, `OdooAPIClient(session:)`. `SettingsRepository(secureStorage:now:)` **injects the wall clock** as `now: @escaping () -> TimeInterval` — a prior `systemUptime` implementation broke across reboots.
**Known deviation:** DI is not universal — `AppRootView` instantiates `AccountRepository()` **directly inside the View**. The data layer does leak into the View. Don't cite the View as a DI example.

**SwiftUI**
- Single `@main` App → `AppRootView`. No `NavigationPath`, no route enum: navigation is `NavigationStack` + `.sheet` + a `LaunchState` switch.
- `@StateObject` for ownership, `@ObservedObject` for injected/singleton. Every themed view repeats `@ObservedObject private var theme = WoowTheme.shared`. This redraws on any `@Published` change of the singleton — that simplicity is intentional; don't replace it with a cleverer subscription.
- **`scenePhase` is translated into domain events at the root and never leaked into ViewModels** (`odooApp.swift`): `.inactive` → privacy overlay ONLY (explicitly **do not re-lock here** — the Face ID sheet itself drives `.inactive`); `.background` → `authViewModel.appDidEnterBackground()`; `.active` → `authViewModel.appDidBecomeActive()`.
- `.transaction { $0.animation = nil }` is used deliberately to kill the Group cross-fade so XCUITest never sees two screens in the a11y tree.
- Colors come from `WoowTheme.shared.primaryColor` or system semantic styles (`.secondary`, `.thinMaterial`, `Color(.systemBackground)`). Hardcoded hex/`.black`/`.white` outside the theme palette breaks dark mode and theme reactivity at once.
- **View purity is NOT uniform.** `AppRootView.authenticatedContent` is a pure `switch` over `authViewModel.uiState`, and `BiometricView` / `AuthSetupRequiredView` are genuinely render-only (all `let` + closures; `BiometricView` documents "RENDER ONLY … owns no `LocalAuthentication`, no `scenePhase`, no auto-prompt"). **`PinView` is NOT render-only** — it declares `@ObservedObject var authViewModel: AuthViewModel` (the whole ViewModel is passed in) and owns five `@State` values including a live `Timer` (`pin`, `error`, `isShaking`, `isLockedOut`, `lockoutTimer`). PIN-screen timing/lockout display logic lives in the View and is untested. Treat "all three auth views are render-only" as **false**; refactoring `PinView` on that assumption will break it.

**Auth flow (App Lock) — fail-closed by design**
- `resolveAuthAction` returns `.none` **only** when `appLockEnabled == false`. App Lock on + no usable method → `.setupRequired` (a blocking device-passcode screen). Never add a path returning `.none` while App Lock is on.
- Two guards in `AuthViewModel` that look like dead code and are not: **`promptedThisLock`** (biometric prompt auto-runs at most once per lock; reset only in `relock()`, never on `.inactive`) and **`lockGeneration`** (bumped in `relock()`; `applyBiometricOutcome(_:generation:)` / `applyDevicePasscodeOutcome(success:generation:)` discard a stale-generation success). Those two methods are **internal, not private, specifically so the guards are unit-testable** — do not "tidy" them to private.
- **`AuthViewModel.setAuthenticated(false)` is not a plain setter** — it routes through `relock()`, bumping `lockGeneration` and clearing `promptedThisLock`. External callers in `odooApp.swift` depend on that. Replacing it with an assignment silently disables the stale-success guard.
- PIN is verified **once per full 6-digit entry** (`enterPinDigit` returns `.needMoreDigits` until `currentPin.count >= PinHasher.pinLength`). Per-keystroke verification burned five lockout attempts on one wrong PIN.
- `PinHasher`: PBKDF2-HMAC-SHA256, 600 000 iterations, 16-byte salt, 32-byte key, stored `salt_hex:hash_hex`, constant-time compare (`constantTimeEqual`). `maxAttemptsPerTier = 5` and `pinLength = 6` are `static` (shared sources of truth). `lockoutDurations` (30s → 5min → 30min → 1h) is **`private static`** — not accessible; don't cite it as a reusable constant.
- Lockout is **counter-gated AND time-gated**: `isPinLockedOut` requires `failedAttempts >= maxAttemptsPerTier` *and* `now < lockoutUntil`. The counter resets only on a correct PIN, so a clock-forward yields at most one guess per jump.

**Core Data — there is NO `.xcdatamodeld`**
- The managed object model is built **programmatically** in `PersistenceController.buildManagedObjectModel()` — hand-constructed `NSEntityDescription`/`NSAttributeDescription`. Xcode's data-model editor will find nothing.
- Adding an attribute is **four coordinated edits**: the `NSAttributeDescription` block, appending it to `entity.properties`, the `@NSManaged` property on `OdooAccountEntity`, and both `toDomainModel()` and `update(from:)`. New attributes **must be `isOptional = true`** or lightweight migration fails on existing installs (see `tenantIdAttr`).
- Single store `"WoowOdoo"`, single entity `OdooAccountEntity`, lightweight migration on. `loadPersistentStores` **`fatalError`s in DEBUG, logs `AppLogger.data.fault` in Release**.
- All access is on `container.viewContext` from the main actor via `AccountRepositoryProtocol`; fetch requests are static factories on the entity. Tests use `PersistenceController(inMemory: true)`.

**Keychain (`SecureStorage`)**
- **Single service string** `"io.woowtech.odoo.keychain"`. **It is the `kSecAttrAccount` KEY that is host-scoped, not the service**: `pwd_{host}_{username}`, `session_{host}_{username}`. Unscoped keys: `pin_hash`, `fcm_token`, `location_enabled`, `app_settings`.
- **Writes are `SecItemUpdate`-first, `SecItemAdd` on `errSecItemNotFound`** — commented "atomic update-or-add pattern. Avoids race condition from delete-then-add." **Do not "fix" this back to delete-then-add.** Consequence: `kSecAttrAccessible` / `kSecAttrSynchronizable` are set **on the add path only**, so an item created before those attributes existed keeps its old accessibility forever.
- `kSecClassGenericPassword` only; `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`.
- `AppSettings` is stored as **one JSON blob** under `app_settings` — Keychain only. The doc comment in `AppSettings.swift` claiming "UserDefaults/Keychain" is wrong.
- Legacy `pwd_{username}` → `pwd_{host}_{username}` migration runs idempotently in `AccountRepository.init`.
- Keychain survives app reinstall — desirable for the PIN, a footgun for a stale session id. Be intentional per key.

**WKWebView (`OdooWebView`) — rewritten; the old two-cookie-store model is obsolete**
- **Per-account isolated data stores.** The representable is never recreated on account change (no `.id(account)`); `OdooWebViewCoordinator.apply(...)` is the single mutation entry point and swaps a child `WKWebView` inside a stable container. `dataStore(forAccountId:)` returns `WKWebsiteDataStore(forIdentifier: uuid)` on **iOS 17+**, `.default()` below. So there are **N+1 cookie jars**: `HTTPCookieStorage.shared` (URLSession/JSON-RPC) plus one WebKit store per account UUID. Writing a cookie into `.default()` does nothing for a real account on iOS 17+.
- **The session cookie must commit before the first load** — `store.httpCookieStore.setCookie(cookie) { self?.loadBase(...) }`; the load lives *inside* the completion handler. Fire-and-forget lands the WebView on the public Odoo page.
- **Deep links are applied by a full `load()`, never by poking `location.hash`.** `deepLinkApplyPlan` has a single case, `.load(URL)`. Odoo 18's `/odoo/...` path router ignores `location.hash`/`hashchange`; a hash poke leaves every notification tap on the Discuss Inbox.
- **Deep-link application is load-gated**: applied in `didFinish` only when `webView.url?.host` case-insensitively matches `currentServerHost`. This is what stops a link landing on the wrong account mid-switch.
- `javaScriptCanOpenWindowsAutomatically = false`; `WKUIDelegate.createWebViewWith` reloads `target=_blank` in place and returns nil.
- `decideNavigation(for:)` is a pure function returning `.allow / .sessionExpired / .openInSafari / .cancel`; `/web/login` in the URL means session expired.
- `injectOWLLayoutFixes` runs on every `didFinish` — Odoo's OWL needs it for viewport sizing. It will silently regress if you refactor the WebView and drop it.
- **`CacheService.clearWebViewCache()` deliberately excludes cookies to preserve login** — it clears only `DiskCache`/`MemoryCache`/`OfflineWebApplicationCache` and the code says so ("cookies excluded to preserve login"). Do not "helpfully" add `WKWebsiteDataTypeCookies`. It also touches only `WKWebsiteDataStore.default()`, so it **misses every per-account store**, and it is called **only** from `SettingsViewModel`'s "Clear Cache" action — **logout never calls it**.

**Push / FCM / multi-account routing**
- `AppDelegate.handleNotificationTap(userInfo:accountRepository:)` is a thin executor; the decision lives in the pure `NotificationDeepLinkRouter.decide(userInfo:resolveTenant:activeAccount:) -> Decision` (`.switchAndRoute / .useActive / .drop(DropReason)`). Payload keys are constants: `odoo_action_url`, `odoo_tenant_id`.
- **Cross-tenant isolation invariant:** a present-but-unresolved `odoo_tenant_id` → `.drop(.unresolvedTenant)`. **Never** fall back to the active account. `AccountRepository.getAccount(byTenantId:)` also refuses an empty id.
- Pending deep links are **bound to an account id, TTL'd at 5 minutes, single-consume**, persisted to `UserDefaults` and cleared from disk on cold-start restore so a link cannot replay across launches.
- `activateAccount(id:)` is a **synchronous, no-network** switch that posts `Notification.Name.activeAccountDidChange`. **Three call sites post it** (`activateAccount`, and two other `AccountRepository` paths incl. logout promotion). `MainViewModel` reloads the WebView on it — a fourth mutation path that forgets to post leaves the WebView on the previous account.
- `TokenRegistrationGate` (actor) dedupes concurrent identical-token registration passes — login success and Firebase's `didReceiveRegistrationToken` fire milliseconds apart and used to double-register.
- Token rotation **unregisters the OLD token from every account first**, then registers via `SessionHealingRegistrar` and persists the server-issued `tenant_id` (`PushTokenRepository.parseTenantId`).
- Registration reconcile fires on three events: cold start (`AppRootViewModel.checkSession`), login success (`onLoginSuccess`), account switch (`ConfigViewModel.switchAccount`).
- **Honest logout:** `AccountRepository.logout` best-effort unregisters, then **deletes the Core Data row** plus the Keychain password and session id, then promotes the most-recent remaining account and broadcasts. Reverting to "clear the cookie only" resurrects the demo444 poisoned-reconcile bug. `unregisterFcmToken` must keep `serverUrl.ensureHTTPS` — the old `"https://\(serverUrl)"` produced `https://https://…` and silently swallowed every unregister.

**Session self-heal**
- Odoo signals an expired session as **HTTP 200 with a `SessionExpiredException` JSON-RPC error envelope**, not 401. Detection is body-inspecting (`SessionExpiry.isSessionExpired(httpCode:body:)`); `OdooAPIClient.callKw` throws `OdooAPIError.sessionExpired`. A status-code-only handler never fires.
- `SessionHealingRegistrar.callKwHealing` re-auths **once** and replays **once**; a second `.sessionExpired` propagates. The cap is structural, not a counter.
- `SessionReauthenticator` (actor) enforces five documented guardrails: https-only + exact stored host, cap = 1, bad-credential STOP with an open circuit + `ReloginSignal`, per-host single-flight `Task` map, never log credentials. Relaxing any one either re-sends a user password to an unvalidated host or loops forever against a changed password.
- `AppRootViewModel.onSessionExpired()` self-heals before bouncing to login; `attemptSelfHealOrLogin()` is `@discardableResult` and awaitable purely for deterministic tests.

**Location**
- `LocationPermissionGate` enforces **THREE** checks in order, not two: (1) **origin-host match against the active account** → `.reject(reason: "origin-host-mismatch")` — this is the security boundary for the JS bridge; (2) `settings.locationEnabled`; (3) `CLAuthorizationStatus`. Location code must go through the gate, never `CLLocationManager` directly.
- `odoo/Data/Location/geolocation_shim.js` is injected as a `WKUserScript` at `.atDocumentStart`.

---

### Testing Rules

**Frameworks.** XCTest only — see B2. `@testable import odoo`. Current baseline: `-only-testing:odooTests` runs **373 tests, 1 skipped, 0 failures** in ~8s.

**HARNESS GOTCHA 1 — the default test plan is `LocationE2E.xctestplan`.** `odoo.xcscheme` sets `shouldAutocreateTestPlan = "NO"` and defaults to it. That plan includes all of `odooTests`, only **two selected** `odooUITests` methods (`E2E_LocationClockInTests/test_clockIn_recordsNonZeroGPS_via_systray` and `…/test_clockOutThenIn_populatesBothGPSColumns`), and injects `RUN_LOCATION_E2E=1` for every configuration. **A newly added XCUITest is invisible to the default plan.** Always pass `-only-testing:odooUITests/<Class>/<method>` explicitly.

**HARNESS GOTCHA 2 — most XCUITests never activate the hooks they rely on.** `TestHookGate.testHooksEnabled` is `#if DEBUG && arguments.contains("-WoowTestRunner")`, and `AppDelegate.processTestLaunchArguments()` early-returns on it. **`-WoowTestRunner` appears in only three UI-test files** (`E2E_ThemeColorTests`, `E2E_ThemeAcrossAllViews`, `E2E_ThemeColorLoginWalkthrough`). **There is NO shared setUp helper that adds it** — `odooUITests/Helpers/OdooHelper.swift` and `TestAccountSeeder.swift` contain no `launchArguments` code. `E2E_LocationClockInTests` sets `WOOW_TEST_AUTOTAP` / `WOOW_SEED_ACCOUNT` without it, so **those hooks are silently inert today.** If your test depends on a hook, add `-WoowTestRunner` to `XCUIApplication.launchArguments` yourself.

**HARNESS GOTCHA 3 — the UI suite cannot run out of the box.** `odooUITests/TestConfig.plist` is **gitignored** (live tunnel URLs + credentials) and is **not present in a fresh checkout**. An operator must copy `odooUITests/TestConfig.plist.example` → `odooUITests/TestConfig.plist`; `SharedTestConfig` hard-fails without it. Because of `PBXFileSystemSynchronizedRootGroup` (B1) the copy is picked up automatically — no project edit.

**Test configuration — single source of truth.** All test config flows through `SharedTestConfig` (plist in bundle, overridden by env: `TEST_SERVER_URL`, `TEST_DB`, `TEST_ADMIN_USER/PASS`, `TEST_USER/PASS`, `TEST_SECOND_USER/PASS`, `TEST_SENDER_EMAIL/PASS`, `TEST_DEVICE_UDID`). **FORBIDDEN:** ad-hoc `ProcessInfo.processInfo.environment["…"]` reads in test helpers. **`.xctestplan` files must not hardcode tunnel URLs, simulator UDIDs, or machine paths** — only generic flags like `RUN_LOCATION_E2E=1`. A previous PR hardcoded `ODOO_TUNNEL`/`SIMCTL_UDID` into a test plan and it rotted within hours.

**Test-double convention (it has moved).**
- `odooTests/TestDoubles/TestDoubles.swift` holds only **three shared mocks**: `MockAccountRepository`, `MockSecureStorage`, `MockPushTokenRepository`, sectioned by `// MARK: -`.
- **Test-local fakes declared inline in the consuming test file are now the dominant pattern** and are correct: `FakeBiometricAuthenticator`, `FakeAccountRepository`, `FakeStatusProvider`, and the `URLProtocol` stubs `StubURLProtocol`, `LogoutURLProtocol`, `RecordingURLProtocol`. Several are `private final class`. Do **not** believe the old "one shared doubles file" rule — but also don't move an existing shared mock out.
- Doubles conform to the production protocol unmodified. No test-only methods on production protocols.

**Network testability.** `URLProtocol`-injected `URLSession` is the **only** accepted mechanism; `OdooAPIClient(session:)` is the seam. There is no `MockURLSession` anywhere and adding one is an architectural regression. For the self-heal path, `SessionAuthenticating` is an additional protocol seam so tests can script `AuthResult`s without touching DNS.

**Keychain / Core Data in tests.** Keychain tests hit the **real simulator keychain** — e.g. `AppLockViewModelTests` constructs a real `SettingsRepository()` and cleans state in **both** `setUp` and `tearDown`. Miss the teardown and later tests inherit App Lock / PIN / lockout state. Note `setPin("123456")` costs a real 600 000-iteration PBKDF2 (~0.1–0.5 s per call). Core Data tests use `PersistenceController(inMemory: true)`.

**Naming.** Two eras coexist. Legacy: `testAcceptWebRoot`. **Use the current form:** `test_<subject>_<condition>_<expectation>` — e.g. `test_appLockOn_noUsableMethod_failsClosed_notNone`, `test_200SessionExpired_thenSuccess_reAuthsOnce_andRetrySucceeds`, `test_boundLink_consumableOnlyByTargetAccount`. Classes are `<Component>Tests`. **`MissingTests.swift` crams 17 unrelated suites into 1400+ lines — do not extend it; create a focused file.**

**XCUITest process rules (from CLAUDE.md, still in force).**
- Never write an interaction against system UI you have not observed: insert a temporary element dump, run it, **read the output**, then write the interaction, then remove the dump.
- After a failure: dump at the failure point → read → identify the real label/identifier → rewrite. Do not retry the same approach; do not guess `boundBy:` indices.
- Notification center: try the four strategies in order (direct `NotificationShortLookView` → expand `NotificationGroupView` → dismiss Focus banner → swipe up), logging which succeeded with a `[NotifStrategy]` prefix. If all four fail, capture a screenshot **and** a full dump before failing.
- Screenshot-on-failure (`XCUIScreen.main.screenshot()` → `XCTAttachment` with `lifetime = .keepAlways`) is mandatory for any test touching system UI.
- Use `XCUIApplication.launch()`, never `xcrun simctl launch` from a test — the latter bypasses `launchArguments` and every hook goes inert.
- Skips are the convention for environment-dependent E2E: `XCTSkipUnless(… "RUN_LOCATION_E2E" == "1")`, `XCTSkip("… requires iOS 16.4+")`.

**Out-of-process observability uses hidden a11y elements, not logs.** `E2EWebViewProbe.shared.publish(id:value:)` maintains one near-transparent `UILabel` per identifier on the key window (`e2e-webview-url`, `e2e-tap-decision`, `e2e-account-tenants`, `e2e-fire-btn`) with a **non-zero frame** — XCUITest omits zero-size views from the tree. `TestNotificationTapInjector` installs an `e2e-fire-tap` button at `alpha 0.02`. Synthetic notification taps fire from `didCommit`, **not** `didFinish` — Odoo's OWL long-poll can delay `didFinish` indefinitely.

**Chaos testing is OFF-device.** `scripts/ios_chaos_hprime.py` replaced the on-device chaos XCUITest: XCUITest runs inside the phone while chaos injection needs Docker/kubectl on the Mac. Cases C-1/C-2/C-3 assert server-side against the Odoo log and `woow.fcm.device` rows.

**Two "tested but dead" APIs.** `DeepLinkManager.invalidateIfNotTarget(accountId:)` and `MainViewModel.consumePendingDeepLink()` have unit tests but **no production caller**. `MainPlaceholderView` is dead code referenced only by `#Preview`. Don't infer from their tests that the behavior is wired.

---

### Code Quality & Style Rules

**Documentation is the strongest convention in this repo.** Nearly every type, protocol, and non-trivial method carries a `///` comment explaining **why** — often citing the bug it fixes or the Android file it ports. Match it. High-water marks worth imitating: `SessionReauthenticator` (numbered guardrail list), `PinLockout` (clock-forward threat model), `OdooWebView` (why no `location.hash`), `TestHookGate` (why two independent gates), `AccountRepository` (honest-logout ordering), `SeededAccount` (`var … = nil` vs `let`).
- `// MARK: -` section headers in every file over ~80 lines.
- `"Ported from Android: <File>.kt"` is a standard header line — keep it when porting.
- Inline `//` comments explain non-obvious *why*, never *what*. No comments referencing the current task or issue ("added for #123") — that rots.

**Constants.** Named constants live near usage as `private static let` on the namespace enum, or file-scope `private let` (`DeepLinkManager`'s `deepLinkUrlKey` / `pendingDeepLinkTTL`). Shared ones are `static let` on the owning namespace: `NotificationDeepLinkRouter.actionUrlKey/tenantIdKey`, `SessionExpiry.exceptionName/expiredCode/messageHint`, `TestHookGate.launchArgumentMarker`, `AppSettings.defaultThemeColor`, `PinHasher.maxAttemptsPerTier/pinLength`. Magic numbers **are** accepted in view chrome (`.padding(32)`, `frame(maxWidth: 500)`, `size: 64`).

**Error handling.** Typed error enums (`OdooAPIError: Error, LocalizedError, Equatable`; `AuthResult.ErrorType: Sendable, Equatable` mapped to localized strings in `LoginViewModel.mapError`). The codebase catches **specific** cases (`catch OdooAPIError.sessionExpired`, `catch is URLError` before a generic fallback), not bare `catch { }`. Best-effort operations are explicit and logged, never silent. `try?` is used for Core Data fetch/save where nil is a legitimate answer; `let saved = (try? context.save()) != nil` gates the notification broadcast.

**Security posture already in code** (don't weaken): constant-time PIN compare; Keychain `WhenUnlockedThisDeviceOnly` + non-synchronizable; `DeepLinkValidator.isValid` rejects in order — empty, control characters, `..`/`%2e%2e` — then allows only `^/web(?:[/?#]|$)` relative paths or https same-host absolutes; **an empty `serverHost` rejects all absolute URLs, which is deliberate fail-closed behaviour, not a bug**; privacy overlay covers the task-switcher snapshot at `.inactive`.

**`ensureHTTPS` is not a validator.** It passes `ftp://`, `ssh://` etc. through unchanged. It exists for user-typed login-form input only. For any attacker-influenced URL use `DeepLinkValidator.isValid(url:serverHost:)`.

**Linting — there is none.** SwiftLint is **not installed, not configured, not invoked**. No `.swiftlint.yml`, no lint build phase, no CI. The one `// swiftlint:disable:this force_try` is decorative. **Do not assume a linter will catch style issues.**

**TODOs.** Effectively zero: exactly one bare `// TODO:` without an issue id in `odooUITests/odooUITests.swift`. The bar is zero; acceptable form if truly unavoidable is `// TODO(#123): …`.

**Accessibility — real, unpatched gaps (state them, don't claim they're fixed).**
- `accessibilityLabel`/`accessibilityHidden`/`accessibilityValue` appear in exactly **one** UI file, `SettingsView.swift` (4 occurrences).
- `PinView`'s PIN dots still have **no** `.accessibilityValue`.
- `AppSettings.reduceMotion` is persisted and surfaced in Settings but **no animation anywhere reads it**, and no view reads `\.accessibilityReduceMotion`. `PinView`, `BiometricView`, and `odooApp.swift` animate unconditionally.
- **Requirements for new UI:** decorative images `.accessibilityHidden(true)`; icon-only buttons `.accessibilityLabel`; shape-communicated state `.accessibilityValue`; prefer semantic fonts (`.body`, `.headline`) over numeric sizes except for hero icons/chrome.

**Removing code.** Removing a public method or protocol member updates every caller in the same change. No `@available(*, deprecated)` stubs, no compat shims, no `_`-prefixed dead variables. Delete unused code completely — including its tests.

---

### Development Workflow Rules

**Build / test commands (verified working):**
```bash
xcodebuild -project odoo.xcodeproj -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

xcodebuild -project odoo.xcodeproj -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:odooTests test
```
`-only-testing:odooTests` is required in practice — without it the default `LocationE2E.xctestplan` also drags in the two selected location E2E tests. Destination is hardcoded to `iPhone 16`.

**The one automated gate in the whole repo.** A `PBXShellScriptBuildPhase` named **"Audit debug-hook leaks (Release)"** on the `odoo` target runs `scripts/audit_release_archive.sh "$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"` and exits 0 immediately when `CONFIGURATION != Release`. It `strings`-greps the built binary for every entry in its own `KNOWN_HOOKS`. **That is the only enforcement that exists** — no CI, no git hooks, no lint, no pre-commit.

**Test-hook registry — a five-step change, and it is currently RED.**
1. **Name** `WOOW_TEST_<purpose>` or `WOOW_SEED_<purpose>`. No other prefix.
2. **Gate** every read behind `guard TestHookGate.testHooksEnabled else { … }`. Bare `#if DEBUG` is insufficient (App Store Guideline 2.3.1).
3. **Register** the exact key in `KNOWN_HOOKS` in **both** `scripts/audit_test_hook_naming.sh` **and** `scripts/audit_release_archive.sh`.
4. **Inertness test** in `odooTests/TestHookGateTest.swift` asserting a no-op when the gate is false.
5. **XCUITest** must add `-WoowTestRunner` to `launchArguments` — there is no helper that does it for you.

`scripts/audit_test_hook_naming.sh` is **manual-only** (nothing invokes it) and **fails on `main` right now, exit 1, three unregistered hooks**: `WOOW_SEED_ACCOUNTS` (`AppDelegate.swift`), `WOOW_TEST_NOTIFICATION_TAP` and `WOOW_TEST_NOTIFICATION_TAP_MODE` (`TestNotificationTapInjector.swift`). Both `KNOWN_HOOKS` arrays still list only the original five, so those three strings are **not** checked for by the Release build phase and can ship in a signed binary. Run the script before you commit anything in this area; fixing the existing three is in scope for anyone touching it.

**Other real scripts (not prose):** `scripts/{audit_test_hook_naming.sh, audit_theme_color_usage.sh, audit_release_archive.sh, verify_all.py, e2e-fcm-test.py, ios_chaos_hprime.py}`.

**Git conventions actually in use (last 40 commits).**
- Conventional prefixes with **feature-name scopes, not milestone scopes**: `feat(applock):`, `feat(ios):`, `fix(deeplink+multiaccount):`, `fix(applock):`, `chore(bmad):`.
- A second bracket-tag style is in active use from the E2E/chaos work: `[R-05-Phase-A]`, `[BUG-3]`, `[E8-S2]`, `[iOS-CHAOS]`, `[E2E]`.
- Work items referenced inline: `WI-1/2/3`, `AC7/AC8/AC9`, `S2/S3/S4`, `MA-1`, `T-I2`, `UX-42/43/68`. Those ids also appear in code comments — that is how code links back to its spec.
- Short-lived `feature/*` and `fix/*` branches merged to `main` via GitHub PR. `main` tracks `origin/main`.
- Never `--amend` after a hook failure (the commit didn't happen; amend destroys the previous one). Never `--no-verify`. Never force-push `main`.
- **Never commit:** `.env`, credentials, `*.p8`/`*.p12`/`*.cer`, `*.mobileprovision`, `xcuserdata/`, `odooUITests/TestConfig.plist`. **`GoogleService-Info.plist` IS checked in** — public Firebase config.
- `.gitignore` (current) covers `xcuserdata/`, `DerivedData/`, `build/`, `*.ipa`, `*.dSYM`, `Package.resolved`, `Pods/`, `.DS_Store`, `_bmad/config.user.yaml`, `_bmad-output/`, `odooUITests/TestConfig.plist`.

**Privacy manifest discipline.** `odoo/PrivacyInfo.xcprivacy` is the source of truth. Adding any new data collection — analytics, crash reporting, advertising ids, or a new Firebase module — requires, in order: (1) update the manifest, (2) update App Store Connect's App Privacy disclosure, (3) get product sign-off (an explicit approval on the PR — there is no other channel), (4) *then* link the module / write the code. Linking `FirebaseAnalytics` or `Crashlytics` "to improve observability" without those steps is a shipped App Store rejection.

**Documented workflow that the repo no longer follows — do NOT assume it is live.** CLAUDE.md describes a 10-step milestone pipeline (M1–M11 / IC01–IC20 / UX-01–UX-82 / iV01–iV58), mandatory `<date>-<Title>_Implementation_Plan.md` + `_Test_Plan.md` docs, and lock-step doc-sync. Measured against the code:
- `scripts/verify_all.py` contains only iV01–iV40 and was last touched 2026-03-27; `docs/ios-verification-log.md` likewise. **The iV pipeline is dormant.**
- Across the 37 commits since 2026-05-10, **zero** use `feat(M{n}):` or carry an IC id; the IC table still ends at IC20; **no plan doc has been added** since `docs/2026-05-02-app-store-readiness-fixing-plan.md`; only `docs/functional-equivalence-matrix.md` was updated once; **CLAUDE.md was last modified 2026-05-03** and describes none of the App Lock v3, FCM token-lifecycle, or multi-account deep-link work.
→ Follow the **live** conventions (feature-scoped commits, work-item ids, PR-merged short-lived branches). If the user asks for the milestone pipeline, follow it — but do not silently invent an `M12`/`IC21`/`iV41` or claim a milestone gate passed when `verify_all.py` was not run. Say which convention you used.

---

### Critical Don't-Miss Rules

Ordered by blast radius. An agent who reads only this section avoids the most damaging mistakes.

**C1. Do not hand-edit `project.pbxproj` to add or exclude a file.** `PBXFileSystemSynchronizedRootGroup`; membership is by directory. Exclude from Release with a whole-file `#if DEBUG`. Only `odoo/Info.plist` is an explicit membership entry. *(Build-breaking.)*

**C2. `@Test` / `#expect` do not compile here.** XCTest only, Swift 5.0, no swift-testing dependency. *(Build-breaking.)*

**C3. `#if DEBUG` alone is NOT the gate — `TestHookGate.testHooksEnabled` is.** It requires `#if DEBUG` **AND** the `-WoowTestRunner` launch argument. Every new `WOOW_TEST_*`/`WOOW_SEED_*` read goes behind it, and the key must be added to `KNOWN_HOOKS` in **both** audit scripts plus an inertness test. Inverse trap live today: only 3 UI-test files pass `-WoowTestRunner`, so hooks in the others are inert. *(App Store 2.3.1.)*

**C4. There is no `.xcdatamodeld`.** The model is built in `PersistenceController.buildManagedObjectModel()`. A new attribute = four coordinated edits, and it must be `isOptional = true` or lightweight migration fails on existing installs.

**C5. Keychain writes are `SecItemUpdate`-then-`SecItemAdd`, not delete-then-add.** Do not "fix" it back. Note accessibility attributes are applied on the add path only.

**C6. Never route a deep link through `location.hash`.** Odoo 18's `/odoo/...` path router ignores `hashchange`. `deepLinkApplyPlan` has one case, `.load(URL)`. A hash poke leaves every notification tap on the Discuss Inbox.

**C7. A push with an unresolved `odoo_tenant_id` MUST be dropped, never applied to the active account.** `NotificationDeepLinkRouter.decide` → `.drop(.unresolvedTenant)`. Adding a "fall back to active" branch is a cross-tenant data-exposure regression. Same invariant in `getAccount(byTenantId:)` — an empty id never matches.

**C8. Cookie stores are N+1, not 2.** `HTTPCookieStorage.shared` plus one `WKWebsiteDataStore(forIdentifier:)` per account on iOS 17+. Writing into `.default()` does nothing for a real account. And `CacheService.clearWebViewCache()` **intentionally excludes cookies** (to preserve login), clears only `.default()`, and is never called by logout.

**C9. The session cookie must commit before the first load** — the load lives inside `setCookie`'s completion handler. Fire-and-forget lands on the public Odoo page.

**C10. Session expiry arrives as HTTP 200** with a `SessionExpiredException` envelope. Detection must inspect the body. A status-code-only check never fires.

**C11. Auth must fail CLOSED.** `resolveAuthAction` returns `.none` only when App Lock is off; App Lock on with no usable method → `.setupRequired`. Revoked Face ID or an OS biometry lockout must never drop the user into the app. And do not "tidy" `promptedThisLock` / `lockGeneration` / the internal `apply*Outcome` methods, or turn `setAuthenticated(false)` into a plain assignment.

**C12. `recomputeUIState()` does synchronous Keychain I/O on the main actor.** `requiresAuth`, `pinEnabled`, and `authAction` each call into `SettingsRepository` → `SecureStorage.getSettings()` → `SecItemCopyMatching`, and `recomputeUIState` is called from `init` and ~8 sites. Adding recompute calls in a loop, or making settings async, is a main-thread hazard.

**C13. `PinView` is not render-only.** It holds `@ObservedObject var authViewModel: AuthViewModel` plus five `@State` values including a live `Timer`. `BiometricView` and `AuthSetupRequiredView` *are* pure value-param views. Don't refactor `PinView` as though it were one.

**C14. `ensureHTTPS` is not a security check.** For attacker-influenced URLs use `DeepLinkValidator`. Passing `serverHost: ""` rejects all absolute URLs — deliberate fail-closed, not a bug.

**C15. `logout` deletes the account row** (plus Keychain password and session id), then promotes the most-recent remaining account and posts `.activeAccountDidChange`. "Clear the cookie only" resurrects the demo444 bug. Keep `serverUrl.ensureHTTPS` in `unregisterFcmToken`.

**C16. `SessionReauthenticator`'s five guardrails are load-bearing**, not defensive coding: https-only exact-host resolution, cap of exactly one retry (structural), bad-credential STOP + open circuit + `ReloginSignal`, per-host single-flight `Task` map, never log credentials.

**C17. Three localization files, 107 keys each, must stay in lockstep** — with real zh-Hans and zh-Hant translations. No `.xcstrings` catalog exists despite `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`. Nothing enforces this.

**C18. The UI suite needs `odooUITests/TestConfig.plist`** copied from `TestConfig.plist.example` before it can run; the default test plan (`LocationE2E.xctestplan`) hides the XCUITest suite — always pass `-only-testing:` explicitly.

**C19. `scripts/audit_test_hook_naming.sh` fails on `main` today** (3 unregistered hooks) and nothing invokes it automatically. Run it manually before committing in that area.

**C20. No SwiftLint, no CI, no git hooks, and the milestone/iV pipeline is dormant.** Everything — plan docs, directory boundaries, localization completeness, test coverage, hook registration — is human-enforced. Do not claim a gate passed unless you actually ran the command and can quote its output.

**C21. Vacuous tests are the highest-impact anti-pattern here.** If you can delete the assertions and the test still passes, it has no value. Smoke test: imagine the implementation deletes itself — does this test fail? If not, rewrite it. Same bar for flaky XCUITests: treat a flake as P0, fix or explicitly quarantine it; never retry until green.

**C22. Class-of-bug fixes must be exhaustive.** The 2026-05-02 audit found two un-gated hooks *after* the 2026-04-28 work had already gated four siblings. Before declaring a class fixed, grep every instance of the pattern and verify each. Applies equally to theme, dark mode, locale, accessibility, and security findings.

**C23. This file drifts too.** It was accurate on 2026-08-01 against commit `b833e47`+. Verify any claim you are about to depend on. When you find drift, fix it here in the same change as the code.

---

## Usage Guidelines

**For AI agents:**
- Read Build-System Rules (B1–B3) and Critical Don't-Miss Rules before writing a line — they are the difference between code that compiles and code that doesn't.
- Where a rule cites a file, verify by symbol name, not line number. Line numbers in this repo drift.
- CLAUDE.md is authoritative for *process the user wants*, but stale on *what the repo currently is* (last modified 2026-05-03). Where they conflict on facts, this file follows the code; say which you followed.
- Prefer the more restrictive option on anything touching App Store compliance, cross-tenant isolation, or auth.
- Report honestly: if you didn't run `verify_all.py` or the hook audit, don't imply you did.

**For humans:**
- Keep this lean — non-obvious behavior only, not what's readable from the code.
- Re-verify after any Xcode upgrade, deployment-target bump, or test-framework change (B1–B3 are the fragile ones).
- Retire an entry once its underlying gap is closed — especially C19 (hook registry red) and the dormant-pipeline note.

**Last updated:** 2026-08-01 · verified against `worktrees/ios` @ `70c458d`
