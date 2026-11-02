# Apporo platform build 6：TestFlight 與正式推播實測

2026-11-02，台北時間。**TestFlight 安裝及設施工作台流程通過；正式推播送達與通知點擊尚未完成，等待發送端登入。** 本輪沒有修改產品程式、重新上傳 binary 或取消審查。

## 已完成

在 USB 連接的 iPad 第 9 代／iPadOS 26.6.1，直接操作 TestFlight 的 Apporo platform 1.0 (6)「安裝」，確認以測試版取代既有開發安裝；完成後顯示「打開」，由此啟動 App。

除了 TestFlight 畫面，另從裝置 installation proxy 獨立核對實際安裝 App：

- `CFBundleIdentifier=com.apporo.odoo`，版本 `1.0`，build `6`。
- `SignerIdentity=TestFlight Beta Distribution`。
- `aps-environment=production`、`beta-reports-active=true`、`get-task-allow=false`。
- `ProfileValidated=true`。

`devicectl` 的 `builtByDeveloper` 欄位仍回傳 true，不能單靠該欄位判斷安裝來源；上述 Apple 簽章與 entitlements 才是本次確認 TestFlight 版本的直接證據。最初預設 App 清單漏列 TestFlight，不能當成裝置未安裝 TestFlight；後續已直接開啟並操作既有 TestFlight。

| 實測 | 結果 |
|---|---|
| 更新後帳號保留 | 審查帳號 UID 10 與獨立推播站 Push Tester A 均保留；兩站切換可載入相應畫面。 |
| 工作台讀取 | 審查帳號讀取 Alpha Site 及先前實機建立的任務 #7。 |
| TestFlight 新增請求 | 實機建立 `TestFlight iPad - lobby sensor check`，成功提示、刷新及讀回均通過。 |
| 後端獨立核對 | 唯一新增任務 #8，project #1、creator UID 10、一般優先級 `0`，內容與實機輸入一致；既有七筆任務未變更。 |
| 生命週期 | 背景切回、終止及重新啟動後，仍能讀回 #8。 |
| 系統設定入口 | App 的語言設定入口可開啟 iOS 的 Apporo platform 設定。 |
| 通知設定 | 允許通知、鎖定畫面、通知中心、橫幅、聲音及標記均已開啟；背景 App 重新整理開啟。 |
| Firebase 啟動 | 正式安裝 App 的執行紀錄出現 notification permission true 與 FCM token callback；沒有保存 token 明文到收據。 |

這些結果不等同推播已送達，也不等同完整的多帳號隔離驗證。

恢復待測畫面的第 22 批腳本曾錯用不存在的「完成」標籤，保留失敗紀錄；依當時畫面改用返回按鈕後，第 23 批成功。這是工具定位錯誤，沒有隱藏或計入產品通過項目。iPad 現保留 TestFlight 版本與 Push Tester A，App 已回到背景，供後續通知投遞測試。

## 正式推播的實際阻礙

審查站 `demo111-odoo.woowtech.io` 仍使用不支援 Apporo 合約的舊推播模組。以審查帳號呼叫 `woow.fcm.device.get_push_capabilities`，實際得到 `AttributeError`：方法不存在。App 執行紀錄亦出現 `push_status_not_configured`。因此不能把審查站的工作台成功當成該站推播成功。

歷史部署紀錄另有經授權的獨立測試站 `apporo-push-test.woowtech.io`，資料庫 `apporopushtest`。本輪透過 iPad 的既有 Push Tester A session（UID 8）確認登入有效，能力查詢實際回傳 contract 2、支援 `woowtech` 與 `apporo`。這只確認介面相容，尚未獨立核對新裝置的註冊 ACK 或正式通知送達。

測試發送端憑證保存在 Linux 維運主機的 `~/apporo-push-test/accounts.env`。Mac 連線 `192.168.2.10` 時既有 SSH 公鑰遭拒；歷史 Tailscale 位址無法連線。接收端一般帳號沒有讀取 FCM Device 管理紀錄的權限，已尊重該權限限制。已用 Chrome MCP（port 12306）開啟測試站管理員登入頁，向使用者請求完成登入；目前尚未登入。Firebase Console 的既有另一個瀏覽器工作階段也已過期。

**本輪尚未送出測試推播。** 前景、背景、App 終止狀態的實際收件，以及通知點擊後開啟正確帳號／內容，都仍待驗證。沒有將本機通知、模擬通知或註冊成功冒充正式 APNs 送達。

登入後需先核對測試站與管理員身分、UID 8 的 Apporo／iOS 裝置，再只向該測試帳號建立帶明確測試標記的通知事件，逐一保存送出紀錄、iPad 通知及點擊開啟結果。若投遞失敗，再以該次事件查 sidecar／FCM／APNs 錯誤。審查站舊模組的相容性問題另外保留，不能以獨立測試站通過宣稱已修復。

## 證據與上架狀態

工作區 `receipts/apporo-platform-validation-1102/testflight-push/` 保存：

- `08-confirm-install/`、`09-install-finished/`：TestFlight 安裝及 build 6 畫面。
- `installed-signing-metadata.json`：裝置實際安裝簽章與正式 APNs entitlements。
- `15-create-testflight-request/`、`16-relaunch-and-push-registration/`：新增、成功、刷新與重開讀回。
- `before-testflight-create.json`、`after-testflight-create.json`：獨立後端核對。
- `20-ios-app-permissions/`、`21-notification-permissions/`：系統權限畫面。
- `backend-capabilities.json`、`app-runtime-sanitized.log`、`receipt.json`：介面核對、經過濾的執行紀錄與明確未完成項目。
- `review-status.json`、`review-status.png`：15:39 重新載入 App Store Connect，確認 **1.0 (6) 仍為等待審查**，尚未核准上架。

先前開發簽章實機測試的收據保持原始範圍；本文件補上其 TestFlight 缺口。相機附件、定位打卡、生物辨識與網路中斷不在本輪已完成結果內。
