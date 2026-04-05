# App Store Blockers — Verification Test Plan

**Date:** 2026-04-05
**Scope:** B1–B5 blockers identified in `2026-04-05-Remaining-Work-Audit_Implementation_Plan.md`
**Test framework:** XCTest (unit), XCUITest (UI)
**Naming convention:** `test_{method}_given{Condition}_{returns|shows|navigates}{Expected}` per CLAUDE.md
**Rules applied from CLAUDE.md:**
- No `sleep()` — use `waitForExistence(timeout:)` only
- `XCTFail` required in every `guard` failure branch
- Screenshot attachment required in every system-UI failure path
- `continueAfterFailure = false` in all UI test `setUp`

---

## Context: What is broken and why it matters

| Blocker | Root cause (source-verified) | App Store consequence |
|---------|-----------------------------|-----------------------|
| B1 | `odoo/PrivacyInfo.xcprivacy` does not exist anywhere in the project | Binary rejected at App Store Connect upload |
| B2 | `AppIcon.appiconset/Contents.json` declares 3 slots; zero PNG files are present and no `"filename"` key exists in any entry | Blank icon in TestFlight; App Store requires 1024x1024 |
| B3 | `Info.plist` contains only `UIBackgroundModes` and `CFBundleURLTypes`; `NSFaceIDUsageDescription` and `CFBundleLocalizations` are absent | Crash on first Face ID prompt; per-app language switching silently broken |
| B4 | `odooApp.swift` line 77–79: `onMenuClick` closure body is a comment only; `ConfigView` and `SettingsView` are fully implemented but have no navigation path to reach them | Users cannot access settings, account switching, or logout |
| B5 | All 3 `Localizable.strings` files exist with 67 keys; zero Swift source files reference `String(localized:)`, `NSLocalizedString`, or `LocalizedStringKey` | App always shows English; UX-58 through UX-62 false-DONE |

---

## B1: PrivacyInfo.xcprivacy

### Why these tests exist

Apple's required reasons API mandate (enforced from spring 2024) causes App Store Connect to reject the binary if the app uses UserDefaults, Keychain, or file-timestamp APIs without a privacy manifest. The file must be present in the app bundle at submission time.

### Test suite: `PrivacyManifestTests` (unit)

**File location:** `odooTests/PrivacyManifestTests.swift`
**Target:** `odooTests`
**Import:** `@testable import odoo`, `Foundation`

---

#### B1-U1

```
test_privacyManifest_givenAppBundle_fileExists
```

**Type:** Unit — bundle resource check
**Given:** The app is built and `PrivacyInfo.xcprivacy` has been added to the Xcode target's Copy Bundle Resources phase.
**When:** The test asks `Bundle.main` for the URL of `PrivacyInfo` with extension `xcprivacy`.
**Expected result:** The URL is non-nil.
**Expected failure mode before fix:** Returns `nil` because the file does not exist in the bundle. Test fails with "PrivacyInfo.xcprivacy not found in bundle".

**Implementation:**

```swift
func test_privacyManifest_givenAppBundle_fileExists() {
    let url = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    XCTAssertNotNil(url, "PrivacyInfo.xcprivacy must exist in the app bundle — Apple rejects binaries without it")
}
```

---

#### B1-U2

```
test_privacyManifest_givenFile_containsNSPrivacyAccessedAPITypes
```

**Type:** Unit — manifest content validation
**Given:** `PrivacyInfo.xcprivacy` exists in the bundle.
**When:** The test reads and parses it as a property list.
**Expected result:** The parsed dictionary contains the key `NSPrivacyAccessedAPITypes` as an array, and the array contains at least one entry with key `NSPrivacyAccessedAPIType` equal to `NSPrivacyAccessedAPICategoryUserDefaults` (required because the app uses `UserDefaults` via `SettingsRepository`).
**Expected failure mode before fix:** File does not exist; guard falls through to `XCTFail`.

**Implementation:**

```swift
func test_privacyManifest_givenFile_containsNSPrivacyAccessedAPITypes() {
    guard let url = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") else {
        XCTFail("PrivacyInfo.xcprivacy not found in bundle — cannot validate contents")
        return
    }
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dict = plist as? [String: Any] else {
        XCTFail("PrivacyInfo.xcprivacy is not a valid property list")
        return
    }
    guard let apiTypes = dict["NSPrivacyAccessedAPITypes"] as? [[String: Any]] else {
        XCTFail("NSPrivacyAccessedAPITypes key missing from PrivacyInfo.xcprivacy")
        return
    }
    let typeValues = apiTypes.compactMap { $0["NSPrivacyAccessedAPIType"] as? String }
    XCTAssertTrue(
        typeValues.contains("NSPrivacyAccessedAPICategoryUserDefaults"),
        "Manifest must declare UserDefaults API usage (C617.1) — app reads/writes UserDefaults via SettingsRepository"
    )
}
```

---

#### B1-U3

```
test_privacyManifest_givenFile_declaresSomeRequiredReasons
```

**Type:** Unit — manifest content validation
**Given:** `PrivacyInfo.xcprivacy` exists and is valid.
**When:** The test checks the first API type entry for a non-empty `NSPrivacyAccessedAPITypeReasons` array.
**Expected result:** At least one API type entry has a non-empty reasons array, proving the manifest is not a skeleton file.
**Expected failure mode before fix:** File absent; guard triggers `XCTFail`.

**Implementation:**

```swift
func test_privacyManifest_givenFile_declaresSomeRequiredReasons() {
    guard let url = Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
          let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dict = plist as? [String: Any],
          let apiTypes = dict["NSPrivacyAccessedAPITypes"] as? [[String: Any]] else {
        XCTFail("PrivacyInfo.xcprivacy missing or invalid — cannot validate reasons")
        return
    }
    let anyEntryHasReasons = apiTypes.contains { entry in
        guard let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return false }
        return !reasons.isEmpty
    }
    XCTAssertTrue(anyEntryHasReasons,
                  "At least one API type in PrivacyInfo.xcprivacy must list required reason codes")
}
```

---

### Build-level verification (not a coded test)

After creating `PrivacyInfo.xcprivacy`, verify:
- `xcodebuild archive` succeeds with no warning: `"The app's Info.plist file doesn't include a NSPrivacyAccessedAPITypes key"`
- `xcrun altool --validate-app` (or App Store Connect upload) does not produce a `ITMS-91053` rejection.

These are checked manually in Step 5 (Simulator Verification) of the milestone pipeline.

---

## B2: App Icon

### Why these tests exist

The `AppIcon.appiconset/Contents.json` manifest declares three image slots (universal light, dark, tinted) but contains zero PNG files and no `"filename"` keys. Xcode will produce a warning and TestFlight will display a blank grid icon. A 1024x1024 PNG is required for App Store submission.

### Test suite: `AppIconTests` (unit)

**File location:** `odooTests/AppIconTests.swift`
**Target:** `odooTests`

---

#### B2-U1

```
test_appIcon_givenBundle_primaryIconNameIsDefined
```

**Type:** Unit — bundle icon metadata check
**Given:** The app has been built with at least one PNG added to `AppIcon.appiconset` and the `"filename"` key present in `Contents.json`.
**When:** The test reads `CFBundleIcons` > `CFBundlePrimaryIcon` > `CFBundleIconName` from `Bundle.main.infoDictionary`.
**Expected result:** The value is a non-empty string (Xcode sets it automatically when icon assets are present).
**Expected failure mode before fix:** `CFBundleIconName` is nil or absent because Xcode cannot resolve the asset when no PNG files exist.

**Implementation:**

```swift
func test_appIcon_givenBundle_primaryIconNameIsDefined() {
    let info = Bundle.main.infoDictionary
    let primaryIcons = info?["CFBundleIcons"] as? [String: Any]
    let primaryIcon = primaryIcons?["CFBundlePrimaryIcon"] as? [String: Any]
    let iconName = primaryIcon?["CFBundleIconName"] as? String
    XCTAssertNotNil(iconName, "CFBundleIconName must be set — app icon PNGs are missing from AppIcon.appiconset")
    XCTAssertFalse(iconName?.isEmpty ?? true, "CFBundleIconName must not be empty")
}
```

---

#### B2-U2

```
test_appIcon_givenBundle_iconIsLoadable
```

**Type:** Unit — runtime image load check
**Given:** At least one PNG is present in the asset catalog.
**When:** The test attempts `UIImage(named: "AppIcon")`.
**Expected result:** Returns a non-nil `UIImage`.
**Expected failure mode before fix:** Returns nil because no PNG exists in the asset catalog.

**Implementation:**

```swift
func test_appIcon_givenBundle_iconIsLoadable() {
    // UIImage(named:) resolves from the asset catalog at runtime
    let icon = UIImage(named: "AppIcon")
    XCTAssertNotNil(icon, "AppIcon must be loadable — add 1024x1024 PNG to AppIcon.appiconset")
}
```

---

### Build-level verification (not a coded test)

After adding PNG files:
- `xcodebuild build` produces zero warnings containing `"Could not get traitCollection"` or `"No image found"` for the app icon.
- Archive export does not produce `ITMS-90717` (invalid app icon).

---

## B3: Info.plist Required Keys

### Why these tests exist

Current `Info.plist` contains only `UIBackgroundModes` and `CFBundleURLTypes`. Missing keys cause:
- `NSFaceIDUsageDescription` absent: app crashes with `NSInternalInconsistencyException` when `LAContext.evaluatePolicy` is called on any device with Face ID.
- `CFBundleLocalizations` absent: iOS ignores the per-app language setting in Settings > Apps; the language picker appears but switching has no effect.

### Test suite: `InfoPlistTests` (unit)

**File location:** `odooTests/InfoPlistTests.swift`
**Target:** `odooTests`

---

#### B3-U1

```
test_infoPlist_givenBundle_NSFaceIDUsageDescriptionExists
```

**Type:** Unit — Info.plist key presence
**Given:** `NSFaceIDUsageDescription` has been added to `Info.plist`.
**When:** The test reads `Bundle.main.infoDictionary["NSFaceIDUsageDescription"]`.
**Expected result:** The value is a non-empty string.
**Expected failure mode before fix:** Returns nil. Test fails with "NSFaceIDUsageDescription missing — app will crash on Face ID prompt".

**Implementation:**

```swift
func test_infoPlist_givenBundle_NSFaceIDUsageDescriptionExists() {
    let description = Bundle.main.infoDictionary?["NSFaceIDUsageDescription"] as? String
    XCTAssertNotNil(description,
                    "NSFaceIDUsageDescription missing from Info.plist — app crashes on Face ID without it")
    XCTAssertFalse(description?.isEmpty ?? true,
                   "NSFaceIDUsageDescription must not be empty — Apple requires a user-facing explanation")
}
```

---

#### B3-U2

```
test_infoPlist_givenBundle_CFBundleLocalizationsContainsRequiredLocales
```

**Type:** Unit — Info.plist localization array
**Given:** `CFBundleLocalizations` has been added to `Info.plist` with values `["en", "zh-Hans", "zh-Hant"]`.
**When:** The test reads and checks the array.
**Expected result:** All three locale codes are present.
**Expected failure mode before fix:** `CFBundleLocalizations` key is absent; guard triggers `XCTFail`.

**Implementation:**

```swift
func test_infoPlist_givenBundle_CFBundleLocalizationsContainsRequiredLocales() {
    guard let localizations = Bundle.main.infoDictionary?["CFBundleLocalizations"] as? [String] else {
        XCTFail("CFBundleLocalizations missing from Info.plist — per-app language switching will not work on iOS 16+")
        return
    }
    let required = ["en", "zh-Hans", "zh-Hant"]
    for locale in required {
        XCTAssertTrue(
            localizations.contains(locale),
            "CFBundleLocalizations must include '\(locale)' — found: \(localizations)"
        )
    }
}
```

---

#### B3-U3

```
test_infoPlist_givenBundle_NSFaceIDUsageDescriptionIsUserFacing
```

**Type:** Unit — content quality gate
**Given:** `NSFaceIDUsageDescription` is present.
**When:** The test checks the string has at least 10 characters and does not equal a placeholder value.
**Expected result:** String is a meaningful sentence, not "TODO" or empty.
**Expected failure mode before fix:** Key absent; guard triggers `XCTFail`.
**Note:** This catches copy-paste placeholders during implementation.

**Implementation:**

```swift
func test_infoPlist_givenBundle_NSFaceIDUsageDescriptionIsUserFacing() {
    guard let description = Bundle.main.infoDictionary?["NSFaceIDUsageDescription"] as? String else {
        XCTFail("NSFaceIDUsageDescription missing from Info.plist")
        return
    }
    XCTAssertGreaterThan(description.count, 10,
                         "NSFaceIDUsageDescription is too short to be meaningful")
    XCTAssertFalse(description.lowercased().contains("todo"),
                   "NSFaceIDUsageDescription must not be a placeholder")
}
```

---

## B4: Config Screen Navigation (MOST IMPORTANT)

### Why these tests exist

`ConfigView`, `SettingsView`, and the account list are fully implemented in source but have zero navigation paths to reach them. The `onMenuClick` closure in `odooApp.swift` line 77–79 is an empty comment. Every UX item from UX-47 through UX-70 is therefore unreachable. These XCUITests will fail until `onMenuClick` is wired to present `ConfigView` (via sheet, `NavigationStack` push, or full-screen cover).

### Pre-conditions for all B4 tests

The menu button (`line.3.horizontal` system image) is visible only after login. These tests require the app to start at the main screen. There are two strategies depending on implementation state:

1. **If auto-login credentials are seeded via `launchArguments`:** Use `app.launchArguments = ["-UITest_UseAutoLogin"]` and have `AppRootViewModel` read it to skip to `.authenticated` state.
2. **If no auto-login injection is available yet:** Each test calls `app.loginWithTestCredentials()` (the existing helper in `odooUITests.swift`) before the assertion.

The tests below use strategy 2 because auto-login injection is not yet confirmed implemented. Replace with strategy 1 once available.

### Test suite: `B4_ConfigNavigationTests` (XCUITest)

**File location:** `odooUITests/B4_ConfigNavigationTests.swift`
**Target:** `odooUITests`

---

#### B4-UI1

```
test_menuButton_givenMainScreen_configViewAppears
```

**Type:** XCUITest — navigation trigger
**Given:** The user is on the main screen (WebView visible, menu button in navigation bar).
**When:** The user taps the `line.3.horizontal` menu button.
**Expected result:** `ConfigView` appears. The screen title "Configuration" is visible within 5 seconds.
**Expected failure mode before fix:** Nothing happens because `onMenuClick` is empty. `waitForExistence` times out. Test fails with screenshot attached.

**Implementation:**

```swift
final class B4_ConfigNavigationTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app.launch()
        // Reach main screen using the existing test helper
        app.loginWithTestCredentials()
    }

    @MainActor
    func test_menuButton_givenMainScreen_configViewAppears() {
        let menuButton = app.buttons["line.3.horizontal"]
        guard menuButton.waitForExistence(timeout: 10) else {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Menu button not found — user may not have reached main screen")
            return
        }
        menuButton.tap()
        guard app.staticTexts["Configuration"].waitForExistence(timeout: 5) else {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("ConfigView did not appear after tapping menu — onMenuClick closure is empty (odooApp.swift line 77)")
            return
        }
        XCTAssertTrue(app.staticTexts["Configuration"].exists)
    }
}
```

---

#### B4-UI2

```
test_configView_givenOpened_showsAccountSection
```

**Type:** XCUITest — config view content
**Given:** The user has tapped the menu button and `ConfigView` is visible.
**When:** The test inspects the list content.
**Expected result:** The active account section is visible. Since `ConfigViewModel.loadAccounts()` is called on `onAppear`, the logged-in account's `displayName` initial letter or the account's `username` is visible in the list within 5 seconds.
**Expected failure mode before fix:** `ConfigView` never appears; guard triggers `XCTFail` with screenshot.

**Implementation:**

```swift
@MainActor
func test_configView_givenOpened_showsAccountSection() {
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 10) else {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Menu button not found")
        return
    }
    menuButton.tap()
    guard app.staticTexts["Configuration"].waitForExistence(timeout: 5) else {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("ConfigView did not appear")
        return
    }
    // The active account row uses the first letter of displayName as an avatar.
    // The admin account used in TestConfig has displayName "Administrator" or "admin".
    // We check that at least one cell containing the test username is visible.
    let accountCell = app.staticTexts[TestConfig.adminUser]
    XCTAssertTrue(
        accountCell.waitForExistence(timeout: 5),
        "Active account username '\(TestConfig.adminUser)' should appear in ConfigView account section"
    )
}
```

---

#### B4-UI3

```
test_configView_givenOpened_hasSettingsButton
```

**Type:** XCUITest — config view Settings button presence
**Given:** `ConfigView` is open.
**When:** The test checks for the "Settings" button label in the list.
**Expected result:** A button or label with text "Settings" is visible.
**Expected failure mode before fix:** `ConfigView` never appears; guard fires with screenshot.

**Implementation:**

```swift
@MainActor
func test_configView_givenOpened_hasSettingsButton() {
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 10) else {
        attachScreenshot(); XCTFail("Menu button not found"); return
    }
    menuButton.tap()
    guard app.staticTexts["Configuration"].waitForExistence(timeout: 5) else {
        attachScreenshot(); XCTFail("ConfigView did not appear"); return
    }
    XCTAssertTrue(
        app.buttons["Settings"].waitForExistence(timeout: 3),
        "ConfigView must contain a 'Settings' button (wired to onSettingsClick)"
    )
}
```

*(Note: `attachScreenshot()` is a private helper defined once in the test class — see full class listing at end of B4 section.)*

---

#### B4-UI4

```
test_configView_givenOpened_hasAddAccountButton
```

**Type:** XCUITest — config view Add Account button presence
**Given:** `ConfigView` is open.
**When:** The test looks for "Add Account".
**Expected result:** The button is visible (it is always shown regardless of account count — `ConfigView` line 57–61).
**Expected failure mode before fix:** `ConfigView` unreachable.

**Implementation:**

```swift
@MainActor
func test_configView_givenOpened_hasAddAccountButton() {
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 10) else {
        attachScreenshot(); XCTFail("Menu button not found"); return
    }
    menuButton.tap()
    guard app.staticTexts["Configuration"].waitForExistence(timeout: 5) else {
        attachScreenshot(); XCTFail("ConfigView did not appear"); return
    }
    XCTAssertTrue(
        app.buttons["Add Account"].waitForExistence(timeout: 3),
        "ConfigView must contain an 'Add Account' button (UX-70)"
    )
}
```

---

#### B4-UI5

```
test_configView_givenOpened_hasLogoutButton
```

**Type:** XCUITest — config view Logout button presence
**Given:** `ConfigView` is open.
**When:** The test looks for a "Logout" button.
**Expected result:** A destructive "Logout" button is visible (`ConfigView` line 65–68).
**Expected failure mode before fix:** `ConfigView` unreachable.

**Implementation:**

```swift
@MainActor
func test_configView_givenOpened_hasLogoutButton() {
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 10) else {
        attachScreenshot(); XCTFail("Menu button not found"); return
    }
    menuButton.tap()
    guard app.staticTexts["Configuration"].waitForExistence(timeout: 5) else {
        attachScreenshot(); XCTFail("ConfigView did not appear"); return
    }
    XCTAssertTrue(
        app.buttons["Logout"].waitForExistence(timeout: 3),
        "ConfigView must contain a 'Logout' button (UX-67)"
    )
}
```

---

#### B4-UI6

```
test_fullFlow_givenMainScreen_menuThenConfigThenSettings_languageSectionVisible
```

**Type:** XCUITest — end-to-end navigation flow
**Given:** The user is on the main screen.
**When:** The user taps menu -> ConfigView appears -> taps "Settings" -> SettingsView appears.
**Expected result:** The "Language" section header or row is visible in SettingsView. This validates the full three-level navigation chain and confirms both B4 (navigation wired) and B5 partial fix (localization section present).
**Expected failure mode before fix:** Fails at the menu tap step because `onMenuClick` is empty.

**Implementation:**

```swift
@MainActor
func test_fullFlow_givenMainScreen_menuThenConfigThenSettings_languageSectionVisible() {
    // Step 1: Tap menu
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 10) else {
        attachScreenshot(); XCTFail("Menu button not found on main screen"); return
    }
    menuButton.tap()

    // Step 2: ConfigView must appear
    guard app.staticTexts["Configuration"].waitForExistence(timeout: 5) else {
        attachScreenshot(); XCTFail("ConfigView did not appear after menu tap"); return
    }

    // Step 3: Tap Settings
    guard app.buttons["Settings"].waitForExistence(timeout: 3) else {
        attachScreenshot(); XCTFail("Settings button not visible in ConfigView"); return
    }
    app.buttons["Settings"].tap()

    // Step 4: SettingsView must appear — look for the Appearance section header
    guard app.staticTexts["Appearance"].waitForExistence(timeout: 5) else {
        attachScreenshot(); XCTFail("SettingsView did not appear after tapping Settings"); return
    }

    // Step 5: Language section must be present (validates B5 implementation hook)
    XCTAssertTrue(
        app.staticTexts["Language"].waitForExistence(timeout: 3),
        "SettingsView must contain a 'Language' section (UX-58)"
    )
}
```

---

#### Full B4 class with shared helper

The screenshot helper is defined once inside `B4_ConfigNavigationTests`:

```swift
// Private helper — DRY screenshot attachment
private func attachScreenshot() {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "failure-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
}
```

Place this `private func attachScreenshot()` inside `B4_ConfigNavigationTests` and call it before every `XCTFail` in the class, as shown above.

---

## B5: Localization

### Why these tests exist

Three `Localizable.strings` files exist and are complete (67 keys each, with real Simplified and Traditional Chinese translations). However, zero Swift source files use `String(localized:)`, `NSLocalizedString`, or `LocalizedStringKey`. Every label is a hardcoded English string literal. The unit tests verify that the strings files are structurally complete now; the XCUITest verifies runtime locale behavior after the fix is applied.

### Test suite A: `LocalizationTests` (unit)

**File location:** `odooTests/LocalizationTests.swift`
**Target:** `odooTests`

The unit tests use `Bundle.main.localizedString(forKey:value:table:)` to read from each bundle rather than relying on the system locale. This is locale-independent and works in any test environment.

---

#### B5-U1

```
test_localization_givenEnglishBundle_settingsKeyExists
```

**Type:** Unit — string key presence in en.lproj
**Given:** The app bundle contains `en.lproj/Localizable.strings`.
**When:** The test requests the value for key `"settings"` from the English table.
**Expected result:** Returns `"Settings"` (exact value from file line 14).
**Note:** If the key is missing, `localizedString(forKey:value:table:)` returns the key itself — the test detects this by checking the result does not equal the key.

**Implementation:**

```swift
final class LocalizationTests: XCTestCase {

    // Verify a representative set of keys across all three locales.
    // These keys cover Login, Settings, Config, and Auth sections.
    private let requiredKeys: [String] = [
        "login_title", "server_url", "database_name", "username", "password",
        "login_button", "next_button", "app_name",
        "settings", "appearance", "security", "data_storage", "about",
        "biometric_title", "use_pin", "enter_pin",
        "configuration", "add_account", "logout",
        "Language"
    ]

    func test_localization_givenEnglishBundle_settingsKeyExists() {
        let value = Bundle.main.localizedString(forKey: "settings", value: nil, table: "Localizable")
        XCTAssertEqual(value, "Settings",
                       "'settings' key in en.lproj must equal 'Settings' — currently all strings are hardcoded English literals")
    }
}
```

---

#### B5-U2

```
test_localization_givenAllLocales_requiredKeysArePresent
```

**Type:** Unit — key coverage across all three locale bundles
**Given:** All three `Localizable.strings` files are in the bundle.
**When:** The test iterates over each locale bundle path and checks every required key.
**Expected result:** For each locale and each key, the bundle returns a value that is different from the key itself (proving the translation exists rather than falling back to the key).
**Expected failure mode before fix:** Passes for this unit test (files exist), but the XCUITest (B5-UI1) fails because the runtime views do not call `localizedString`.

**Implementation:**

```swift
func test_localization_givenAllLocales_requiredKeysArePresent() {
    let locales = ["en", "zh-Hans", "zh-Hant"]
    for locale in locales {
        guard let localePath = Bundle.main.path(forResource: locale, ofType: "lproj"),
              let localeBundle = Bundle(path: localePath) else {
            XCTFail("Locale bundle not found in app bundle: \(locale)")
            continue
        }
        for key in requiredKeys {
            let value = localeBundle.localizedString(forKey: key, value: nil, table: "Localizable")
            XCTAssertNotEqual(
                value, key,
                "Key '\(key)' missing or untranslated in \(locale).lproj/Localizable.strings"
            )
        }
    }
}
```

---

#### B5-U3

```
test_localization_givenZhHans_settingsKeyIsChineseSimplified
```

**Type:** Unit — translation correctness spot-check
**Given:** `zh-Hans.lproj/Localizable.strings` is in the bundle.
**When:** The test reads the `"settings"` key from the zh-Hans bundle.
**Expected result:** Returns `"设置"` (from file line 14).
**Rationale:** Confirms the zh-Hans translations are not English copies. The audit found all 3 files have real translations but this test documents the contract.

**Implementation:**

```swift
func test_localization_givenZhHans_settingsKeyIsChineseSimplified() {
    guard let localePath = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
          let localeBundle = Bundle(path: localePath) else {
        XCTFail("zh-Hans.lproj not found in bundle")
        return
    }
    let value = localeBundle.localizedString(forKey: "settings", value: nil, table: "Localizable")
    XCTAssertEqual(value, "设置",
                   "'settings' key in zh-Hans.lproj must be '设置', not an English copy")
}
```

---

#### B5-U4

```
test_localization_givenZhHant_settingsKeyIsChineseTraditional
```

**Type:** Unit — translation correctness spot-check
**Given:** `zh-Hant.lproj/Localizable.strings` is in the bundle.
**When:** The test reads the `"settings"` key from the zh-Hant bundle.
**Expected result:** Returns `"設定"` (from file line 14 of zh-Hant).

**Implementation:**

```swift
func test_localization_givenZhHant_settingsKeyIsChineseTraditional() {
    guard let localePath = Bundle.main.path(forResource: "zh-Hant", ofType: "lproj"),
          let localeBundle = Bundle(path: localePath) else {
        XCTFail("zh-Hant.lproj not found in bundle")
        return
    }
    let value = localeBundle.localizedString(forKey: "settings", value: nil, table: "Localizable")
    XCTAssertEqual(value, "設定",
                   "'settings' key in zh-Hant.lproj must be '設定', not an English copy")
}
```

---

#### B5-U5

```
test_localization_givenAllLocales_keyCountIsConsistent
```

**Type:** Unit — cross-locale key count parity
**Given:** All three locale files are present.
**When:** The test counts the keys in each bundle by testing all 21 `requiredKeys`.
**Expected result:** All 21 keys resolve (return non-key values) in all three locales. This catches regressions where a new key is added to `en.lproj` but not to the Chinese files.
**Note:** This test is intentionally narrow (21 sampled keys, not all 67) to stay fast. The `test_localization_givenAllLocales_requiredKeysArePresent` test already covers these 21. This test adds a count assertion to make gaps more visible.

**Implementation:**

```swift
func test_localization_givenAllLocales_keyCountIsConsistent() {
    let locales = ["en", "zh-Hans", "zh-Hant"]
    var resolvedCountPerLocale: [String: Int] = [:]
    for locale in locales {
        guard let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            XCTFail("Locale bundle not found: \(locale)")
            continue
        }
        let resolvedCount = requiredKeys.filter { key in
            let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            return value != key
        }.count
        resolvedCountPerLocale[locale] = resolvedCount
    }
    let enCount = resolvedCountPerLocale["en"] ?? 0
    for locale in ["zh-Hans", "zh-Hant"] {
        let count = resolvedCountPerLocale[locale] ?? 0
        XCTAssertEqual(
            count, enCount,
            "\(locale) resolves \(count) keys but en resolves \(enCount) — missing translations in \(locale)"
        )
    }
}
```

---

### Test suite B: `B5_LocalizationUITests` (XCUITest)

**File location:** `odooUITests/B5_LocalizationUITests.swift`
**Target:** `odooUITests`

**Important constraint:** XCUITest cannot change the system locale at runtime in a reliable way without a test plan (`.xctestplan`) that specifies the `AppleLocale` and `AppleLanguages` arguments. The test below uses `launchArguments` to set the locale, which works on Simulator but requires the app to call `String(localized:)` or `NSLocalizedString` for it to have any effect. This test is therefore expected to **fail until B5 implementation is complete** (strings replaced with localized calls).

---

#### B5-UI1

```
test_loginScreen_givenZhHansLocale_showsChineseStrings
```

**Type:** XCUITest — runtime locale verification
**Given:** The app is launched with `AppleLocale=zh_CN` and `AppleLanguages=(zh-Hans)` launch arguments.
**When:** The test waits for the login screen.
**Expected result:** The login screen shows `"添加账号"` (zh-Hans value of `"login_title"`) instead of `"Add New Account"`.
**Expected failure mode before fix:** Shows hardcoded English `"Add New Account"` because source files never call `String(localized:)`. Test fails with screenshot.
**Expected failure mode after partial fix:** Passes once `LoginView` is updated to use `String(localized: "login_title")` or `Text("login_title")` with SwiftUI auto-matching.

**Implementation:**

```swift
final class B5_LocalizationUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Force zh-Hans locale for this test run
        app.launchArguments += ["-AppleLocale", "zh_CN", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
    }

    @MainActor
    func test_loginScreen_givenZhHansLocale_showsChineseStrings() {
        // The login screen title key is "login_title" = "添加账号" in zh-Hans
        guard app.staticTexts["添加账号"].waitForExistence(timeout: 5) else {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "zh-Hans-login-screen"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail(
                "Login screen title not in Chinese — still showing hardcoded English. " +
                "B5 fix required: replace Text(\"Add New Account\") with Text(\"login_title\") " +
                "or String(localized: \"login_title\") in LoginView.swift"
            )
            return
        }
        XCTAssertTrue(app.staticTexts["添加账号"].exists,
                      "Login screen shows zh-Hans title '添加账号'")
    }
}
```

---

#### B5-UI2

```
test_settingsScreen_givenZhHantLocale_showsTraditionalChineseStrings
```

**Type:** XCUITest — runtime locale verification (Traditional Chinese)
**Given:** App launched with zh-Hant locale. User navigates to SettingsView (requires B4 to be fixed first).
**When:** SettingsView is visible.
**Expected result:** "Appearance" section header shows `"外觀"` (zh-Hant value of `"appearance"`).
**Dependency:** B4 must be fixed first (menu navigation must work). If B4 is not yet fixed, this test will fail at the navigation step, not the locale step. The failure message must distinguish the two causes.
**Expected failure mode before B4+B5 fix:** Two possible failures — navigation fails (B4) or settings shows "Appearance" in English (B5).

**Implementation:**

```swift
@MainActor
func test_settingsScreen_givenZhHantLocale_showsTraditionalChineseStrings() {
    // Must reach main screen first — use helper
    app.loginWithTestCredentials()

    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 10) else {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("Menu button not found — B4 (navigation) must be fixed before this B5 test can run")
        return
    }
    menuButton.tap()

    guard app.staticTexts["設定"].waitForExistence(timeout: 5) else {
        // ConfigView title in zh-Hant is "設定" (from "configuration" key)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail(
            "ConfigView title not in Traditional Chinese — either B4 navigation not wired or B5 localization not applied"
        )
        return
    }

    app.buttons["設定"].tap() // Settings button in zh-Hant

    guard app.staticTexts["外觀"].waitForExistence(timeout: 5) else {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("SettingsView Appearance section not in Traditional Chinese '外觀' — B5 localization incomplete")
        return
    }
    XCTAssertTrue(app.staticTexts["外觀"].exists)
}
```

---

## Test Inventory Summary

| Test ID | Name | Type | File | Blocker | Passes after fix |
|---------|------|------|------|---------|-----------------|
| B1-U1 | `test_privacyManifest_givenAppBundle_fileExists` | Unit | `PrivacyManifestTests.swift` | B1 | File added to bundle |
| B1-U2 | `test_privacyManifest_givenFile_containsNSPrivacyAccessedAPITypes` | Unit | `PrivacyManifestTests.swift` | B1 | File content valid |
| B1-U3 | `test_privacyManifest_givenFile_declaresSomeRequiredReasons` | Unit | `PrivacyManifestTests.swift` | B1 | Reason codes added |
| B2-U1 | `test_appIcon_givenBundle_primaryIconNameIsDefined` | Unit | `AppIconTests.swift` | B2 | PNG added to asset catalog |
| B2-U2 | `test_appIcon_givenBundle_iconIsLoadable` | Unit | `AppIconTests.swift` | B2 | PNG added to asset catalog |
| B3-U1 | `test_infoPlist_givenBundle_NSFaceIDUsageDescriptionExists` | Unit | `InfoPlistTests.swift` | B3 | Key added to Info.plist |
| B3-U2 | `test_infoPlist_givenBundle_CFBundleLocalizationsContainsRequiredLocales` | Unit | `InfoPlistTests.swift` | B3 | Array added to Info.plist |
| B3-U3 | `test_infoPlist_givenBundle_NSFaceIDUsageDescriptionIsUserFacing` | Unit | `InfoPlistTests.swift` | B3 | Non-placeholder string |
| B4-UI1 | `test_menuButton_givenMainScreen_configViewAppears` | XCUITest | `B4_ConfigNavigationTests.swift` | B4 | `onMenuClick` wired |
| B4-UI2 | `test_configView_givenOpened_showsAccountSection` | XCUITest | `B4_ConfigNavigationTests.swift` | B4 | `onMenuClick` wired |
| B4-UI3 | `test_configView_givenOpened_hasSettingsButton` | XCUITest | `B4_ConfigNavigationTests.swift` | B4 | `onMenuClick` wired |
| B4-UI4 | `test_configView_givenOpened_hasAddAccountButton` | XCUITest | `B4_ConfigNavigationTests.swift` | B4 | `onMenuClick` wired |
| B4-UI5 | `test_configView_givenOpened_hasLogoutButton` | XCUITest | `B4_ConfigNavigationTests.swift` | B4 | `onMenuClick` wired |
| B4-UI6 | `test_fullFlow_givenMainScreen_menuThenConfigThenSettings_languageSectionVisible` | XCUITest | `B4_ConfigNavigationTests.swift` | B4+B5 | Both B4 and B5 fixed |
| B5-U1 | `test_localization_givenEnglishBundle_settingsKeyExists` | Unit | `LocalizationTests.swift` | B5 | Already passes (file exists) |
| B5-U2 | `test_localization_givenAllLocales_requiredKeysArePresent` | Unit | `LocalizationTests.swift` | B5 | Already passes (files exist) |
| B5-U3 | `test_localization_givenZhHans_settingsKeyIsChineseSimplified` | Unit | `LocalizationTests.swift` | B5 | Already passes (file exists) |
| B5-U4 | `test_localization_givenZhHant_settingsKeyIsChineseTraditional` | Unit | `LocalizationTests.swift` | B5 | Already passes (file exists) |
| B5-U5 | `test_localization_givenAllLocales_keyCountIsConsistent` | Unit | `LocalizationTests.swift` | B5 | Already passes (files exist) |
| B5-UI1 | `test_loginScreen_givenZhHansLocale_showsChineseStrings` | XCUITest | `B5_LocalizationUITests.swift` | B5 | After string literals replaced |
| B5-UI2 | `test_settingsScreen_givenZhHantLocale_showsTraditionalChineseStrings` | XCUITest | `B5_LocalizationUITests.swift` | B4+B5 | After both B4 and B5 fixed |

**Total: 21 tests** — 13 unit tests, 8 XCUITests

---

## Implementation Notes and Constraints

### Ordering: fix B3 before B1 before B2 before B4 before B5

The audit's recommended order stands:
1. **B3 first (15 min):** `Info.plist` keys are prerequisites for Face ID to function without crashing during any B4 navigation tests that reach the auth gate.
2. **B1 second (30 min):** Privacy manifest is a compilation-time artifact; confirm with a clean build + archive before running the B1 unit tests.
3. **B2 third (1 hr):** App icon has no runtime consequence for the other tests but must be done before TestFlight upload.
4. **B4 fourth (2–3 hrs):** Wire `onMenuClick`. The B4 XCUITests will drive the implementation — run them after each wiring attempt to confirm the navigation stack is correct.
5. **B5 fifth (4–6 hrs):** The B5 unit tests already pass because the strings files exist. The B5 XCUITests drive the source-level fix (replacing all string literals with `String(localized:)` calls).

### B4 navigation implementation options

`ConfigView` accepts `onBackClick`, `onSettingsClick`, `onAddAccountClick`, and `onLogout` callbacks. The wiring in `odooApp.swift` should use one of:

- **`.sheet(isPresented:)`** on `AppRootView` — simplest, but loses nav bar back swipe.
- **`NavigationStack` push from `AppRootView`** using a `@State var showConfig = false` and `NavigationLink(destination: ConfigView(...), isActive: $showConfig)` — matches the existing `MainView` `NavigationStack`.
- **Full-screen cover** — appropriate if config is considered a modal context.

The XCUITests are presentation-agnostic: they only require that `app.staticTexts["Configuration"]` appears within 5 seconds of the menu tap. Any of the three options will make the tests pass.

### B5-U1 through B5-U5 pass before the fix

The B5 unit tests probe the strings files directly via `Bundle(path:)` — they do not test whether Swift source files call `String(localized:)`. They will pass as soon as the files are in the bundle (which they already are). This is intentional: they document the contract of the strings files and guard against regressions (e.g., accidentally deleting a key during a merge). The XCUITests (B5-UI1, B5-UI2) are the ones that fail before the fix and pass after.

### Why no `sleep()` in any test above

Per CLAUDE.md, `sleep()` is prohibited. All timing uses `waitForExistence(timeout:)`. The existing `odooUITests.swift` violates this rule (lines 47, 55, 169, etc.) — those existing tests are out of scope to fix here, but the new tests introduced in this plan contain zero `sleep()` calls.

### `XCTFail` in every guard branch

Every `guard … else { … return }` block in the XCUITests above calls `XCTFail` with a precise message identifying which fix is needed. This is required by CLAUDE.md and ensures that a timed-out `waitForExistence` never silently passes.

---

## Running the Tests

### Unit tests only (fast, no Simulator needed)

```bash
xcodebuild \
  -project /Users/alanlin/Woow_odoo_ios/odoo.xcodeproj \
  -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:odooTests/PrivacyManifestTests \
  -only-testing:odooTests/AppIconTests \
  -only-testing:odooTests/InfoPlistTests \
  -only-testing:odooTests/LocalizationTests \
  test
```

### B4 navigation UI tests (requires Simulator + live server OR auto-login injection)

```bash
xcodebuild \
  -project /Users/alanlin/Woow_odoo_ios/odoo.xcodeproj \
  -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:odooUITests/B4_ConfigNavigationTests \
  test
```

### B5 localization UI tests

```bash
xcodebuild \
  -project /Users/alanlin/Woow_odoo_ios/odoo.xcodeproj \
  -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:odooUITests/B5_LocalizationUITests \
  test
```

### All blocker tests

```bash
xcodebuild \
  -project /Users/alanlin/Woow_odoo_ios/odoo.xcodeproj \
  -scheme odoo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:odooTests/PrivacyManifestTests \
  -only-testing:odooTests/AppIconTests \
  -only-testing:odooTests/InfoPlistTests \
  -only-testing:odooTests/LocalizationTests \
  -only-testing:odooUITests/B4_ConfigNavigationTests \
  -only-testing:odooUITests/B5_LocalizationUITests \
  test
```

---

## Acceptance Criteria

All five blockers are cleared when:

| Blocker | Acceptance criterion |
|---------|---------------------|
| B1 | B1-U1, B1-U2, B1-U3 all pass. `xcodebuild archive` produces no `ITMS-91053` warning. |
| B2 | B2-U1, B2-U2 both pass. Archive produces no icon-related `ITMS-90717` warning. |
| B3 | B3-U1, B3-U2, B3-U3 all pass. |
| B4 | B4-UI1 through B4-UI6 all pass without live server (auto-login injection) or with `TestConfig` credentials. |
| B5 | B5-U1 through B5-U5 pass (they already pass if files are in bundle). B5-UI1 and B5-UI2 pass after string literals are replaced with `String(localized:)` calls. |
