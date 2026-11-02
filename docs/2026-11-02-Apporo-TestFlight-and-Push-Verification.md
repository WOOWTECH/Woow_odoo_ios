# Apporo platform build 6：TestFlight 與正式推播實測

2026-11-02，台北時間，18:49 更新。**TestFlight 安裝、設施工作台與正式推播已通過；審查站推播及測試站 WebSocket 兩項後端問題也已修復並部署。** 審查站現已用同一台 iPad 驗證背景／終止後送達、通知冷啟動與正確帳號／對話。詳見 [後端修復與實機驗證](2026-11-02-Apporo-Backend-Repair-and-Verification.md)。沒有修改或重新上傳 App binary，也沒有取消審查。下文保留先前測試事件的原始範圍。

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

以上安裝與權限證據本身不能證明送達；實際送達證據見下一節。跨站通知切換已驗證，但不等同所有多帳號隔離及登出清除情況均已驗證。

恢復待測畫面的第 22 批腳本曾錯用不存在的「完成」標籤，保留失敗紀錄；依當時畫面改用返回按鈕後，第 23 批成功。這是工具定位錯誤，沒有隱藏或計入產品通過項目。

## 正式推播實際送達與點擊

先前 Mac 的 SSH 金鑰遭拒、Linux 發送端憑證無法取得，Chrome 測試站也尚未登入管理員。後續使用 iPad 既有 Push Tester A session（UID 8），透過正常 Odoo API 在既有私人 OdooBot 對話 #11 發送測試訊息／執行 help 指令，由 OdooBot 的正常回覆觸發正式遠端推播，因此不再需要管理員登入才能完成這輪投遞測試。每次寫入前均核對測試站、UID 8 及對話成員僅為 partner 2（OdooBot）與 partner 42（Push Tester A）；沒有冒用其他使用者或傳送給真人帳號。

| 實測 | 後端事件與實機結果 |
|---|---|
| 背景送達及點擊 | 17:10 建立標記訊息 #44，OdooBot 回覆 #45。iPad 通知中心出現 Apporo platform、OdooBot 與相同內容；點擊後開到對話 #11，讀到標記及回覆。 |
| 完全終止後送達／冷啟動 | 17:21 建立 #46、回覆 #47。送出前與收到通知後，`devicectl` 均確認沒有 odoo 程序；點擊通知後出現 PID 1923，App 直接載入正確對話及 `20261102-COLD-BOT-02`。驗證階段未用 activate／launch 代替點擊啟動。 |
| 前景橫幅 | 17:23 執行 help，OdooBot 建立 #48。當時 App 前景使用 demo111 審查帳號林雅婷；實機截圖捕捉到另一站 Push Tester A 的 OdooBot 通知橫幅。 |
| 前景通知點擊及跨站帳號切換 | 17:26 建立 #49、回覆 #50。直接點擊出現的系統橫幅，App 從林雅婷切換成 Push Tester A，開啟對話 #11 並讀到 `20261102-FG-TAP-BOT-03`；再以原生帳號選單核對 `push.a@example.com`。 |

這些通知由後端實際 OdooBot 訊息觸發，送到已確認具 production APNs entitlement 的 TestFlight 安裝，沒有注入本機或模擬通知。未取得發送端逐跳 trace 或管理端裝置註冊 ACK；以後端訊息、裝置系統通知及點擊目的地共同證明端到端行為。聲音權限已開啟，但未以收音驗證實際聲音。

保留的工具限制：第 26 批首次點擊只展開通知，第 27 批因此無法取得背景 App 的 accessibility tree；第 28 批重新讀取實際通知位置，第 29–30 批才確認成功開啟。前景 help 指令成功建立 #48，但回應沒有 result 欄位，舊腳本出現 KeyError；已用獨立讀回及橫幅截圖確認，沒有重送該指令。現行 App 前景呈現選項包含 banner、sound、badge，未包含 list；因此 #48 橫幅消失後不在通知中心，第 39 批改直接點擊下一則前景橫幅，成功完成驗證。上述情況均未被掩蓋或當成單憑腳本執行成功的產品通過證據。

## 後端問題已修復

17:27 的審查站 `get_push_capabilities` AttributeError 及測試站 WebSocket HTTP 500 是修復前的實測結果。18:27 審查站完成模組 1.3.0 升級與專屬 Apporo 推播配置，能力介面回傳 contract 2、woowtech/apporo；UID 10 已註冊有效 iOS 裝置並收到正常 OdooBot 遠端通知。兩個站點的公開 WebSocket 均通過 HTTP 101 與訂閱回應，iPad 即時聊天已恢復。

後續維運透過擁有者授權的 Linux shell 完成，不再受原 SSH 金鑰問題阻塞。備份、資料比對、發送紀錄、通知點擊冷啟動及工具失敗的完整說明見 [後端修復與實機驗證](2026-11-02-Apporo-Backend-Repair-and-Verification.md)。18:39 Apple 原提交仍為等待審查。

## 證據與上架狀態

工作區 `receipts/apporo-platform-validation-1102/testflight-push/` 保存：

- `08-confirm-install/`、`09-install-finished/`：TestFlight 安裝及 build 6 畫面。
- `installed-signing-metadata.json`：裝置實際安裝簽章與正式 APNs entitlements。
- `15-create-testflight-request/`、`16-relaunch-and-push-registration/`：新增、成功、刷新與重開讀回。
- `before-testflight-create.json`、`after-testflight-create.json`：獨立後端核對。
- `20-ios-app-permissions/`、`21-notification-permissions/`：系統權限畫面。
- `bot-probe-*.json`：四次測試事件、後端訊息 ID 與裝置證據對應。
- `25-bot-background-notification/`、`30-confirm-background-destination/`：背景收件及點擊目的地。
- `cold-process-proof.json`、`32-cold-notification/`、`34-cold-destination/`：程序不存在、通知收件與冷啟動目的地。
- `35-foreground-cross-account-setup/`、`36-foreground-delivery/foreground-6s.png`、`39-foreground-banner-tap/`、`40-cross-account-destination/`：另一帳號前景、實際橫幅、點擊及正確收件帳號。
- `backend-capabilities.json`、`review-push-capabilities-latest.json`、`websocket-diagnostic.json`、`receipt.json`：介面核對、未解決問題與測試總收據。
- `review-status-latest.json`、`review-status-latest.png`：17:22 重新載入 App Store Connect，確認 **1.0 (6) 仍為等待審查**，尚未核准上架。

完整通知中心截圖含其他 App 的私人通知，只保留於本機收據，未上傳至 Git 或 Apple。先前階段結束時保留 Push Tester A；本輪後端修復驗證後，iPad 已恢復 TestFlight 1.0 (6) 的林雅婷審查帳號與設施工作台。

先前開發簽章實機測試的收據保持原始範圍；本文件補上其 TestFlight 缺口。相機附件、定位打卡、生物辨識與網路中斷不在本輪已完成結果內。
