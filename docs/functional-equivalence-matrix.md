# Functional Equivalence Matrix: Android ↔ iOS

> **Purpose:** Ensure every user-facing feature looks and behaves identically on both platforms.
> **Rule:** A user should NOT be able to tell which platform they're on based on functionality.
> **Date:** 2026-03-26

---

## How to Read This Document

Each row = one user-visible behavior. Both platforms must pass every row.

- **Status**: DONE (implemented + tested) | PLANNED (in milestone) | GAP (not yet planned)
- **Android V-ID**: verification ID from Android test suite
- **iOS V-ID**: verification ID to be created for iOS test suite

---

## 1. Onboarding & Login

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-01 | Open app first time | See login screen with server URL field | DONE (V04) | M3 | |
| UX-02 | Enter server URL without https:// | App auto-prefixes with https:// | DONE (unit test) | M3 | |
| UX-03 | Enter http:// URL | Error: "HTTPS required" | DONE (unit test) | M3 | |
| UX-04 | Enter valid server + database | Proceed to credentials step | DONE | M3 | |
| UX-05 | Enter wrong password | Error: "Invalid credentials" | DONE (unit test) | M3 | |
| UX-06 | Enter correct credentials | Login success → main screen | DONE | M3 | |
| UX-07 | Check "Remember Me" | Password saved encrypted | DONE | M3 | Android: EncryptedSharedPrefs, iOS: Keychain |
| UX-08 | Network error during login | Error: "Unable to connect to server" | DONE (unit test) | M3 | |
| UX-09 | Timeout during login | Error: "Connection timeout" | DONE (unit test) | M3 | 30 second timeout |

---

## 2. Biometric & PIN Lock

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-10 | Enable "App Lock" in settings | Toggle ON → next launch requires auth | DONE (V02) | M4 | |
| UX-11 | Launch app with lock ON | Biometric prompt appears | DONE (unit test) | M4 | Android: BiometricPrompt, iOS: LAContext |
| UX-12 | Biometric success | Navigate to main screen | DONE | M4 | |
| UX-13 | Biometric fails | Show "Use PIN" option | DONE | M4 | |
| UX-14 | ~~Skip button~~ | **NO skip button** — removed for security | DONE (V02) | M4 | Both platforms must NOT have skip |
| UX-15 | Enter correct PIN (4-6 digits) | Unlock → main screen | DONE (unit test) | M4 | |
| UX-16 | Enter wrong PIN | Error + remaining attempts shown | DONE | M4 | |
| UX-17 | 5 wrong PINs | Lockout 30 seconds | DONE (unit test) | M4 | |
| UX-18 | 10 wrong PINs | Lockout 5 minutes | DONE (unit test) | M4 | Exponential: 30s→5m→30m→1hr |
| UX-19 | 20 wrong PINs | Lockout 1 hour (max) | DONE (unit test) | M4 | |
| UX-20 | App goes to background + returns | Re-prompt biometric/PIN | DONE (V03, unit test) | M4 | Android: LifecycleEventEffect, iOS: scenePhase |
| UX-21 | App lock OFF + background/foreground | No auth prompt | DONE (unit test) | M4 | |
| UX-22 | Set new PIN | PIN stored as PBKDF2 hash (600K iterations) | DONE (unit test) | M4 | Same algorithm, cross-platform compatible |
| UX-23 | Change PIN | Old PIN verified, new PIN saved | DONE | M4 | |
| UX-24 | Remove PIN | PIN deleted from storage | DONE | M4 | |

---

## 3. Main Screen (Odoo WebView)

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-25 | Login success | Odoo web UI loads in WebView | DONE (V04) | M5 | Android: WebView, iOS: WKWebView |
| UX-26 | Browse Odoo | WebView only loads same-host URLs | DONE (V04, V17) | M5 | External URLs → system browser |
| UX-27 | Tap external link in Odoo | Opens in Safari/Chrome (not in WebView) | DONE (V05, V17) | M5 | |
| UX-28 | Session expires | Redirect to login screen | DONE | M5 | Detect /web/login redirect |
| UX-29 | Upload file in Odoo | Camera + gallery picker appears | DONE | M5 | Android: onShowFileChooser, iOS: native WKWebView |
| UX-30 | Tap menu button | Navigate to config/settings | DONE (V08) | M5 | |
| UX-31 | WebView loads | Loading spinner shown | DONE | M5 | |
| UX-32 | Odoo OWL framework rendering | No blank areas, correct layout | DONE | M5 | **HIGH RISK** — may need platform-specific JS injection |
| UX-33 | Landscape rotation | WebView adapts | DONE | M5 | |
| UX-34 | iPad layout | Full-width WebView | N/A | M5 | iPad-specific, wider layout |

---

## 4. Push Notifications (FCM)

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-35 | Someone posts chatter message | Push notification arrives | DONE (E2E verified) | M6 | Same Odoo module, FCM bridges to APNs |
| UX-36 | Someone sends Discuss DM | Push notification arrives | DONE (E2E-02) | M6 | |
| UX-37 | Someone @mentions you | Push notification arrives | DONE (E2E-03) | M6 | |
| UX-38 | Activity assigned to you | Push notification arrives | DONE (E2E-04) | M6 | |
| UX-39 | Notification shows sender name | "John Doe" as title | DONE (E2E-10) | M6 | Rich payload, not generic text |
| UX-40 | Notification shows message preview | "Please review SO-2026..." as body | DONE (E2E-10) | M6 | |
| UX-41 | Chinese content in notification | Chinese characters display correctly | DONE (E2E-10) | M6 | |
| UX-42 | Tap notification | App opens → navigates to Odoo record | DONE (E2E-01c, E2E-05) | M6 | Deep link via DeepLinkManager |
| UX-43 | Tap notification while locked | Auth first → then deep link restored | DONE (code) | M6 | DeepLinkManager persists across auth |
| UX-44 | Multiple notifications | Grouped by event type (chatter/discuss/activity) | DONE (E2E-11) | M6 | Android: setGroup, iOS: threadIdentifier |
| UX-45 | Notification on lock screen | Content hidden (VISIBILITY_PRIVATE) | DONE (unit test) | M6 | Android: VISIBILITY_PRIVATE, iOS: hiddenPreviewsDeclaration |
| UX-46 | App in foreground + notification | Heads-up notification shown (not auto-navigate) | DONE | M6 | Let user choose to tap |

---

## 5. Settings Screen

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-47 | Open Settings | See sections: Appearance, Security, Language, Data, Help, About | DONE (V08) | M7 | Same section order |
| UX-48 | Tap "Theme Color" | Color picker dialog opens | DONE (V10) | M7 | |
| UX-49 | See brand preset colors | 5 brand colors (Primary Blue, White, Light Gray, Gray, Deep Gray) | DONE (V10a) | M7 | Same hex values |
| UX-50 | See accent colors | 10 accent colors (Cyan, Yellow, SkyBlue, etc.) | DONE (V10b) | M7 | Same hex values |
| UX-51 | See HEX input | Custom color input field (#RRGGBB) | DONE (E2E-07c) | M7 | |
| UX-52 | Enter custom HEX + Apply | Theme color changes to custom color | DONE (V15) | M7 | |
| UX-53 | Change theme mode | System / Light / Dark mode switch | DONE | M7 | |
| UX-54 | Toggle "App Lock" | Enable/disable biometric lock | DONE | M7 | |
| UX-55 | Toggle "Biometric Unlock" | Enable/disable Face ID / fingerprint | DONE | M7 | |
| UX-56 | Set/Change PIN | 4-6 digit PIN with dot indicators | DONE | M7 | Same numpad layout |
| UX-57 | "Reduce Motion" toggle | Reduce animations | DONE | M7 | |

---

## 6. Language

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-58 | Tap Language picker | See: System Default, English, 繁體中文, 简体中文 | DONE (V09) | M8 | Same 4 options |
| UX-59 | Select 简体中文 | ALL UI strings change to Simplified Chinese | DONE (V16a) | M8 | Android: instant, iOS: via system Settings (Q4: B) |
| UX-60 | Select 繁體中文 | ALL UI strings change to Traditional Chinese | DONE | M8 | |
| UX-61 | Select English | ALL UI strings change to English | DONE (V16b) | M8 | |
| UX-62 | Key terms in zh-CN | 服务器, 数据库, 设置, 账号, 生物识别, 清除缓存 | DONE | M8 | NOT 伺服器/資料庫 (those are zh-TW) |

**iOS Difference (UX-59):** On iOS, language switching uses system per-app language setting (Settings app → odoo → Language). This is different from Android where it switches instantly in-app. The user must go to iOS Settings to change language. This is Apple's recommended approach for iOS 16+.

---

## 7. Cache Clearing

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-63 | Tap "Clear Cache" in Settings | Cache cleared | DONE (V11, V18) | M8 | |
| UX-64 | After cache clear | Still logged in (login preserved) | DONE (V11b) | M8 | Only cache/WebView data, not session |
| UX-65 | After cache clear | Return to main screen shows Odoo (not login) | DONE (E2E-09b) | M8 | |
| UX-66 | Cache size display | Shows current cache size (e.g., "2 MB") | DONE | M8 | |

---

## 8. Multi-Account

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-67 | Tap "Add Account" | Login screen for new account | DONE | M7 | |
| UX-68 | Switch between accounts | WebView reloads with new account's session | DONE | M7 | |
| UX-69 | Logout | Account removed, return to login | DONE (unit test) | M7 | Cookies + password cleared |
| UX-70 | Delete account | Account removed from list | DONE (unit test) | M7 | |

---

## 9. Deep Link Security

| # | User Action | Expected Behavior | Android | iOS | Notes |
|---|------------|-------------------|---------|-----|-------|
| UX-71 | Notification with `/web#id=42` | WebView navigates to record | DONE (V19) | M6 | |
| UX-72 | Malicious `javascript:alert()` link | **REJECTED** — not loaded | DONE (unit test, V17) | M1 (done) | Same validator |
| UX-73 | Malicious `data:text/html` link | **REJECTED** — not loaded | DONE (unit test) | M1 (done) | Same validator |
| UX-74 | External host `evil.com` link | **REJECTED** — not loaded | DONE (unit test, V17) | M1 (done) | Same validator |
| UX-75 | `woowodoo://open` URL scheme | App handles deep link | DONE | M6 | Registered in Info.plist |

---

## 10. Visual Consistency

| # | Element | Expected Behavior | Android | iOS | Notes |
|---|---------|-------------------|---------|-----|-------|
| UX-76 | Primary brand color | #6183FC everywhere | DONE (V08) | M1 (done) | Same hex in WoowColors |
| UX-77 | 10 accent colors | Same hex values on both | DONE | M1 (done) | Same hex values |
| UX-78 | App bar / navigation bar | Shows "WoowTech Odoo" with brand color | DONE (V08b) | M5 | |
| UX-79 | Font | System font (no custom fonts) | DONE | M1 (done) | Android: Sans Serif, iOS: San Francisco |
| UX-80 | PIN numpad layout | 3x3 grid + 0 + backspace | DONE | M4 | Same layout |
| UX-81 | Color picker layout | Grid of circles + HEX input | DONE | M7 | Same layout |
| UX-82 | Settings sections order | Appearance → Security → Language → Data → Help → About | DONE | M7 | Same order |

---

## Summary (Updated 2026-04-05 — ALL GAPS CLOSED)

| Category | Total UX Items | Android DONE | iOS Status | iOS GAPs |
|----------|---------------|-------------|------------|----------|
| Login | 9 | 9 | 9/9 DONE | 0 |
| Biometric/PIN | 15 | 15 | 15/15 DONE | 0 |
| Main WebView | 10 | 9 | 10/10 DONE | 0 |
| Push Notifications | 12 | 12 | 12/12 DONE | 0 |
| Settings | 11 | 11 | 11/11 DONE | 0 |
| Language | 5 | 5 | 5/5 DONE | 0 |
| Cache | 4 | 4 | 4/4 DONE | 0 |
| Multi-Account | 4 | 4 | 4/4 DONE | 0 |
| Deep Link Security | 5 | 5 | 5/5 DONE | 0 |
| Visual Consistency | 7 | 7 | 7/7 DONE | 0 |
| **Total** | **82** | **81** | **82/82 DONE** | **0 gaps** |

### Gap Status — All Closed

| Priority | Gap | Description | Status |
|----------|-----|-------------|--------|
| ~~P0~~ | ~~G3~~ | ~~URL scheme~~ | **DONE** |
| ~~P0~~ | ~~G9~~ | ~~FCM unregister on logout~~ | **DONE** |
| ~~P0~~ | ~~G7~~ | ~~Lock screen notification privacy~~ | **DONE** |
| ~~P1~~ | ~~G8~~ | ~~Account switch re-auth~~ | **DONE** |
| ~~P1~~ | ~~G2~~ | ~~PIN setup in Settings~~ | **DONE** |
| ~~P2~~ | ~~G1~~ | ~~Language picker~~ | **DONE** — shows current language, taps to iOS Settings, localized hint |
| ~~P2~~ | ~~G6~~ | ~~Reduce Motion toggle~~ | **DONE** — Toggle in Appearance, persisted via SettingsRepository |
| ~~P3~~ | ~~G5~~ | ~~About section~~ | **DONE** — version + website + contact email + copyright |
| ~~P3~~ | ~~G4~~ | ~~Help & Support~~ | **DONE** — Odoo Help Center + Community Forum links |

#### Quality Fixes Applied (Architect Review)
- All strings localized in en, zh-Hans, zh-Hant (real Chinese translations)
- Decorative images have `.accessibilityHidden(true)` for VoiceOver
- URLs extracted to `SettingsConstants` enum (testable, single source of truth)
- ViewModel properties (`appVersion`, `currentLanguageDisplayName`) extracted from views
- `setReduceMotion` added to `SettingsRepositoryProtocol` + implementation
- CLAUDE.md updated with localization rules + production checklist

#### No Remaining Work

1. **G1** (2 hrs) — Language picker (redirect to iOS Settings)
2. **G6** (1 hr) — Reduce Motion toggle
3. **G5** (1.5 hrs) — About section rows
4. **G4** (2 hrs) — Help & Support section
9. **G4** (2 hrs) — Help & Support section

### Known iOS Differences (Not Bugs)

| # | Difference | Why | Impact |
|---|-----------|-----|--------|
| D1 | Language switching via system Settings, not in-app | Apple's iOS 16+ design guideline | User goes to Settings → odoo → Language instead of in-app picker |
| D2 | Face ID instead of fingerprint on newer devices | Hardware difference | Same LAContext API handles both |
| D3 | San Francisco font instead of Sans Serif | Platform default font | Visually very similar |
| D4 | Notification grouping is automatic | iOS groups by threadIdentifier, no manual summary | Slightly different grouping UI |
| D5 | iPad sidebar/split view | iPad-specific layout | Android has no tablet equivalent |

---

## Verification Plan

For each UX item, iOS verification will use:
- **XCTest** for unit testable logic (auth, PIN hash, validator, settings)
- **XCUITest** for UI flow testing (login, settings, color picker)
- **idb** (iOS Development Bridge) for device-level automation (like uiautomator2)
- **Manual** for push notifications (APNs cannot be automated in simulator)

Each milestone commit must verify ALL UX items in that milestone before committing.
