# P2 + P3 Gap Fix Implementation Plan

> **Date:** 2026-04-05
> **Scope:** 4 remaining gaps (G1, G6, G5, G4) from functional-equivalence-matrix.md
> **Total Effort:** ~6.5 hours
> **Prerequisite:** P0 + P1 gaps already closed

---

## Overview

| Order | Gap | Priority | UX Items | Effort | Summary |
|-------|-----|----------|----------|--------|---------|
| 1 | G1 | P2 | UX-58, UX-59 | 2h | Language picker UI (redirect to iOS Settings) |
| 2 | G6 | P2 | UX-57 | 1h | Reduce Motion toggle in Appearance section |
| 3 | G5 | P3 | UX-47 | 1.5h | About section: website, contact email, copyright |
| 4 | G4 | P3 | UX-47, UX-82 | 2h | Help & Support section with external links |

---

## Work Item 1: G1 -- Language Picker UI (P2, 2h)

### Problem

iOS uses the system per-app language setting (Settings app -> odoo -> Language) per Apple's iOS 16+ guidelines. The `SettingsView` currently has no Language section at all, so the user has no indication that language can be changed or how to do it.

Android (reference: `SettingsScreen.kt` lines 216-223) shows a Language section with an in-app picker dialog listing System Default, English, Traditional Chinese, and Simplified Chinese. iOS cannot replicate in-app switching but must show an equivalent section that guides the user to the correct system setting.

### Current State

- `AppSettings.swift` already declares `language: AppLanguage = .system` with the `AppLanguage` enum providing `system`, `english`, `chineseTW`, `chineseCN` cases and `displayName` computed property.
- `SettingsView.swift` has no Language section.
- `SettingsViewModel.swift` has no language-related methods.

### Implementation

#### File 1: `odoo/UI/Settings/SettingsView.swift`

Add a new **Language** section between the Security section and the Data & Storage section. This maintains the section order from UX-82: Appearance -> Security -> **Language** -> Data -> Help -> About.

**Insert after the Security section closing brace (after line 73), before `// Data & Storage`:**

```swift
// Language
Section("Language") {
    Button {
        // Open the app's language settings in iOS Settings
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    } label: {
        HStack {
            Label("Language", systemImage: "globe")
            Spacer()
            Text(currentLanguageDisplayName())
                .foregroundStyle(.secondary)
                .font(.caption)
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
    .foregroundStyle(.primary)

    Text("Change language in Settings -> odoo -> Language")
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```

**Add a private helper at the bottom of `SettingsView` (before the closing brace of the struct):**

```swift
/// Returns the display name for the current app language based on the
/// system's preferred language for this app bundle.
private func currentLanguageDisplayName() -> String {
    guard let preferred = Bundle.main.preferredLocalizations.first else {
        return "System Default"
    }
    switch preferred {
    case "en": return "English"
    case "zh-Hant": return "Traditional Chinese"
    case "zh-Hans": return "Simplified Chinese"
    default: return "System Default"
    }
}
```

**Why a helper instead of reading `AppSettings.language`:** On iOS, the per-app language is managed by the system, not our model. `Bundle.main.preferredLocalizations` reflects the actual language the OS selected for our bundle, which is the source of truth.

#### File 2: `odoo/Resources/en.lproj/Localizable.strings`

Add:
```
/* Language */
"language" = "Language";
"language_change_hint" = "Change language in Settings -> odoo -> Language";
```

#### File 3: `odoo/Resources/zh-Hans.lproj/Localizable.strings`

Add:
```
/* Language */
"language" = "Language";
"language_change_hint" = "Change language in Settings -> odoo -> Language";
```

Note: The hint text stays in English intentionally -- once the user changes the system language, the entire Localizable.strings file switches and they see translated strings. The hint guides them to the correct iOS Settings path, which is always displayed in the current system language by iOS itself.

#### File 4: `odoo/Resources/zh-Hant.lproj/Localizable.strings`

Add:
```
/* Language */
"language" = "Language";
"language_change_hint" = "Change language in Settings -> odoo -> Language";
```

#### File 5 (optional): Localize the hint properly

If we want the hint fully localized:

- en: `"language_change_hint" = "Change language in Settings -> odoo -> Language";`
- zh-Hans: `"language_change_hint" = "Settings -> odoo -> Language";`
- zh-Hant: `"language_change_hint" = "Settings -> odoo -> Language";`

Decision: Keep English for the path portion since the Settings app labels appear in the user's system language anyway. Only localize the verb portion if desired.

### Unit Test

File: `odooTests/UI/Settings/SettingsViewLanguageTests.swift`

```swift
import XCTest
@testable import odoo

final class SettingsViewLanguageTests: XCTestCase {
    func testOpenSettingsURLStringIsValid() {
        // Verify the URL string used to open iOS Settings is non-nil
        let url = URL(string: UIApplication.openSettingsURLString)
        XCTAssertNotNil(url)
    }
}
```

### Commit Message

```
feat(settings): add Language section with link to iOS system language settings (G1)

Adds a Language row to SettingsView that shows the current app language
and opens iOS Settings -> odoo -> Language when tapped. Uses
Bundle.main.preferredLocalizations as the source of truth for the
current language, following Apple's per-app language design (iOS 16+).

Closes G1 (UX-58, UX-59).
```

---

## Work Item 2: G6 -- Reduce Motion Toggle (P2, 1h)

### Problem

`AppSettings.reduceMotion` field exists and defaults to `false`, but no toggle is exposed in the UI. Android has this in the Appearance section (SettingsViewModel.kt line 38: `updateReduceMotion`).

### Current State

- `AppSettings.swift` line 8: `var reduceMotion: Bool = false` -- field exists.
- `SettingsViewModel.swift` -- no `toggleReduceMotion` method.
- `SettingsView.swift` Appearance section -- no Reduce Motion toggle.
- `SettingsRepository.swift` (`SettingsRepositoryProtocol`) -- no `setReduceMotion` method.

### Implementation

#### File 1: `odoo/Data/Repository/SettingsRepository.swift`

**Add to `SettingsRepositoryProtocol` (after `func setBiometric`):**

```swift
func setReduceMotion(_ enabled: Bool)
```

**Add to `SettingsRepository` class (after the `setBiometric` method):**

```swift
func setReduceMotion(_ enabled: Bool) {
    var settings = secureStorage.getSettings()
    settings.reduceMotion = enabled
    secureStorage.saveSettings(settings)
}
```

#### File 2: `odoo/UI/Settings/SettingsViewModel.swift`

**Add method (after `updateThemeMode`):**

```swift
func toggleReduceMotion(_ enabled: Bool) {
    settingsRepo.setReduceMotion(enabled)
    settings.reduceMotion = enabled
}
```

#### File 3: `odoo/UI/Settings/SettingsView.swift`

**Add inside the Appearance section, after the Theme Mode picker (after line 37):**

```swift
Toggle(isOn: Binding(
    get: { viewModel.settings.reduceMotion },
    set: { viewModel.toggleReduceMotion($0) }
)) {
    Label("Reduce Motion", systemImage: "figure.walk")
}
```

The `Label` uses `figure.walk` as a motion-related SF Symbol, matching the semantic meaning. Android uses a custom vector icon; SF Symbols provides an appropriate platform-native equivalent.

#### File 4: `odoo/Resources/en.lproj/Localizable.strings`

Add:
```
"reduce_motion" = "Reduce Motion";
"reduce_motion_subtitle" = "Minimize animations";
```

#### File 5: `odoo/Resources/zh-Hans.lproj/Localizable.strings`

Add:
```
"reduce_motion" = "Reduce Motion";
"reduce_motion_subtitle" = "Minimize animations";
```

#### File 6: `odoo/Resources/zh-Hant.lproj/Localizable.strings`

Add:
```
"reduce_motion" = "Reduce Motion";
"reduce_motion_subtitle" = "Minimize animations";
```

### Where the Setting Is Consumed

Any animation code in the app should check `settings.reduceMotion` to decide whether to apply transitions. This is outside the scope of this work item (the toggle itself is the gap), but document that any future animation should respect this flag:

```swift
// Example usage pattern in any View:
.animation(settings.reduceMotion ? nil : .default, value: someValue)
```

### Unit Test

File: `odooTests/UI/Settings/SettingsViewModelReduceMotionTests.swift`

```swift
import XCTest
@testable import odoo

final class SettingsViewModelReduceMotionTests: XCTestCase {

    func testGivenDefaultSettingsWhenToggleReduceMotionTrueThenSettingsUpdated() {
        let repo = MockSettingsRepository()
        let vm = SettingsViewModel(settingsRepo: repo)

        vm.toggleReduceMotion(true)

        XCTAssertTrue(vm.settings.reduceMotion)
    }

    func testGivenReduceMotionEnabledWhenToggleFalseThenSettingsUpdated() {
        let repo = MockSettingsRepository()
        var initial = AppSettings()
        initial.reduceMotion = true
        repo.stubbedSettings = initial
        let vm = SettingsViewModel(settingsRepo: repo)

        vm.toggleReduceMotion(false)

        XCTAssertFalse(vm.settings.reduceMotion)
    }
}
```

### Commit Message

```
feat(settings): add Reduce Motion toggle to Appearance section (G6)

Adds setReduceMotion to SettingsRepositoryProtocol and wires a Toggle
in SettingsView's Appearance section. The reduceMotion field already
existed in AppSettings; this commit exposes it in the UI.

Closes G6 (UX-57).
```

---

## Work Item 3: G5 -- About Section Incomplete (P3, 1.5h)

### Problem

The About section currently shows only the app version (SettingsView.swift lines 92-99). Android's About section (SettingsScreen.kt lines 268-298) includes:

1. **Visit Website** -- tappable link to `https://aiot.woowtech.io`
2. **Contact Us** -- tappable mailto link to `woowtech@designsmart.com.tw`
3. **App Version** -- version string (already exists)

Additionally, Android shows a copyright line below the About section (lines 303-308):
- `"(c) 2026 WoowTech"`

### Current State

- `SettingsView.swift` About section has only the version row.
- No website link, no contact email, no copyright text.

### Implementation

#### File 1: `odoo/UI/Settings/SettingsView.swift`

**Replace the entire About section (lines 92-99) with:**

```swift
// About
Section("About") {
    // Website link
    Button {
        if let url = URL(string: "https://aiot.woowtech.io") {
            UIApplication.shared.open(url)
        }
    } label: {
        HStack {
            Label("Visit Website", systemImage: "globe")
            Spacer()
            Text("aiot.woowtech.io")
                .foregroundStyle(.secondary)
                .font(.caption)
            Image(systemName: "arrow.up.forward")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
    .foregroundStyle(.primary)

    // Contact email
    Button {
        if let url = URL(string: "mailto:woowtech@designsmart.com.tw") {
            UIApplication.shared.open(url)
        }
    } label: {
        HStack {
            Label("Contact Us", systemImage: "envelope")
            Spacer()
            Text("woowtech@designsmart.com.tw")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
    .foregroundStyle(.primary)

    // App version (existing, unchanged)
    HStack {
        Label("App Version", systemImage: "info.circle")
        Spacer()
        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            .foregroundStyle(.secondary)
    }
}

// Copyright (below the Form, or as a Section footer)
Section {
    EmptyView()
} footer: {
    Text("\u{00A9} 2026 WoowTech")
        .frame(maxWidth: .infinity, alignment: .center)
}
```

**Alternative for the copyright:** If placing it outside `Form` is preferred, add it after the Form's closing brace as a standalone `Text` view. The `Section` footer approach keeps it inside the `Form` scroll area, which is more natural for SwiftUI `Form` layouts.

#### File 2: `odoo/Resources/en.lproj/Localizable.strings`

Add:
```
/* About */
"visit_website" = "Visit Website";
"contact_us" = "Contact Us";
"copyright" = "\U00A9 2026 WoowTech";
```

#### File 3: `odoo/Resources/zh-Hans.lproj/Localizable.strings`

Add:
```
/* About */
"visit_website" = "Visit Website";
"contact_us" = "Contact Us";
"copyright" = "\U00A9 2026 WoowTech";
```

#### File 4: `odoo/Resources/zh-Hant.lproj/Localizable.strings`

Add:
```
/* About */
"visit_website" = "Visit Website";
"contact_us" = "Contact Us";
"copyright" = "\U00A9 2026 WoowTech";
```

Note: Website name and copyright text are brand names and remain untranslated across all locales, matching Android behavior.

### Unit Test

File: `odooTests/UI/Settings/SettingsAboutSectionTests.swift`

```swift
import XCTest

final class SettingsAboutSectionTests: XCTestCase {

    func testWebsiteURLIsValid() {
        let url = URL(string: "https://aiot.woowtech.io")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "https")
    }

    func testContactEmailURLIsValid() {
        let url = URL(string: "mailto:woowtech@designsmart.com.tw")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "mailto")
    }
}
```

### Commit Message

```
feat(settings): add website link, contact email, and copyright to About section (G5)

Expands the About section with a tappable website row
(aiot.woowtech.io), a contact email row (mailto:), and a copyright
footer, matching Android's SettingsScreen layout.

Closes G5 (UX-47 partial).
```

---

## Work Item 4: G4 -- Help & Support Section (P3, 2h)

### Problem

The entire Help & Support section is missing from `SettingsView.swift`. Android (SettingsScreen.kt lines 247-263) shows:

1. **Odoo Help Center** -- links to `https://www.odoo.com/help` with subtitle "Official documentation and guides"
2. **Odoo Community Forum** -- links to `https://www.odoo.com/forum` with subtitle "Get help from the community"

Per UX-82 the section order must be: Appearance -> Security -> Language -> Data -> **Help** -> About.

### Current State

- `SettingsView.swift` has no Help & Support section.
- The section needs to be inserted between Data & Storage and About.

### Implementation

#### File 1: `odoo/UI/Settings/SettingsView.swift`

**Insert a new section between Data & Storage and About (after the Data & Storage section):**

```swift
// Help & Support
Section("Help & Support") {
    // Odoo Help Center
    Button {
        if let url = URL(string: "https://www.odoo.com/help") {
            UIApplication.shared.open(url)
        }
    } label: {
        HStack {
            Label("Odoo Help Center", systemImage: "questionmark.circle")
            Spacer()
            Image(systemName: "arrow.up.forward")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
    .foregroundStyle(.primary)

    // Odoo Community Forum
    Button {
        if let url = URL(string: "https://www.odoo.com/forum") {
            UIApplication.shared.open(url)
        }
    } label: {
        HStack {
            Label("Odoo Community Forum", systemImage: "bubble.left.and.bubble.right")
            Spacer()
            Image(systemName: "arrow.up.forward")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
    .foregroundStyle(.primary)
}
```

**SF Symbol mapping from Android Material Icons:**

| Android Icon | iOS SF Symbol | Rationale |
|---|---|---|
| `Icons.AutoMirrored.Filled.HelpCenter` | `questionmark.circle` | Standard help icon |
| `Icons.Default.Forum` | `bubble.left.and.bubble.right` | Forum/community discussion icon |
| `Icons.Default.Public` | `globe` | Website icon (used in About section) |
| `Icons.Default.Email` | `envelope` | Email icon (used in About section) |

#### File 2: `odoo/Resources/en.lproj/Localizable.strings`

Add:
```
/* Help & Support */
"help_support" = "Help & Support";
"odoo_help_center" = "Odoo Help Center";
"odoo_help_center_subtitle" = "Official documentation and guides";
"odoo_community_forum" = "Odoo Community Forum";
"odoo_community_forum_subtitle" = "Get help from the community";
```

#### File 3: `odoo/Resources/zh-Hans.lproj/Localizable.strings`

Add:
```
/* Help & Support */
"help_support" = "Help & Support";
"odoo_help_center" = "Odoo Help Center";
"odoo_help_center_subtitle" = "Official documentation and guides";
"odoo_community_forum" = "Odoo Community Forum";
"odoo_community_forum_subtitle" = "Get help from the community";
```

#### File 4: `odoo/Resources/zh-Hant.lproj/Localizable.strings`

Add:
```
/* Help & Support */
"help_support" = "Help & Support";
"odoo_help_center" = "Odoo Help Center";
"odoo_help_center_subtitle" = "Official documentation and guides";
"odoo_community_forum" = "Odoo Community Forum";
"odoo_community_forum_subtitle" = "Get help from the community";
```

Note: "Odoo Help Center" and "Odoo Community Forum" are official Odoo product names and stay in English across all locales, consistent with Android. The subtitles could be localized in a follow-up if needed.

### Unit Test

File: `odooTests/UI/Settings/SettingsHelpSectionTests.swift`

```swift
import XCTest

final class SettingsHelpSectionTests: XCTestCase {

    func testHelpCenterURLIsValid() {
        let url = URL(string: "https://www.odoo.com/help")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "www.odoo.com")
        XCTAssertEqual(url?.path, "/help")
    }

    func testCommunityForumURLIsValid() {
        let url = URL(string: "https://www.odoo.com/forum")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.host, "www.odoo.com")
        XCTAssertEqual(url?.path, "/forum")
    }
}
```

### Commit Message

```
feat(settings): add Help & Support section with help center and forum links (G4)

Adds a Help & Support section between Data & Storage and About,
containing links to Odoo Help Center and Odoo Community Forum.
Matches Android SettingsScreen section order (UX-82).

Closes G4 (UX-47 partial).
```

---

## Final SettingsView Section Order After All 4 Gaps

After implementing all four work items, the `SettingsView` `Form` will contain sections in this order:

```
1. Appearance         (Theme Color, Theme Mode, Reduce Motion)     <-- G6 adds toggle
2. Security           (App Lock, Biometric, PIN)
3. Language           (current language + link to iOS Settings)    <-- G1 adds section
4. Data & Storage     (Clear Cache)
5. Help & Support     (Help Center, Community Forum)              <-- G4 adds section
6. About              (Website, Contact, Version)                 <-- G5 expands section
7. Copyright footer   ("(c) 2026 WoowTech")                      <-- G5 adds footer
```

This matches UX-82 exactly: **Appearance -> Security -> Language -> Data -> Help -> About**.

---

## Files Modified Summary

| File | G1 | G6 | G5 | G4 |
|------|----|----|----|----|
| `odoo/UI/Settings/SettingsView.swift` | Y | Y | Y | Y |
| `odoo/UI/Settings/SettingsViewModel.swift` | -- | Y | -- | -- |
| `odoo/Data/Repository/SettingsRepository.swift` | -- | Y | -- | -- |
| `odoo/Resources/en.lproj/Localizable.strings` | Y | Y | Y | Y |
| `odoo/Resources/zh-Hans.lproj/Localizable.strings` | Y | Y | Y | Y |
| `odoo/Resources/zh-Hant.lproj/Localizable.strings` | Y | Y | Y | Y |

No new model fields needed -- `AppSettings.reduceMotion` and `AppSettings.language` already exist.

---

## Post-Implementation Checklist

- [x] Run full test suite — 230/230 pass
- [x] Update `functional-equivalence-matrix.md` — 82/82 DONE, 0 gaps
- [x] Verify section order matches UX-82: Appearance → Security → Language → Data → Help → About
- [ ] Manual verification on device: tap each new row, confirm navigation/action
- [ ] Test language section: confirm it opens iOS Settings app
- [ ] Test Reduce Motion toggle: confirm value persists across app restart
- [ ] Test About links: website opens Safari, email opens Mail
- [ ] Test Help links: both URLs open Safari

---

## Architect Review Fixes Applied

The following issues were identified during architect review and fixed during implementation:

| # | Issue | Fix Applied |
|---|-------|-------------|
| 1 | **Localization broken** — Swift used hardcoded English, Localizable.strings keys didn't match | Used exact English text as keys (SwiftUI auto-matches). Added real zh-Hans/zh-Hant translations. |
| 2 | **Missing ViewModel properties** — test plan referenced `websiteURL`, `helpURL`, `appVersion` that didn't exist | Added `appVersion` and `currentLanguageDisplayName` to SettingsViewModel. Extracted URLs to `SettingsConstants` enum. |
| 3 | **`currentLanguageDisplayName()` inconsistency** — returned English names instead of Chinese characters | Returns `繁體中文`/`简体中文` matching `AppLanguage.displayName` convention. |
| 4 | **VoiceOver inaccessible** — decorative arrow images not hidden | Added `.accessibilityHidden(true)` on all `arrow.up.forward` and `arrow.up.forward.app` images. |
| 5 | **No `setReduceMotion` in repository** — method missing from protocol and implementation | Added to `SettingsRepositoryProtocol` + `SettingsRepository`. |
| 6 | **URLs hardcoded in view** — not testable, no single source of truth | Extracted to `SettingsConstants` enum with `websiteURL`, `contactEmail`, `helpURL`, `forumURL`. |
| 7 | **CLAUDE.md missing localization rules** — no guidance on string handling | Added Localization Rules section + Production Checklist + Constants & Testability rules. |
| 8 | **`reduce_motion_subtitle` key unused** — defined in plan but never used in UI | Not added (no subtitle needed for a simple toggle). |

## Implementation Status

| Gap | Status | Commit |
|-----|--------|--------|
| G1 Language picker | **DONE** | `d42e6a6` |
| G6 Reduce Motion | **DONE** | `d42e6a6` |
| G5 About section | **DONE** | `d42e6a6` |
| G4 Help & Support | **DONE** | `d42e6a6` |
