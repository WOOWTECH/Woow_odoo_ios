# App Store Blockers B1-B5 -- Implementation Plan

**Date:** 2026-04-05
**Scope:** Five blockers that will cause App Store rejection or render the app non-functional
**Total Estimated Effort:** 10.5 hours
**Dependencies:** B3 and B1 are independent; B2 is independent; B4 unlocks all Config/Settings UX items; B5 depends on B4 being wired (so localized strings are reachable)

---

## Dependency Graph

```
B1 (PrivacyInfo)    ── independent, do first (30 min)
B3 (Info.plist)     ── independent, do first (15 min)
B2 (App Icon)       ── independent, do anytime (2 hr)
B4 (Config Wiring)  ── independent, but B5 should come after (4 hr)
B5 (Localization)   ── should come after B4 so all views are reachable (4 hr)
```

**Recommended order:** B3 -> B1 -> B2 -> B4 -> B5

---

## B1: PrivacyInfo.xcprivacy -- Privacy Manifest

**Effort:** 30 minutes
**Why it blocks:** Since Spring 2024, Apple rejects any binary that uses "required reason APIs" without a privacy manifest. The app uses `UserDefaults` (C617.1), `FileManager` file timestamps, and the Keychain -- all of which fall under Apple's required reason API categories.

### Files to Create

| File | Action |
|------|--------|
| `odoo/PrivacyInfo.xcprivacy` | **CREATE** |

### What the File Must Contain

Apple requires four top-level keys in the privacy manifest:

1. **`NSPrivacyTracking`** -- set to `false` (the app does not track users)
2. **`NSPrivacyTrackingDomains`** -- empty array (no tracking domains)
3. **`NSPrivacyCollectedDataTypes`** -- empty array (no data collected for tracking purposes; push token is functional, not tracking)
4. **`NSPrivacyAccessedAPITypes`** -- this is the critical section. Based on code analysis:

| API Category | Reason Code | Where Used |
|---|---|---|
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` (access info from same app) | `UserDefaults.standard` in `SettingsRepository`, `WoowTheme`, `DeepLinkManager` |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` (access file timestamps for app functionality) | `CacheService` calculates cache sizes via `FileManager` attributes |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `E174.1` (check available disk space) | `CacheService` displays storage info |

### Exact File Content

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>C617.1</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryDiskSpace</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>E174.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

### Post-Creation Steps

1. Open Xcode project
2. Drag `PrivacyInfo.xcprivacy` into the `odoo` target group
3. Verify it appears in **Build Phases > Copy Bundle Resources**
4. Archive and run `xcrun altool --validate-app` or upload to TestFlight to confirm no rejection

### Commit Message

```
feat: add PrivacyInfo.xcprivacy privacy manifest for App Store compliance

Declares UserDefaults, file timestamp, and disk space API usage reasons
required by Apple since Spring 2024. Without this file, App Store Connect
rejects the binary upload.
```

---

## B2: App Icon PNGs

**Effort:** 2 hours (design time + export + Xcode configuration)
**Why it blocks:** `Assets.xcassets/AppIcon.appiconset/Contents.json` defines three slots (light, dark, tinted) but contains zero PNG files. App Store requires a 1024x1024 app icon. TestFlight builds will show a blank grid icon.

### Files to Modify

| File | Action |
|------|--------|
| `odoo/Assets.xcassets/AppIcon.appiconset/appicon_light.png` | **CREATE** -- 1024x1024 PNG |
| `odoo/Assets.xcassets/AppIcon.appiconset/appicon_dark.png` | **CREATE** -- 1024x1024 PNG |
| `odoo/Assets.xcassets/AppIcon.appiconset/appicon_tinted.png` | **CREATE** -- 1024x1024 PNG |
| `odoo/Assets.xcassets/AppIcon.appiconset/Contents.json` | **MODIFY** -- add `"filename"` keys |

### Icon Specifications

**Minimum requirement (App Store submission):**
- 1 PNG file at exactly **1024x1024 pixels**
- Format: PNG, no alpha channel, sRGB color space
- No rounded corners (iOS applies the mask automatically)

**Full set for light/dark/tinted appearances (iOS 18+):**
- `appicon_light.png` -- 1024x1024, standard brand icon (WoowTech logo on brand blue)
- `appicon_dark.png` -- 1024x1024, dark variant (lighter logo on dark background)
- `appicon_tinted.png` -- 1024x1024, monochrome variant for tinted mode

### Source Material

The Android app has the brand icon at multiple densities:
- `/Users/alanlin/Woow_odoo_app/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` (192x192)
- `/Users/alanlin/Woow_odoo_app/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png` (192x192)

**Approach:** Take the Android `ic_launcher_foreground.png` (the foreground layer without the adaptive icon mask), upscale or re-export from the original vector/Figma source at 1024x1024. If no vector source exists, use the xxxhdpi (192px) as a reference and recreate at 1024px.

### Updated Contents.json

```json
{
  "images" : [
    {
      "filename" : "appicon_light.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "appicon_dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "appicon_tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

### Shortcut Option (Minimum Viable)

If dark and tinted variants are not ready, provide only the light icon. iOS will auto-derive dark/tinted versions. Update Contents.json to only include a `"filename"` on the first (universal) entry and leave the other two without `"filename"` keys -- Xcode will show warnings but the build will succeed.

### Validation

1. After adding PNGs, open `Assets.xcassets` in Xcode -- verify no yellow/red warnings on AppIcon
2. Build to a device or simulator -- verify the icon appears on the Home Screen
3. Archive -- verify App Store Connect does not return "Missing app icon" error

### Commit Message

```
feat: add app icon PNGs for light, dark, and tinted appearances

Provides 1024x1024 PNG icons required for App Store submission.
Contents.json updated with filename references for all three slots.
```

---

## B3: Missing Info.plist Keys

**Effort:** 15 minutes
**Why it blocks:** The app uses Face ID via `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` in `BiometricView.swift` line 102. Without `NSFaceIDUsageDescription`, iOS will crash the app when the biometric prompt triggers. Without `CFBundleLocalizations`, the per-app language setting will not appear in iOS Settings.

### Files to Modify

| File | Action |
|------|--------|
| `/Users/alanlin/Woow_odoo_ios/odoo/Info.plist` | **MODIFY** -- add 4 keys |

### Keys to Add

| Key | Value | Reason |
|-----|-------|--------|
| `NSFaceIDUsageDescription` | `"WoowTech Odoo uses Face ID to unlock the app securely."` | Required by Apple when calling Face ID APIs. App crashes without it. |
| `NSCameraUsageDescription` | `"WoowTech Odoo needs camera access for document scanning and file uploads within Odoo."` | WKWebView may request camera via `<input type="file" capture>`. Apple rejects apps that prompt for camera without a plist key. |
| `NSPhotoLibraryUsageDescription` | `"WoowTech Odoo needs photo library access to upload files and images to Odoo."` | WKWebView file upload can access the photo library. Same rejection risk as camera. |
| `CFBundleLocalizations` | `["en", "zh-Hans", "zh-Hant"]` | Required for iOS 13+ per-app language settings. Without this, the Language option does not appear in iOS Settings > WoowTech Odoo. Must match the `.lproj` directories that exist. |

### Exact Code Change

**Current** `Info.plist` (lines 1-22):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>UIBackgroundModes</key>
	<array>
		<string>remote-notification</string>
	</array>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>io.woowtech.odoo</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>woowodoo</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

**Updated** `Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>UIBackgroundModes</key>
	<array>
		<string>remote-notification</string>
	</array>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>io.woowtech.odoo</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>woowodoo</string>
			</array>
		</dict>
	</array>
	<key>NSFaceIDUsageDescription</key>
	<string>WoowTech Odoo uses Face ID to unlock the app securely.</string>
	<key>NSCameraUsageDescription</key>
	<string>WoowTech Odoo needs camera access for document scanning and file uploads within Odoo.</string>
	<key>NSPhotoLibraryUsageDescription</key>
	<string>WoowTech Odoo needs photo library access to upload files and images to Odoo.</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>zh-Hans</string>
		<string>zh-Hant</string>
	</array>
</dict>
</plist>
```

### Validation

1. Build and run on a device with Face ID -- verify the system prompt shows the custom usage description
2. Open iOS Settings > Apps > WoowTech Odoo -- verify "Language" row appears with en, Simplified Chinese, Traditional Chinese
3. Trigger file upload in WKWebView -- verify camera/photo library prompts show the custom descriptions

### Commit Message

```
fix: add required Info.plist keys for Face ID, camera, photos, and localization

Adds NSFaceIDUsageDescription (prevents crash on biometric prompt),
NSCameraUsageDescription and NSPhotoLibraryUsageDescription (required
for WKWebView file uploads), and CFBundleLocalizations (enables per-app
language switching in iOS Settings).
```

---

## B4: Config Screen Wiring -- THE BIGGEST BLOCKER

**Effort:** 4 hours
**Why it blocks:** The hamburger menu button in `MainView` calls `onMenuClick` which is an empty closure in `odooApp.swift` line 77-78. `ConfigView` and `SettingsView` are fully built but completely unreachable. This means:
- Users cannot access Settings (theme, security, language, cache, about)
- Users cannot switch accounts
- Users cannot add accounts
- Users cannot log out (except by clearing app data)
- **22 UX items in the functional-equivalence matrix are marked DONE but are actually unreachable**

### Android Reference

The Android app handles this navigation cleanly in `NavGraph.kt`:

```kotlin
// MainScreen -> Config (line 114-119)
composable(Screen.Main.route) {
    MainScreen(
        onMenuClick = {
            navController.navigate(Screen.Config.route)
        }
    )
}

// Config -> Settings (line 122-135)
composable(Screen.Config.route) {
    ConfigScreen(
        onBackClick = { navController.popBackStack() },
        onSettingsClick = { navController.navigate(Screen.Settings.route) },
        onAddAccountClick = { navController.navigate(Screen.Login.route) },
        onLogout = {
            navController.navigate(Screen.Login.route) {
                popUpTo(Screen.Main.route) { inclusive = true }
            }
        }
    )
}

// Settings -> back (line 137-141)
composable(Screen.Settings.route) {
    SettingsScreen(
        onBackClick = { navController.popBackStack() }
    )
}
```

### iOS Navigation Approach Decision

**Option A: `.sheet` presentation (RECOMMENDED)**
- Config slides up as a modal sheet from MainView
- Settings pushes inside the sheet's NavigationStack
- Matches iOS conventions for "settings/config" screens
- Does not interfere with MainView's existing NavigationStack
- Back button in Config dismisses the sheet
- Back button in Settings pops within the sheet's NavigationStack

**Option B: NavigationStack push**
- Config pushes onto MainView's existing NavigationStack
- Requires modifying MainView's NavigationStack to accept navigation destinations
- More complex because MainView's NavigationStack is tightly coupled to the WebView toolbar

**Option C: `fullScreenCover`**
- Config takes over the entire screen
- Feels heavy for a config/settings screen
- Not recommended

**Decision: Option A (`.sheet`)** -- cleanest separation, matches iOS HIG for config panels, minimal changes to existing MainView.

### Files to Modify

| File | Action | Changes |
|------|--------|---------|
| `/Users/alanlin/Woow_odoo_ios/odoo/odooApp.swift` | **MODIFY** | Wire `onMenuClick`, add `showConfig` state, present ConfigView as sheet, handle logout/add-account flows |
| `/Users/alanlin/Woow_odoo_ios/odoo/UI/Config/ConfigView.swift` | **MODIFY** | Wrap content in NavigationStack (for sheet presentation), add navigation to SettingsView |
| `/Users/alanlin/Woow_odoo_ios/odoo/UI/Main/MainView.swift` | **NO CHANGE** | Already passes `onMenuClick` closure correctly |
| `/Users/alanlin/Woow_odoo_ios/odoo/UI/Settings/SettingsView.swift` | **NO CHANGE** | Already has `onBackClick` callback |

### Code Change 1: `odooApp.swift` -- AppRootView

Add `@State private var showConfig = false` and wire the closure:

```swift
struct AppRootView: View {
    @StateObject private var rootViewModel = AppRootViewModel()
    @StateObject private var authViewModel = AuthViewModel()
    @State private var showPin = false
    @State private var showConfig = false                    // NEW
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch rootViewModel.launchState {
            case .loading:
                ProgressView()
            case .login:
                LoginView(onLoginSuccess: {
                    rootViewModel.onLoginSuccess()
                    if !authViewModel.requiresAuth {
                        authViewModel.setAuthenticated(true)
                    }
                })
            case .authenticated:
                if authViewModel.requiresAuth && !authViewModel.isAuthenticated {
                    if showPin {
                        PinView(
                            authViewModel: authViewModel,
                            onPinVerified: { showPin = false },
                            onBackClick: { showPin = false }
                        )
                    } else {
                        BiometricView(
                            authViewModel: authViewModel,
                            onAuthSuccess: {},
                            onUsePinClick: { showPin = true }
                        )
                    }
                } else {
                    MainView(
                        onMenuClick: {
                            showConfig = true                // CHANGED: was empty
                        },
                        onSessionExpired: {
                            rootViewModel.onSessionExpired()
                            authViewModel.setAuthenticated(false)
                        }
                    )
                    .sheet(isPresented: $showConfig) {       // NEW: present Config
                        ConfigView(
                            onBackClick: {
                                showConfig = false
                            },
                            onSettingsClick: {
                                // Navigation handled inside ConfigView
                            },
                            onAddAccountClick: {
                                showConfig = false
                                rootViewModel.onSessionExpired()  // go to login
                            },
                            onLogout: {
                                showConfig = false
                                rootViewModel.onSessionExpired()
                                authViewModel.setAuthenticated(false)
                            }
                        )
                    }
                }
            }
        }
        .task {
            rootViewModel.checkSession()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background {
                authViewModel.onAppBackgrounded()
                showPin = false
            }
        }
    }
}
```

### Code Change 2: `ConfigView.swift` -- Add NavigationStack + Settings Navigation

The current `ConfigView` uses `.navigationTitle` and `.toolbar` but is not wrapped in a `NavigationStack`. When presented as a `.sheet`, it needs its own `NavigationStack`. Additionally, the `onSettingsClick` callback should push `SettingsView` within this NavigationStack rather than delegating upward.

```swift
import SwiftUI

/// Config screen -- account list, switch, add, logout.
/// UX-67 through UX-70.
struct ConfigView: View {
    @StateObject private var viewModel = ConfigViewModel()
    let onBackClick: () -> Void
    let onSettingsClick: () -> Void
    let onAddAccountClick: () -> Void
    let onLogout: () -> Void

    @State private var showLogoutAlert = false
    @State private var showSettings = false                   // NEW

    var body: some View {
        NavigationStack {                                      // NEW: wrap in NavigationStack
            List {
                // Active account
                if let account = viewModel.activeAccount {
                    Section {
                        HStack(spacing: 12) {
                            Text(String(account.displayName.prefix(1)).uppercased())
                                .font(.title2).fontWeight(.bold)
                                .frame(width: 50, height: 50)
                                .background(WoowColors.primaryBlue.opacity(0.2))
                                .clipShape(Circle())
                            VStack(alignment: .leading) {
                                Text(account.displayName).font(.headline)
                                Text(account.username).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Settings
                Section {
                    Button {
                        showSettings = true                    // CHANGED: navigate instead of callback
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                // Other accounts
                if viewModel.accounts.count > 1 {
                    Section("Switch Account") {
                        ForEach(viewModel.accounts.filter { !$0.isActive }) { account in
                            Button {
                                Task { _ = await viewModel.switchAccount(id: account.id) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(account.displayName)
                                    Text(account.serverUrl).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Add account
                Section {
                    Button { onAddAccountClick() } label: {
                        Label("Add Account", systemImage: "plus.circle")
                    }
                }

                // Logout
                Section {
                    Button(role: .destructive) { showLogoutAlert = true } label: {
                        Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Configuration")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBackClick) {
                        Image(systemName: "xmark")            // CHANGED: X for sheet dismiss
                    }
                }
            }
            .alert("Logout", isPresented: $showLogoutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Logout", role: .destructive) {
                    Task {
                        await viewModel.logout()
                        onLogout()
                    }
                }
            } message: {
                Text("Are you sure you want to logout?")
            }
            .onAppear { viewModel.loadAccounts() }
            .navigationDestination(isPresented: $showSettings) {  // NEW
                SettingsView(onBackClick: { showSettings = false })
            }
        }
    }
}
```

### Navigation Flow Summary

```
MainView
  |-- [hamburger button tap]
  |-- .sheet -> ConfigView (in its own NavigationStack)
       |-- [Settings tap]
       |-- .navigationDestination -> SettingsView (pushes in sheet's nav stack)
       |     |-- [back] -> pops to ConfigView
       |-- [Add Account tap]
       |-- dismiss sheet -> navigate to LoginView
       |-- [Logout tap]
       |-- alert -> dismiss sheet -> navigate to LoginView
       |-- [X button tap]
       |-- dismiss sheet -> return to MainView
```

### What About Account Switching?

When the user taps a different account in ConfigView, `viewModel.switchAccount(id:)` is called. After switching, the sheet should dismiss and MainView should reload with the new account's WebView. This requires:

1. After `switchAccount` returns `true`, dismiss the config sheet
2. `MainView.onAppear` already calls `viewModel.loadActiveAccount()` -- but `.onAppear` only fires once. Need to trigger a reload.

**Solution:** Add an `onAccountSwitched` callback that dismisses the sheet. MainView should observe the active account change. The simplest approach: have `switchAccount` dismiss the sheet, then use `MainViewModel`'s `loadActiveAccount()` triggered by the reappearance.

Updated account switch button in ConfigView:

```swift
Button {
    Task {
        let success = await viewModel.switchAccount(id: account.id)
        if success {
            onBackClick()  // dismiss sheet, MainView reloads
        }
    }
} label: { /* ... */ }
```

And in MainView, change `.onAppear` to observe the sheet dismissal:

```swift
// In MainView, add:
.onChange(of: /* some trigger */) { _ in
    viewModel.loadActiveAccount()
}
```

Or more simply, move `loadActiveAccount()` to `.task` which re-runs when view identity changes, or use `.onAppear` which will fire when the sheet is dismissed and MainView reappears.

**Note:** `.onAppear` in SwiftUI fires when the view appears, including when a sheet is dismissed. So the existing `.onAppear { viewModel.loadActiveAccount() }` in MainView line 51 should already handle this. Verify during testing.

### Validation

1. Build and run -- tap hamburger menu -- ConfigView appears as a sheet
2. Tap Settings -- SettingsView pushes within the sheet
3. Tap back in Settings -- pops to ConfigView
4. Tap X in ConfigView -- sheet dismisses, MainView visible
5. Tap Add Account -- sheet dismisses, LoginView appears
6. Tap Logout -- alert appears, confirm -> sheet dismisses, LoginView appears
7. If multiple accounts: tap another account -- sheet dismisses, WebView reloads with new account

### Commit Message

```
feat: wire Config screen navigation from MainView hamburger menu

Presents ConfigView as a .sheet from MainView when the hamburger menu
button is tapped. ConfigView wraps itself in a NavigationStack and
pushes SettingsView via .navigationDestination. Logout and Add Account
dismiss the sheet and navigate to LoginView. This unblocks 22 UX items
(UX-30, UX-47-57, UX-63-66, UX-67-70) that were previously unreachable.
```

---

## B5: Localizable.strings Not Referenced -- Wiring Localization

**Effort:** 4 hours
**Why it blocks:** Three `Localizable.strings` files exist with 67 keys across en/zh-Hans/zh-Hant. Zero of these keys are referenced from Swift code. Every displayed string is a hardcoded English literal. The language switching feature (UX-58 through UX-62) is completely broken.

### How SwiftUI Localization Works

In SwiftUI, `Text("someString")` automatically looks up `"someString"` as a key in `Localizable.strings`. **However**, this only works when the string literal exactly matches a key in the `.strings` file. The current code has a mismatch problem:

**Some strings already match keys** (because the key IS the English text):
- `Text("Language")` will match `"Language" = "Language"` in en.lproj
- `Text("Change language in iOS Settings")` will match its key
- `Text("Reduce Motion")` will match its key

**Most strings do NOT match keys** (because keys use snake_case):
- `Text("Settings")` does NOT match `"settings"` (case-sensitive)
- `Text("Server URL")` does NOT match `"server_url"`
- `Text("Login")` does NOT match `"login_button"`

### Strategy

There are two approaches:

**Approach A: Change keys in .strings files to match hardcoded text** -- Less code changes but messy keys (mixed case, spaces in keys).

**Approach B: Replace hardcoded strings with `String(localized:)` referencing existing snake_case keys** -- More code changes but clean, consistent key naming. This is the standard iOS approach.

**Decision: Approach B** -- Use `String(localized:)` for programmatic strings (ViewModel errors) and rely on SwiftUI's automatic lookup for `Text()` / `Label()` / `Section()` by changing keys to match exactly. Actually, the cleanest approach is a hybrid:

1. For `Text()`, `Label()`, `Section()`, `Button()`, `Toggle()`, `Picker()`, `.navigationTitle()`, `.alert()` -- these all accept `LocalizedStringKey` automatically. Change the **keys in the .strings files** to match the English text exactly (e.g., change `"settings"` to `"Settings"`, `"server_url"` to `"Server URL"`).

2. For ViewModel error strings (not in a SwiftUI initializer) -- use `String(localized:)` with the matching key.

3. For interpolated strings like `"Wrong PIN. \(remaining) attempts remaining"` -- use `String(localized:)` with a format key, or add new keys.

### Files to Modify

| File | Action | Type of Change |
|------|--------|---------------|
| `odoo/Resources/en.lproj/Localizable.strings` | **MODIFY** | Rename keys to match English text; add missing keys |
| `odoo/Resources/zh-Hans.lproj/Localizable.strings` | **MODIFY** | Same key renames; add missing keys with Chinese translations |
| `odoo/Resources/zh-Hant.lproj/Localizable.strings` | **MODIFY** | Same key renames; add missing keys with Chinese translations |
| `odoo/UI/Login/LoginView.swift` | **MODIFY** | Fix `Text("Enter server details")` etc. to use keys that exist |
| `odoo/UI/Login/LoginViewModel.swift` | **MODIFY** | Replace hardcoded error strings with `String(localized:)` |
| `odoo/UI/Auth/BiometricView.swift` | **MODIFY** | Replace hardcoded strings with localized keys |
| `odoo/UI/Auth/PinView.swift` | **MODIFY** | Replace hardcoded strings with localized keys |
| `odoo/UI/Config/ConfigView.swift` | **MODIFY** | Strings already match some keys; verify all |
| `odoo/UI/Settings/SettingsView.swift` | **MODIFY** | Some strings match keys; verify all |
| `odoo/UI/Settings/ColorPickerView.swift` | **MODIFY** | Replace hardcoded strings |
| `odoo/UI/Settings/PinSetupView.swift` | **MODIFY** | Replace hardcoded strings |
| `odoo/UI/Main/MainView.swift` | **MODIFY** | `Text("WoowTech Odoo")` -- add key or keep as brand name |

### Complete String Audit

Below is every hardcoded user-visible string, the file it appears in, and the action required.

#### LoginView.swift

| Line | Current Code | Existing Key | Action |
|------|-------------|-------------|--------|
| 23 | `Text("WoowTech Odoo")` | `"app_name"` | Change to `Text(String(localized: "app_name"))` or add key `"WoowTech Odoo"` |
| 27 | `Text("Enter server details")` / `Text("Enter credentials")` | NONE | Add keys `"enter_server_details"` / `"enter_credentials"` |
| 57 | `ProgressView("Connecting...")` | NONE | Add key `"connecting"` |
| 71 | `Text("Server URL")` | `"server_url"` | Rename key to `"Server URL"` OR use `Text(String(localized: "server_url"))` |
| 75 | `Text("https://")` | N/A | Keep as-is (protocol prefix, not translatable) |
| 77 | `TextField("example.odoo.com", ...)` | N/A | Keep as-is (placeholder example) |
| 89 | `Text("Database")` | `"database_name"` | Rename key to `"Database"` |
| 92 | `TextField("Enter database name", ...)` | NONE | Add key `"enter_database_name"` |
| 102 | `Text("Next")` | `"next_button"` | Rename key to `"Next"` |
| 129 | `Button("Change")` | NONE | Add key `"Change"` |
| 139 | `Text("Username")` | `"username"` | Rename key to `"Username"` |
| 142 | `TextField("Username or email", ...)` | NONE | Add key `"username_placeholder"` |
| 152 | `Text("Password")` | `"password"` | Rename key to `"Password"` |
| 155 | `SecureField("Enter password", ...)` | NONE | Add key `"enter_password"` |
| 166 | `Text("Login")` | `"login_button"` | Rename key to `"Login"` |
| 175 | `Button("Back")` | NONE | Add key `"Back"` |

#### LoginViewModel.swift (error strings -- need `String(localized:)`)

| Line | Current String | Action |
|------|---------------|--------|
| 60 | `"Server URL is required"` | Add key, use `String(localized: "error_server_url_required")` |
| 65 | `"Database name is required"` | Add key, use `String(localized: "error_database_required")` |
| 71 | `"HTTPS connection required"` | Add key, use `String(localized: "error_https_required")` |
| 93 | `"Username is required"` | Add key, use `String(localized: "error_username_required")` |
| 97 | `"Password is required"` | Add key, use `String(localized: "error_password_required")` |
| 130 | `"Unable to connect to server"` | Add key `"error_network"` |
| 131 | `"Invalid server URL"` | Add key `"error_invalid_url"` |
| 132 | `"Database not found"` | Add key `"error_database_not_found"` |
| 133 | `"Invalid username or password"` | Add key `"error_invalid_credentials"` |
| 134 | `"Session expired, please login again"` | Add key `"error_session_expired"` |
| 135 | `"HTTPS connection required"` | Reuse `"error_https_required"` |
| 136 | `"Server error: \(message)"` | Add key `"error_server"` with format |

#### BiometricView.swift

| Line | Current Code | Existing Key | Action |
|------|-------------|-------------|--------|
| 26 | `Text("Biometric Login")` | `"biometric_title"` | Rename key to `"Biometric Login"` |
| 30 | `Text("Use Face ID or Touch ID to unlock")` | `"biometric_subtitle"` | Rename key to `"Use Face ID or Touch ID to unlock"` |
| 52 | `Text("Unlock with \(biometricName)")` | NONE | Add key `"unlock_with_%@"`, use `String(localized: "unlock_with_\(biometricName)")` or `Text("Unlock with \(biometricName)")` with a parameterized key |
| 63 | `Button("Use PIN")` | `"use_pin"` | Rename key to `"Use PIN"` |
| 96 | `errorMessage = "Biometric authentication not available"` | NONE | Add key, use `String(localized:)` |
| 104 | `localizedReason: "Unlock WoowTech Odoo"` | NONE | Add key `"biometric_reason"` |
| 118 | `"Too many attempts. Use PIN instead."` | NONE | Add key |
| 121 | `"Authentication failed. Try again."` | NONE | Add key |

#### PinView.swift

| Line | Current Code | Existing Key | Action |
|------|-------------|-------------|--------|
| 33 | `Text("Enter PIN")` | `"enter_pin"` | Rename key to `"Enter PIN"` |
| 37 | `Text("Enter your PIN to unlock")` | NONE | Add key `"enter_pin_subtitle"` |
| 68 | `Text("Try again in \(remaining)s")` | NONE | Add key with format |
| 151 | `"Wrong PIN. \(remaining) attempts remaining"` | NONE | Add key with format |

#### ConfigView.swift

| Line | Current Code | Existing Key | Action |
|------|-------------|-------------|--------|
| 36 | `Label("Settings", ...)` | Has key `"Settings"` in SettingsView set | Rename `"settings"` -> `"Settings"` |
| 42 | `Section("Switch Account")` | `"switch_accounts"` | Rename to `"Switch Account"` |
| 59 | `Label("Add Account", ...)` | `"add_account"` | Rename to `"Add Account"` |
| 66 | `Label("Logout", ...)` | `"logout"` | Rename to `"Logout"` |
| 70 | `.navigationTitle("Configuration")` | `"configuration"` | Rename to `"Configuration"` |
| 78 | `.alert("Logout", ...)` | Reuse `"Logout"` | Already handled |
| 79 | `Button("Cancel", ...)` | `"cancel"` | Rename to `"Cancel"` |
| 87 | `Text("Are you sure you want to logout?")` | NONE | Add key `"logout_confirm_message"` |

#### SettingsView.swift

| Line | Current Code | Existing Key Match? | Action |
|------|-------------|-------------------|--------|
| 16 | `Section("Appearance")` | `"appearance"` | Rename to `"Appearance"` |
| 22 | `Label("Theme Color", ...)` | `"theme_color"` | Rename to `"Theme Color"` |
| 30 | `Picker("Theme Mode", ...)` | `"theme_mode"` | Rename to `"Theme Mode"` |
| 34-36 | `Text("System")`, `Text("Light")`, `Text("Dark")` | NONE | Add keys `"System"`, `"Light"`, `"Dark"` |
| 47 | `Section("Security")` | `"security"` | Rename to `"Security"` |
| 48 | `Toggle("App Lock", ...)` | `"app_lock"` | Rename to `"App Lock"` |
| 54 | `Toggle("Biometric Unlock", ...)` | `"biometric_unlock"` | Rename to `"Biometric Unlock"` |
| 63 | `Label("PIN Code", ...)` | `"pin_code"` | Rename to `"PIN Code"` |
| 65 | `Text("Change PIN")` / `Text("Set PIN")` | NONE | Add keys `"Change PIN"` and `"Set PIN"` |
| 76 | `Label("Remove PIN", ...)` | NONE | Add key `"Remove PIN"` |
| 109 | `Section("Data & Storage")` | `"data_storage"` | Rename to `"Data & Storage"` |
| 114 | `Label("Clear Cache", ...)` | `"clear_cache"` | Rename to `"Clear Cache"` |
| 159 | `Section("About")` | `"about"` | Rename to `"About"` |
| 161 | `Label("App Version", ...)` | `"app_version"` | Rename to `"App Version"` |
| 201 | `Text("\u{00A9} 2026 WoowTech")` | N/A | Keep as-is (copyright, not translatable) |
| 207 | `.navigationTitle("Settings")` | `"settings"` | Rename to `"Settings"` |

#### ColorPickerView.swift

| Line | Current Code | Existing Key | Action |
|------|-------------|-------------|--------|
| 18 | `Text("Preset Colors")` | `"preset_colors"` | Rename to `"Preset Colors"` |
| 27 | `Text("Accent")` | NONE | Add key `"Accent"` |
| 35 | `Text("Custom Color")` | `"custom_color"` | Rename to `"Custom Color"` |
| 57 | `.navigationTitle("Select Color")` | `"select_color"` | Rename to `"Select Color"` |
| 61 | `Button("Cancel")` | `"cancel"` -> `"Cancel"` | Already handled |
| 64 | `Button("Apply")` | `"apply"` | Rename to `"Apply"` |

#### PinSetupView.swift

| Line | Current Code | Action |
|------|-------------|--------|
| 63 | `"Change PIN"` / `"Set PIN"` | Reuse keys from SettingsView |
| 67 | `Button("Cancel", ...)` | Reuse `"Cancel"` |
| 75 | `"Enter Current PIN"` | Add key |
| 76 | `"Enter New PIN"` | Add key |
| 77 | `"Confirm New PIN"` | Add key |
| 140 | `"Incorrect PIN"` | Add key |
| 151 | `"PINs don't match"` | Add key |

#### MainView.swift

| Line | Current Code | Action |
|------|-------------|--------|
| 37 | `Text("WoowTech Odoo")` | Brand name -- keep as-is or use `"app_name"` key renamed to `"WoowTech Odoo"` |

### Updated Localizable.strings (en.lproj) -- Complete Replacement

Below is the full updated `en.lproj/Localizable.strings` with all keys renamed to match the exact English text used in SwiftUI views (enabling automatic `LocalizedStringKey` lookup), plus new keys for error messages and missing strings:

```
/* App */
"WoowTech Odoo" = "WoowTech Odoo";

/* Login */
"Add New Account" = "Add New Account";
"Server URL" = "Server URL";
"Database" = "Database";
"Username" = "Username";
"Password" = "Password";
"Login" = "Login";
"Next" = "Next";
"Back" = "Back";
"Change" = "Change";
"Enter server details" = "Enter server details";
"Enter credentials" = "Enter credentials";
"Connecting..." = "Connecting...";
"enter_database_name" = "Enter database name";
"username_placeholder" = "Username or email";
"enter_password" = "Enter password";

/* Login Errors */
"error_server_url_required" = "Server URL is required";
"error_database_required" = "Database name is required";
"error_https_required" = "HTTPS connection required";
"error_username_required" = "Username is required";
"error_password_required" = "Password is required";
"error_network" = "Unable to connect to server";
"error_invalid_url" = "Invalid server URL";
"error_database_not_found" = "Database not found";
"error_invalid_credentials" = "Invalid username or password";
"error_session_expired" = "Session expired, please login again";
"error_server_%@" = "Server error: %@";

/* Auth -- Biometric */
"Biometric Login" = "Biometric Login";
"Use Face ID or Touch ID to unlock" = "Use Face ID or Touch ID to unlock";
"Unlock with %@" = "Unlock with %@";
"Use PIN" = "Use PIN";
"biometric_reason" = "Unlock WoowTech Odoo";
"error_biometric_unavailable" = "Biometric authentication not available";
"error_biometric_lockout" = "Too many attempts. Use PIN instead.";
"error_biometric_failed" = "Authentication failed. Try again.";

/* Auth -- PIN */
"Enter PIN" = "Enter PIN";
"Enter your PIN to unlock" = "Enter your PIN to unlock";
"lockout_timer_%lld" = "Try again in %llds";
"wrong_pin_%lld" = "Wrong PIN. %lld attempts remaining";

/* Config */
"Configuration" = "Configuration";
"Switch Account" = "Switch Account";
"Add Account" = "Add Account";
"Logout" = "Logout";
"Cancel" = "Cancel";
"Confirm" = "Confirm";
"logout_confirm_message" = "Are you sure you want to logout?";

/* Settings */
"Settings" = "Settings";
"Appearance" = "Appearance";
"Theme Color" = "Theme Color";
"Theme Mode" = "Theme Mode";
"System" = "System";
"Light" = "Light";
"Dark" = "Dark";
"Security" = "Security";
"App Lock" = "App Lock";
"Biometric Unlock" = "Biometric Unlock";
"PIN Code" = "PIN Code";
"Change PIN" = "Change PIN";
"Set PIN" = "Set PIN";
"Remove PIN" = "Remove PIN";
"Data & Storage" = "Data & Storage";
"Clear Cache" = "Clear Cache";
"About" = "About";
"App Version" = "App Version";
"Reduce Motion" = "Reduce Motion";

/* Settings -- Language */
"Language" = "Language";
"Change language in iOS Settings" = "Change language in iOS Settings";

/* Settings -- Help & Support */
"Help & Support" = "Help & Support";
"Odoo Help Center" = "Odoo Help Center";
"Community Forum" = "Community Forum";

/* Settings -- About */
"Visit Website" = "Visit Website";
"Contact Us" = "Contact Us";

/* Color Picker */
"Select Color" = "Select Color";
"Preset Colors" = "Preset Colors";
"Accent" = "Accent";
"Custom Color" = "Custom Color";
"Apply" = "Apply";

/* PIN Setup */
"Enter Current PIN" = "Enter Current PIN";
"Enter New PIN" = "Enter New PIN";
"Confirm New PIN" = "Confirm New PIN";
"Incorrect PIN" = "Incorrect PIN";
"PINs don't match" = "PINs don't match";

/* Cache */
"cache_cleared" = "Cache cleared";

/* Notifications */
"notification_channel_messages" = "Odoo Messages";
```

### Swift Code Changes Required

For most `Text()`, `Label()`, `Section()`, `Button()`, `Toggle()`, `Picker()`, `.navigationTitle()`, and `.alert()` calls -- **no code change needed** because SwiftUI automatically treats string literals as `LocalizedStringKey` and looks them up. Once the .strings keys match the English text, localization kicks in automatically.

**Code changes are only needed for:**

1. **ViewModel error strings** -- these are `String` assignments, not `Text()`. Must use `String(localized:)`.

2. **Interpolated strings** -- `Text("Unlock with \(biometricName)")` works with SwiftUI's `LocalizedStringKey` interpolation IF the key format matches. Need to use the `"Unlock with %@"` pattern.

3. **TextField/SecureField placeholders** -- these also accept `LocalizedStringKey` automatically.

#### LoginViewModel.swift changes

```swift
// Replace all hardcoded error strings:
error = String(localized: "error_server_url_required")
error = String(localized: "error_database_required")
error = String(localized: "error_https_required")
error = String(localized: "error_username_required")
error = String(localized: "error_password_required")

// In mapError():
case .networkError: return String(localized: "error_network")
case .invalidUrl: return String(localized: "error_invalid_url")
case .databaseNotFound: return String(localized: "error_database_not_found")
case .invalidCredentials: return String(localized: "error_invalid_credentials")
case .sessionExpired: return String(localized: "error_session_expired")
case .httpsRequired: return String(localized: "error_https_required")
case .serverError: return String(format: String(localized: "error_server_%@"), message)
case .unknown: return message
```

#### BiometricView.swift changes

```swift
// Line 96:
errorMessage = String(localized: "error_biometric_unavailable")

// Line 104:
localizedReason: String(localized: "biometric_reason")

// Line 118:
errorMessage = String(localized: "error_biometric_lockout")

// Line 121:
errorMessage = String(localized: "error_biometric_failed")

// Line 52: SwiftUI interpolation handles this automatically with key "Unlock with %@"
Text("Unlock with \(biometricName)")
```

#### PinView.swift changes

```swift
// Line 68: Need special handling for interpolated lockout timer
Text("lockout_timer_\(remaining)")
// Actually, use String(format:) approach:
Text(String(format: String(localized: "lockout_timer_%lld"), remaining))

// Line 151:
error = String(format: String(localized: "wrong_pin_%lld"), remaining)
```

#### PinSetupView.swift changes

```swift
// Line 140:
error = String(localized: "Incorrect PIN")

// Line 151:
error = String(localized: "PINs don't match")
```

### zh-Hans and zh-Hant Updates

Both Chinese locale files need the same key renames plus translations for all new keys. Here are the new keys that need translations:

| Key | zh-Hans | zh-Hant |
|-----|---------|---------|
| `"Enter server details"` | `"输入服务器信息"` | `"輸入伺服器資訊"` |
| `"Enter credentials"` | `"输入登录凭据"` | `"輸入登入憑據"` |
| `"Connecting..."` | `"连接中..."` | `"連線中..."` |
| `"Back"` | `"返回"` | `"返回"` |
| `"Change"` | `"更改"` | `"變更"` |
| `"error_server_url_required"` | `"服务器网址为必填项"` | `"伺服器網址為必填項"` |
| `"error_database_required"` | `"数据库名称为必填项"` | `"資料庫名稱為必填項"` |
| `"error_https_required"` | `"需要 HTTPS 连接"` | `"需要 HTTPS 連線"` |
| `"error_username_required"` | `"用户名为必填项"` | `"使用者名稱為必填項"` |
| `"error_password_required"` | `"密码为必填项"` | `"密碼為必填項"` |
| `"error_network"` | `"无法连接到服务器"` | `"無法連線到伺服器"` |
| `"error_invalid_url"` | `"无效的服务器网址"` | `"無效的伺服器網址"` |
| `"error_database_not_found"` | `"未找到数据库"` | `"未找到資料庫"` |
| `"error_invalid_credentials"` | `"用户名或密码错误"` | `"使用者名稱或密碼錯誤"` |
| `"error_session_expired"` | `"会话已过期，请重新登录"` | `"工作階段已過期，請重新登入"` |
| `"error_server_%@"` | `"服务器错误：%@"` | `"伺服器錯誤：%@"` |
| `"Unlock with %@"` | `"使用 %@ 解锁"` | `"使用 %@ 解鎖"` |
| `"biometric_reason"` | `"解锁 WoowTech Odoo"` | `"解鎖 WoowTech Odoo"` |
| `"error_biometric_unavailable"` | `"生物识别认证不可用"` | `"生物辨識認證不可用"` |
| `"error_biometric_lockout"` | `"尝试次数过多，请使用 PIN 码"` | `"嘗試次數過多，請使用 PIN 碼"` |
| `"error_biometric_failed"` | `"认证失败，请重试"` | `"認證失敗，請重試"` |
| `"Enter your PIN to unlock"` | `"输入 PIN 码解锁"` | `"輸入 PIN 碼解鎖"` |
| `"lockout_timer_%lld"` | `"%lld 秒后重试"` | `"%lld 秒後重試"` |
| `"wrong_pin_%lld"` | `"PIN 码错误，剩余 %lld 次"` | `"PIN 碼錯誤，剩餘 %lld 次"` |
| `"logout_confirm_message"` | `"确定要退出登录吗？"` | `"確定要登出嗎？"` |
| `"System"` | `"系统"` | `"系統"` |
| `"Light"` | `"浅色"` | `"淺色"` |
| `"Dark"` | `"深色"` | `"深色"` |
| `"Change PIN"` | `"更改 PIN 码"` | `"變更 PIN 碼"` |
| `"Set PIN"` | `"设置 PIN 码"` | `"設定 PIN 碼"` |
| `"Remove PIN"` | `"移除 PIN 码"` | `"移除 PIN 碼"` |
| `"Accent"` | `"强调色"` | `"強調色"` |
| `"Enter Current PIN"` | `"输入当前 PIN 码"` | `"輸入目前 PIN 碼"` |
| `"Enter New PIN"` | `"输入新 PIN 码"` | `"輸入新 PIN 碼"` |
| `"Confirm New PIN"` | `"确认新 PIN 码"` | `"確認新 PIN 碼"` |
| `"Incorrect PIN"` | `"PIN 码不正确"` | `"PIN 碼不正確"` |
| `"PINs don't match"` | `"PIN 码不匹配"` | `"PIN 碼不相符"` |

Plus all existing keys need to be renamed from snake_case to match English text (e.g., `"settings"` -> `"Settings"`, `"appearance"` -> `"Appearance"`, etc.) while preserving their Chinese translations.

### Validation

1. Set device language to English -- verify all strings display correctly
2. Set device language to Simplified Chinese -- verify all strings display in Chinese
3. Set device language to Traditional Chinese -- verify all strings display in Chinese
4. Use iOS Settings > WoowTech Odoo > Language to set per-app language -- verify it works (requires B3's `CFBundleLocalizations` key)
5. Trigger every error state (empty fields, wrong password, lockout) -- verify error messages are localized
6. Open every screen (Login, Biometric, PIN, Main, Config, Settings, Color Picker, PIN Setup) -- verify no English text leaks through in Chinese mode

### Commit Message

```
feat: wire all UI strings to Localizable.strings for en/zh-Hans/zh-Hant

Renames 67 existing .strings keys from snake_case to match exact English
text used in SwiftUI views (enabling automatic LocalizedStringKey lookup).
Adds 35 new keys for error messages, interpolated strings, and previously
missing UI text. Updates LoginViewModel, BiometricView, PinView, and
PinSetupView to use String(localized:) for programmatic string assignments.
Enables UX-58 through UX-62 (language switching).
```

---

## Summary: All Five Blockers

| ID | Blocker | Effort | Files Changed | Files Created |
|----|---------|--------|---------------|---------------|
| B3 | Info.plist missing keys | 15 min | 1 | 0 |
| B1 | PrivacyInfo.xcprivacy | 30 min | 0 | 1 |
| B2 | App icon PNGs | 2 hr | 1 (Contents.json) | 3 (PNGs) |
| B4 | Config screen wiring | 4 hr | 2 (odooApp.swift, ConfigView.swift) | 0 |
| B5 | Localization wiring | 4 hr | 10 (3 .strings + 7 .swift) | 0 |
| **Total** | | **10 hr 45 min** | **14** | **4** |

### UX Items Unblocked

After completing B1-B5, the following UX items move from BROKEN/UNREACHABLE to FUNCTIONAL:

- **UX-30:** Menu button navigates to Config
- **UX-47-57:** Settings screen accessible (theme, security, language, cache, about)
- **UX-58-62:** Language switching works end-to-end
- **UX-63-66:** Cache management accessible
- **UX-67-70:** Config screen (account management) accessible
- **UX-82:** Settings section order verifiable

**Corrected matrix score after B1-B5: ~60/82 -> ~78/82** (remaining 4 are H5 theme mode, M2 remember me, M7 iPad, and verified multi-account edge cases).

---

## Post-Implementation Checklist

- [ ] B3: Info.plist has all 4 new keys
- [ ] B1: PrivacyInfo.xcprivacy exists and is in Copy Bundle Resources
- [ ] B2: All 3 app icon PNGs exist and Contents.json references them
- [ ] B4: Hamburger menu opens ConfigView as a sheet
- [ ] B4: Settings pushes from Config within the sheet
- [ ] B4: Logout dismisses sheet and goes to Login
- [ ] B4: Add Account dismisses sheet and goes to Login
- [ ] B4: Account switch dismisses sheet and reloads WebView
- [ ] B5: All Text/Label/Section/Button strings have matching .strings keys
- [ ] B5: All ViewModel error strings use String(localized:)
- [ ] B5: zh-Hans locale has translations for all keys
- [ ] B5: zh-Hant locale has translations for all keys
- [ ] B5: Per-app language switching works in iOS Settings
- [ ] Clean build with no warnings related to these changes
- [ ] TestFlight upload succeeds (no App Store Connect rejection)
