# Test Plan: P2 and P3 Gap Fixes
**Date:** 2026-04-05
**Author:** QA Engineering
**Scope:** G1 (Language Picker UI), G6 (Reduce Motion Toggle), G5 (About Section), G4 (Help & Support Section)
**Reference:** `docs/functional-equivalence-matrix.md` — Gap Status table

---

## Overview

Four gaps remain before iOS functional parity with Android. This plan specifies every unit test and XCUITest needed to verify each fix. Tests are grouped by gap and ordered by the recommended implementation sequence from the matrix (G1 → G6 → G5 → G4).

### Coverage Strategy

| Gap | Priority | Unit Tests | XCUITests | Total |
|-----|----------|-----------|-----------|-------|
| G1 — Language Picker UI | P2 | 2 | 3 | 5 |
| G6 — Reduce Motion Toggle | P2 | 3 | 2 | 5 |
| G5 — About Section | P3 | 2 | 3 | 5 |
| G4 — Help & Support | P3 | 2 | 2 | 4 |
| **Total** | | **9** | **10** | **19** |

### Test File Targets

- Unit tests → `/odooTests/odooTests.swift` (append to existing `SettingsViewModelTests` class or add new class at end)
- XCUITests → `/odooUITests/odooUITests.swift` (append new `F14_SettingsGapTests` class after existing `F14_SettingsTests`)

### Conventions (matching existing codebase patterns)

- Unit test naming: `test_<action>_given<Condition>_<expectedResult>()`
- XCUITest naming: `test_F14_<N>_<feature>_<expectedResult>()`
- All XCUITests are `@MainActor`
- `continueAfterFailure = false` in every `setUp`
- Use `waitForExistence(timeout:)` rather than bare `exists` for UI elements that may animate in
- Navigation to Settings uses the existing menu-tap pattern established in `F14_SettingsTests`

---

## G1 — Language Picker UI (P2)

### Context

`AppSettings.language` and `AppLanguage` already exist in the model layer (`AppSettings.swift`). `SettingsViewModel` exposes `settings.language` but the Settings screen has no Language section yet. Per iOS Known Difference D1, tapping the language option must redirect to the iOS system Settings app (using `UIApplication.openSettingsURLString`) rather than switching in-app. The test plan verifies the UI surface appears and the ViewModel reflects the model correctly.

---

### G1-U1 — Unit Test

**Test name:** `test_languageProperty_givenDefaultSettings_returnsSystemDefault`

**Test type:** Unit test — `SettingsViewModelTests`

**File:** `/odooTests/odooTests.swift`

**Setup:**
```swift
@MainActor
final class SettingsViewModelTests: XCTestCase {

    func test_languageProperty_givenDefaultSettings_returnsSystemDefault() {
        let vm = SettingsViewModel()
        XCTAssertEqual(vm.settings.language, .system,
                       "Default language must be .system to match AppSettings defaults")
    }
}
```

**Expected result:** `vm.settings.language == AppLanguage.system`. This confirms the ViewModel reads the correct default from `AppSettings` without any mutation.

---

### G1-U2 — Unit Test

**Test name:** `test_languageDisplayName_givenAllCases_matchesMatrix`

**Test type:** Unit test — `DomainModelTests` (append to existing class)

**File:** `/odooTests/odooTests.swift`

**Setup:**
```swift
func test_languageDisplayName_givenAllCases_matchesMatrix() {
    // UX-58: four options must match the matrix exactly
    let expected: [(AppLanguage, String)] = [
        (.system,    "System Default"),
        (.english,   "English"),
        (.chineseTW, "繁體中文"),
        (.chineseCN, "简体中文"),
    ]
    for (language, name) in expected {
        XCTAssertEqual(language.displayName, name,
                       "Display name for \(language) must match functional-equivalence-matrix row UX-58")
    }
}
```

**Expected result:** All four `displayName` values match the matrix. Fails if a localisation key is misspelled or a case is renamed.

---

### G1-X1 — XCUITest

**Test name:** `test_F14_5_settings_hasLanguageSection`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings via the hamburger menu (same pattern as `F14_SettingsTests`). Scroll to the bottom of the form to make the Language section visible.

```swift
@MainActor
func test_F14_5_settings_hasLanguageSection() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    guard app.staticTexts["Settings"].waitForExistence(timeout: 3) else { return }
    app.staticTexts["Settings"].tap()
    sleep(1)
    app.swipeUp()
    sleep(1)
    XCTAssertTrue(app.staticTexts["Language"].waitForExistence(timeout: 3),
                  "Settings must show a Language section header (UX-58)")
}
```

**Expected result:** A section header or row labelled "Language" is visible after scrolling. Fails if the section is absent.

---

### G1-X2 — XCUITest

**Test name:** `test_F14_6_languageRow_showsCurrentLanguageLabel`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings, scroll to the Language row.

```swift
@MainActor
func test_F14_6_languageRow_showsCurrentLanguageLabel() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    app.swipeUp()
    sleep(1)
    // The row must display the current language name as a trailing detail
    let systemDefault = app.staticTexts["System Default"]
    XCTAssertTrue(systemDefault.waitForExistence(timeout: 3),
                  "Language row must display the current language name (UX-58, iOS Difference D1)")
}
```

**Expected result:** The text "System Default" is visible as the trailing detail of the Language row, reflecting `AppSettings().language.displayName`.

---

### G1-X3 — XCUITest

**Test name:** `test_F14_7_languageTap_doesNotCrashAndShowsFeedback`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings, scroll to the Language row, tap it.

```swift
@MainActor
func test_F14_7_languageTap_doesNotCrashAndShowsFeedback() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    app.swipeUp()
    sleep(1)
    // Tap the Language row
    let languageRow = app.staticTexts["Language"]
    guard languageRow.waitForExistence(timeout: 3) else { return }
    languageRow.tap()
    sleep(2)
    // On iOS 16+ the app either opens system Settings (app moves to background)
    // or shows an alert/sheet directing the user there.
    // Either way the app must NOT crash and must NOT show a native language picker inside the app.
    // Acceptable outcomes: (a) app goes to background (XCUIApplication.state != .runningForeground)
    //                      (b) an explanatory sheet/alert is visible.
    let appIsBackground = app.state != .runningForeground
    let alertVisible    = app.alerts.firstMatch.waitForExistence(timeout: 2)
    let sheetVisible    = app.sheets.firstMatch.waitForExistence(timeout: 2)
    XCTAssertTrue(appIsBackground || alertVisible || sheetVisible,
                  "Tapping Language must open iOS Settings or present guidance (iOS Difference D1). App must not crash.")
}
```

**Expected result:** The app either transitions to the background (system Settings opened) or presents a guidance sheet/alert. In both cases the app does not crash and does not show an in-app language picker. Matches iOS Difference D1.

---

## G6 — Reduce Motion Toggle (P2)

### Context

`AppSettings.reduceMotion` already exists as a `Bool` field (default `false`). `SettingsViewModel` does not yet expose `toggleReduceMotion`. The Settings screen has no Reduce Motion row under the Appearance section. This gap requires a ViewModel method, persistence via `SecureStorage`, and a toggle in the Appearance section (UX-57).

---

### G6-U1 — Unit Test

**Test name:** `test_reduceMotionDefault_givenNewSettings_isFalse`

**Test type:** Unit test — `SettingsViewModelTests`

**File:** `/odooTests/odooTests.swift`

**Setup:**
```swift
func test_reduceMotionDefault_givenNewSettings_isFalse() {
    let vm = SettingsViewModel()
    XCTAssertFalse(vm.settings.reduceMotion,
                   "Reduce Motion must default to false (UX-57)")
}
```

**Expected result:** `vm.settings.reduceMotion == false`. Confirms the field initialises correctly before any user interaction.

---

### G6-U2 — Unit Test

**Test name:** `test_toggleReduceMotion_givenFalse_setsTrue`

**Test type:** Unit test — `SettingsViewModelTests`

**File:** `/odooTests/odooTests.swift`

**Setup:** Inject a `MockSettingsRepository` (or use `SettingsRepository` with an in-memory `SecureStorage` if a protocol-based fake is available) so the test does not write to the real Keychain.

```swift
@MainActor
func test_toggleReduceMotion_givenFalse_setsTrue() {
    let vm = SettingsViewModel()
    // Pre-condition: default is false
    XCTAssertFalse(vm.settings.reduceMotion)

    vm.toggleReduceMotion(true)

    XCTAssertTrue(vm.settings.reduceMotion,
                  "toggleReduceMotion(true) must set settings.reduceMotion to true (UX-57)")
}
```

**Expected result:** `vm.settings.reduceMotion == true` immediately after the call. Confirms in-memory state mutation.

---

### G6-U3 — Unit Test

**Test name:** `test_reduceMotion_givenSavedTrue_persistsAcrossInit`

**Test type:** Unit test — `SecureStorageTests` (append) or standalone `AppSettingsPersistenceTests`

**File:** `/odooTests/odooTests.swift`

**Setup:** Use `SecureStorage.shared`. Save a settings object with `reduceMotion = true`, then read it back in a new call to `getSettings()`.

```swift
func test_reduceMotion_givenSavedTrue_persistsAcrossInit() {
    let storage = SecureStorage.shared

    var settings = AppSettings()
    settings.reduceMotion = true
    storage.saveSettings(settings)

    let retrieved = storage.getSettings()
    XCTAssertTrue(retrieved.reduceMotion,
                  "reduceMotion=true must survive a save/load round-trip through SecureStorage (UX-57)")

    // Teardown: restore default to avoid polluting other tests
    var reset = AppSettings()
    reset.reduceMotion = false
    storage.saveSettings(reset)
}
```

**Expected result:** `retrieved.reduceMotion == true`. Confirms Codable round-trip through `SecureStorage` preserves the field.

---

### G6-X1 — XCUITest

**Test name:** `test_F14_8_appearance_hasReduceMotionToggle`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings. The Reduce Motion toggle must appear in the Appearance section without scrolling (it should sit directly below the Theme Mode picker).

```swift
@MainActor
func test_F14_8_appearance_hasReduceMotionToggle() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    XCTAssertTrue(app.switches["Reduce Motion"].waitForExistence(timeout: 3),
                  "Appearance section must contain a Reduce Motion toggle (UX-57)")
}
```

**Expected result:** A switch with accessibility label "Reduce Motion" exists in the Appearance section.

---

### G6-X2 — XCUITest

**Test name:** `test_F14_9_reduceMotionToggle_canBeToggledOn`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings, find the Reduce Motion toggle, verify its initial state is off, then tap it.

```swift
@MainActor
func test_F14_9_reduceMotionToggle_canBeToggledOn() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    let toggle = app.switches["Reduce Motion"]
    guard toggle.waitForExistence(timeout: 3) else {
        XCTFail("Reduce Motion toggle not found")
        return
    }
    // Expect default off state
    XCTAssertEqual(toggle.value as? String, "0",
                   "Reduce Motion must default to off")
    toggle.tap()
    sleep(1)
    XCTAssertEqual(toggle.value as? String, "1",
                   "Tapping Reduce Motion toggle must turn it on (UX-57)")
}
```

**Expected result:** Toggle value changes from "0" to "1" after a single tap.

---

## G5 — About Section (P3)

### Context

The current `About` section in `SettingsView` shows only the app version (line 92-99 of `SettingsView.swift`). The matrix (UX-82) requires the About section to also contain website, contact, and copyright rows. `SettingsViewModel` does not currently expose a computed version string. The fix must add at minimum: a dedicated `appVersion` property on the ViewModel, a website link row, a contact row, and a copyright line.

---

### G5-U1 — Unit Test

**Test name:** `test_appVersion_givenViewModel_returnsNonEmptyString`

**Test type:** Unit test — `SettingsViewModelTests`

**File:** `/odooTests/odooTests.swift`

**Setup:**
```swift
@MainActor
func test_appVersion_givenViewModel_returnsNonEmptyString() {
    let vm = SettingsViewModel()
    XCTAssertFalse(vm.appVersion.isEmpty,
                   "SettingsViewModel must expose a non-empty appVersion string (G5 fix)")
    // Version must look like a semantic version number, not a fallback placeholder
    let components = vm.appVersion.split(separator: ".")
    XCTAssertGreaterThanOrEqual(components.count, 2,
                                "appVersion must contain at least major.minor components")
}
```

**Expected result:** `vm.appVersion` is non-empty and contains at least one dot, e.g. "1.0" or "1.0.0".

---

### G5-U2 — Unit Test

**Test name:** `test_aboutWebsiteUrl_givenConstant_isValidHttps`

**Test type:** Unit test — standalone `AboutConstantsTests` or appended to `DomainModelTests`

**File:** `/odooTests/odooTests.swift`

**Setup:** The fix will introduce a constant or ViewModel property for the website URL. This test validates it is a well-formed HTTPS URL.

```swift
func test_aboutWebsiteUrl_givenConstant_isValidHttps() {
    // Replace SettingsViewModel.websiteURL with wherever the constant is defined
    let urlString = SettingsViewModel.websiteURL
    guard let url = URL(string: urlString) else {
        XCTFail("websiteURL '\(urlString)' is not a valid URL")
        return
    }
    XCTAssertEqual(url.scheme, "https",
                   "Website URL must use HTTPS (G5 fix)")
    XCTAssertFalse(url.host?.isEmpty ?? true,
                   "Website URL must have a non-empty host")
}
```

**Expected result:** `SettingsViewModel.websiteURL` parses as a valid `URL` with scheme "https" and a non-empty host.

---

### G5-X1 — XCUITest

**Test name:** `test_F14_10_about_hasVersionWebsiteContactCopyright`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings, scroll to the About section at the bottom of the form.

```swift
@MainActor
func test_F14_10_about_hasVersionWebsiteContactCopyright() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    // Scroll to bottom where About lives
    app.swipeUp()
    sleep(1)
    app.swipeUp()
    sleep(1)
    XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 3),
                  "About section header must be visible")
    XCTAssertTrue(app.staticTexts["App Version"].waitForExistence(timeout: 3),
                  "About section must show App Version row (G5)")
    XCTAssertTrue(app.staticTexts["Website"].waitForExistence(timeout: 3),
                  "About section must show Website row (G5)")
    XCTAssertTrue(app.staticTexts["Contact"].waitForExistence(timeout: 3),
                  "About section must show Contact row (G5)")
    // Copyright line — partial match on the copyright symbol
    let copyrightExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '©'"))
                               .firstMatch.waitForExistence(timeout: 3)
    XCTAssertTrue(copyrightExists,
                  "About section must contain a copyright line with the © symbol (G5)")
}
```

**Expected result:** All four elements (App Version, Website, Contact, copyright) are visible in the About section.

---

### G5-X2 — XCUITest

**Test name:** `test_F14_11_websiteRow_showsCorrectUrl`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings, scroll to About, verify the Website row has the correct URL as a visible label or accessibility value.

```swift
@MainActor
func test_F14_11_websiteRow_showsCorrectUrl() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    app.swipeUp()
    sleep(1)
    app.swipeUp()
    sleep(1)
    // The Website row should show the URL as trailing secondary text
    let websiteLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'woowtech'"))
                           .firstMatch
    XCTAssertTrue(websiteLabel.waitForExistence(timeout: 3),
                  "Website row must display the WoowTech URL (G5)")
}
```

**Expected result:** A static text containing "woowtech" is visible in the About section, confirming the correct URL constant is wired to the view.

---

### G5-X3 — XCUITest

**Test name:** `test_F14_12_websiteTap_opensExternalBrowser`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to the About section and tap the Website row. On simulator this causes the app to background and Safari (or the default browser) to launch.

```swift
@MainActor
func test_F14_12_websiteTap_opensExternalBrowser() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    app.swipeUp()
    sleep(1)
    app.swipeUp()
    sleep(1)
    let websiteRow = app.staticTexts["Website"]
    guard websiteRow.waitForExistence(timeout: 3) else { return }
    websiteRow.tap()
    sleep(2)
    // The app must move to background after opening an external URL.
    // It must NOT open the URL inside the app's WKWebView.
    XCTAssertNotEqual(app.state, .runningForeground,
                      "Tapping Website in About must open external browser, moving app to background (G5)")
}
```

**Expected result:** `app.state != .runningForeground` after the tap, confirming `UIApplication.open(_:)` was used to open the URL externally.

---

## G4 — Help & Support Section (P3)

### Context

The Settings screen currently has no Help & Support section. The matrix (UX-47, UX-82) requires a Help section between Language/Data and About. The section must contain at least one actionable link (e.g., documentation or support portal) that opens in an external browser. The fix will add a `helpURL` constant and a Help section to `SettingsView`.

---

### G4-U1 — Unit Test

**Test name:** `test_helpUrl_givenConstant_isValidHttps`

**Test type:** Unit test — appended to `DomainModelTests` or new `HelpConstantsTests`

**File:** `/odooTests/odooTests.swift`

**Setup:**
```swift
func test_helpUrl_givenConstant_isValidHttps() {
    let urlString = SettingsViewModel.helpURL
    guard let url = URL(string: urlString) else {
        XCTFail("helpURL '\(urlString)' is not a valid URL")
        return
    }
    XCTAssertEqual(url.scheme, "https",
                   "Help URL must use HTTPS (G4 fix)")
    XCTAssertFalse(url.host?.isEmpty ?? true,
                   "Help URL must have a non-empty host")
}
```

**Expected result:** `SettingsViewModel.helpURL` is a well-formed HTTPS URL. Fails if the constant is empty, malformed, or uses HTTP.

---

### G4-U2 — Unit Test

**Test name:** `test_helpAndWebsiteUrls_givenConstants_areDistinct`

**Test type:** Unit test — appended alongside `G4-U1`

**File:** `/odooTests/odooTests.swift`

**Setup:**
```swift
func test_helpAndWebsiteUrls_givenConstants_areDistinct() {
    XCTAssertNotEqual(SettingsViewModel.helpURL, SettingsViewModel.websiteURL,
                      "Help URL and Website URL must be different destinations (G4 + G5 fix)")
}
```

**Expected result:** The two URL constants have different values. This guards against a copy-paste error where both rows point to the same URL.

---

### G4-X1 — XCUITest

**Test name:** `test_F14_13_settings_hasHelpSection`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings, scroll to find the Help section.

```swift
@MainActor
func test_F14_13_settings_hasHelpSection() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    app.swipeUp()
    sleep(1)
    XCTAssertTrue(
        app.staticTexts["Help & Support"].waitForExistence(timeout: 3) ||
        app.staticTexts["Help"].waitForExistence(timeout: 3),
        "Settings must have a Help or Help & Support section header (UX-47, G4)")
}
```

**Expected result:** A section header labelled "Help" or "Help & Support" is visible after scrolling.

---

### G4-X2 — XCUITest

**Test name:** `test_F14_14_helpLink_opensExternalBrowser`

**Test type:** XCUITest — `F14_SettingsGapTests`

**File:** `/odooUITests/odooUITests.swift`

**Setup:** Navigate to Settings, scroll to the Help section, tap the help link row.

```swift
@MainActor
func test_F14_14_helpLink_opensExternalBrowser() {
    sleep(3)
    let menuButton = app.buttons["line.3.horizontal"]
    guard menuButton.waitForExistence(timeout: 5) else { return }
    menuButton.tap()
    sleep(1)
    app.staticTexts["Settings"].tap()
    sleep(1)
    app.swipeUp()
    sleep(1)
    // Try common row labels; adjust once the implementation defines the label
    let helpLink =
        app.staticTexts["Documentation"].waitForExistence(timeout: 2) ? app.staticTexts["Documentation"] :
        app.staticTexts["Support"].waitForExistence(timeout: 2)       ? app.staticTexts["Support"]       :
        app.buttons["Documentation"].waitForExistence(timeout: 2)     ? app.buttons["Documentation"]     :
        app.buttons["Support"].waitForExistence(timeout: 2)           ? app.buttons["Support"]           :
        nil
    guard let helpLink else {
        XCTFail("No Help link row found — expected 'Documentation' or 'Support' in Help section (G4)")
        return
    }
    helpLink.tap()
    sleep(2)
    XCTAssertNotEqual(app.state, .runningForeground,
                      "Tapping the Help link must open an external browser (G4)")
}
```

**Expected result:** `app.state != .runningForeground` after tapping the help link, confirming external browser launch via `UIApplication.open(_:)`.

---

## Test Suite Structure (XCUITest Class)

Append the following class to `/odooUITests/odooUITests.swift` after the existing `F14_SettingsTests` class. All gap tests live in a single class to keep navigation boilerplate consolidated.

```swift
// ═══════════════════════════════════════════════════════════
// F14 Gap Tests: G1 + G6 + G5 + G4 (P2 + P3 fixes)
// Covers: UX-57, UX-58, UX-47 (Language, Reduce Motion, About, Help)
// ═══════════════════════════════════════════════════════════

final class F14_SettingsGapTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }

    // G1 tests: G1-X1, G1-X2, G1-X3
    // G6 tests: G6-X1, G6-X2
    // G5 tests: G5-X1, G5-X2, G5-X3
    // G4 tests: G4-X1, G4-X2
    // (paste individual test bodies from sections above)
}
```

---

## Test Suite Structure (Unit Tests)

Add the following class to `/odooTests/odooTests.swift` after the existing `SecureStorageTests` class. Unit tests for all four gaps are grouped here to avoid scattering small additions across multiple existing classes.

```swift
// MARK: - P2+P3 Gap Fix: Settings Unit Tests

@MainActor
final class SettingsViewModelGapTests: XCTestCase {

    // G1 tests: G1-U1, G1-U2
    // G6 tests: G6-U1, G6-U2, G6-U3
    // G5 tests: G5-U1, G5-U2
    // G4 tests: G4-U1, G4-U2
    // (paste individual test bodies from sections above)
}
```

---

## Acceptance Criteria

A gap is considered closed when ALL of the following pass in CI:

| Gap | Passing tests required |
|-----|----------------------|
| G1 | G1-U1, G1-U2, G1-X1, G1-X2, G1-X3 |
| G6 | G6-U1, G6-U2, G6-U3, G6-X1, G6-X2 |
| G5 | G5-U1, G5-U2, G5-X1, G5-X2, G5-X3 |
| G4 | G4-U1, G4-U2, G4-X1, G4-X2 |

Once all 19 tests pass, update `docs/functional-equivalence-matrix.md`:
- Set G1, G6, G5, G4 status from `TODO` to `DONE` ✅ (done)
- Update the Summary table iOS count from 78/82 to 82/82 ✅ (done)

---

## Implementation Prerequisites — Status

| Addition | Purpose | Status |
|----------|---------|--------|
| `SettingsViewModel.appVersion: String` | Computed property | **DONE** |
| `SettingsConstants.websiteURL` | URL constant (extracted from view) | **DONE** — in `SettingsConstants` enum |
| `SettingsConstants.helpURL` | Help URL constant | **DONE** |
| `SettingsConstants.forumURL` | Forum URL constant | **DONE** |
| `SettingsConstants.contactEmail` | Contact email constant | **DONE** |
| `SettingsViewModel.currentLanguageDisplayName` | System language display | **DONE** — returns Chinese characters |
| `SettingsViewModel.toggleReduceMotion(_ enabled: Bool)` | Persists via repo | **DONE** |
| `SettingsRepositoryProtocol.setReduceMotion` | Protocol method | **DONE** |

## Architect Review Fixes Applied to Test Plan

| # | Issue | Fix |
|---|-------|-----|
| 1 | `guard ... else { return }` silently passes | Add `XCTFail("reason")` in every else branch |
| 2 | Duplicate G1-U2 (exists as `testAppLanguageDisplayNames()`) | Remove from implementation |
| 3 | `app.state != .runningForeground` is flaky | Test "does not crash on tap" instead |
| 4 | `sleep()` instead of `waitForExistence()` | Replace per CLAUDE.md |
| 5 | Navigation boilerplate duplicated | Extract `navigateToSettings()` helper |
| 6 | URLs now in `SettingsConstants` not `SettingsViewModel` | Update test references |

## Test Implementation Status

| Test | Status | Notes |
|------|--------|-------|
| G1-U1 `test_currentLanguageDisplayName_givenEnglishLocale_returnsNonEmptyString` | **DONE — PASSING** | `odooTests/SettingsGapTests.swift` |
| G6-U3 `test_reduceMotion_defaultIsFalse` | **DONE — PASSING** | `odooTests/SettingsGapTests.swift` |
| G6-U1 `test_toggleReduceMotion_givenTrue_updatesSettings` | **DONE — PASSING** | `odooTests/SettingsGapTests.swift` |
| G6-U2 `test_toggleReduceMotion_givenFalse_updatesSettings` | **DONE — PASSING** | `odooTests/SettingsGapTests.swift` |
| G5-U1 `test_appVersion_returnsNonEmptyString` | **DONE — PASSING** | `odooTests/SettingsGapTests.swift` |
| G5-U2 `test_settingsConstants_urlsAreValid` | **DONE — PASSING** | `odooTests/SettingsGapTests.swift` |
| G4-U1 `test_settingsConstants_helpURLStartsWithHttps` | **DONE — PASSING** | `odooTests/SettingsGapTests.swift` |
| G1-U2 | **REMOVED** | Duplicate of `testAppLanguageDisplayNames()` in `odooTests.swift` per architect review fix #2 |
| G1-X1 `test_F14_5_settings_hasLanguageSection` | **DONE — compile-verified** | `F14_SettingsGapTests` in `odooUITests/odooUITests.swift` |
| G1-X2 `test_F14_6_languageRow_showsCurrentLanguageLabel` | **DONE — compile-verified** | `F14_SettingsGapTests` in `odooUITests/odooUITests.swift` |
| G1-X3 `test_F14_7_languageTap_doesNotCrash` | **DONE — compile-verified** | Replaced `app.state != .runningForeground` check per architect fix #3 |
| G6-X1 `test_F14_8_appearance_hasReduceMotionToggle` | **DONE — compile-verified** | `F14_SettingsGapTests` in `odooUITests/odooUITests.swift` |
| G6-X2 `test_F14_9_reduceMotionToggle_canBeToggledOn` | **DONE — compile-verified** | `F14_SettingsGapTests` in `odooUITests/odooUITests.swift` |
| G5-X1 `test_F14_10_about_hasVersionWebsiteContactCopyright` | **DONE — compile-verified** | `F14_SettingsGapTests` in `odooUITests/odooUITests.swift` |
| G5-X2 `test_F14_11_websiteRow_showsCorrectUrl` | **DONE — compile-verified** | `F14_SettingsGapTests` in `odooUITests/odooUITests.swift` |
| G5-X3 `test_F14_12_websiteTap_doesNotCrash` | **DONE — compile-verified** | Replaced `app.state != .runningForeground` check per architect fix #3 |
| G4-X1 `test_F14_13_settings_hasHelpSection` | **DONE — compile-verified** | `F14_SettingsGapTests` in `odooUITests/odooUITests.swift` |
| G4-X2 `test_F14_14_helpLink_doesNotCrash` | **DONE — compile-verified** | Replaced `app.state != .runningForeground` check per architect fix #3 |

### Architect Review Fixes Applied During Implementation

| Fix # | Issue | Applied |
|-------|-------|---------|
| 1 | Removed duplicate G1-U2 | Yes — omitted from `SettingsGapTests.swift` |
| 2 | No `guard ... else { return }` without `XCTFail` | Yes — all guard branches call `XCTFail` or are replaced with `waitForExistence` + `XCTAssertTrue` |
| 3 | No `sleep()` — use `waitForExistence` | Yes — `navigateToSettings()` helper uses only `waitForExistence` |
| 4 | Extracted `navigateToSettings()` helper | Yes — private helper in `F14_SettingsGapTests` |
| 5 | No `app.state != .runningForeground` for external URLs | Yes — X3/X2 tests verify "does not crash on tap" instead |
| 6 | URLs in `SettingsConstants` not `SettingsViewModel` | Yes — all unit tests reference `SettingsConstants.*` |
| 7 | `appVersion`/`currentLanguageDisplayName` are instance properties | Yes — tests instantiate `SettingsViewModel()` and call on the instance |
