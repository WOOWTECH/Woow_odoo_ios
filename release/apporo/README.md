# Apporo platform iOS 發版工具

比照 woowtech platform 的 `optionH-prime-implementation/releases/tools/`，但放在本 repo 版控內，避免 scratchpad 被清。

## 前置（需擁有者批准，見 RELEASE-MASTER-PLAN B7）
1. Apple Developer 註冊 App ID `com.apporo.odoo`（勾 Push Notifications）與 `com.apporo.odoo.dev`。
2. ASC 建立 App 紀錄（名稱 Apporo platform，主要語言 English (U.S.)，SKU `APPORO-ODOO-IOS`）。
3. 實機驗收用 ad-hoc：建立 ad-hoc profile，把 UUID 填進 `ExportOptions-AdHoc.plist`。

## 版本號規則
- `MARKETING_VERSION` 在 `Config/Shared.xcconfig`（兩品牌共用，目前 1.0）。若 Apporo 需要與 WOOW 不同的版本號，改在 `Config/ApporoRelease.xcconfig` 覆寫。
- `CURRENT_PROJECT_VERSION` 在 `Config/ApporoRelease.xcconfig`，**每次上傳 ASC 前單調遞增**（1→2→…），同一個 build number 不能重複上傳。
- ExportOptions 設 `manageAppVersionAndBuildNumber=false`，由上面兩個值決定，不讓 Xcode 自動改。
- 每次上傳打本機 tag `ios-apporo-<MARKETING_VERSION>-b<CURRENT_PROJECT_VERSION>`，指向實際建出 IPA 的 commit；只推指定 tag，禁止 `git push --tags`。

## 指令（範例）
```sh
xcodebuild archive -project odoo.xcodeproj -scheme apporoodoo -configuration ApporoRelease \
  -destination 'generic/platform=iOS' -archivePath build/apporo/ApporoPlatform.xcarchive
xcodebuild -exportArchive -archivePath build/apporo/ApporoPlatform.xcarchive \
  -exportOptionsPlist release/apporo/ExportOptions-AppStore.plist -exportPath build/apporo/export
# 實機驗收：既有 xcarchive 用 ExportOptions-AdHoc.plist 重匯出即可，不要改開發簽章
```
上傳沿用 ASC API 金鑰（`~/.appstoreconnect/private_keys/`，只寫路徑）與 `xcrun altool`／Transporter；送審一律手動發布。
