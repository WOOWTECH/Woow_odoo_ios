# Apporo platform build 6：TestFlight 與正式推播實測

2026-11-02，台北時間，17:28 更新。**TestFlight 安裝、設施工作台、正式推播的背景／前景／冷啟動送達與通知點擊均已通過；另已驗證通知點擊自動切換到正確帳號。** 審查站推播模組相容性與獨立測試站即時連線問題仍待修復。本輪沒有修改產品程式、重新上傳 binary 或取消審查。

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

## 尚待處理的後端問題

審查站 `demo111-odoo.woowtech.io` 仍使用不支援 Apporo 合約的舊推播模組。以審查帳號呼叫 `woow.fcm.device.get_push_capabilities`，實際得到 `AttributeError`：方法不存在。App 執行紀錄亦出現 `push_status_not_configured`。因此不能把審查站的工作台成功當成該站推播成功。

17:27 再次實際查詢仍得到相同 AttributeError。需要在審查站升級／配置相容的推播後端，再用審查帳號完成送達驗證；不能以獨立測試站通過宣稱該站已修復。

獨立測試站 `apporo-push-test.woowtech.io`／`apporopushtest` 的能力介面回傳 contract 2、支援 woowtech 與 apporo，並已完成上述正式通知實測。但其聊天頁顯示 `Real-time connection lost...`；17:25 以同一測試 session 對 `/websocket?version=18.0-7` 發起握手，回傳 HTTP 500。這是仍存在的即時更新問題，確切原因尚需後端紀錄，不能由通知成功推論聊天即時更新正常。

後端維修仍需要可用的 Linux 維運／部署存取。既有 SSH 公鑰被拒及管理員未登入的情況尚未改變；一般接收帳號仍沒有裝置管理權限，沒有繞過權限或修改伺服器安全設定。

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

完整通知中心截圖含其他 App 的私人通知，只保留於本機收據，未上傳至 Git 或 Apple。iPad 最後保留 TestFlight 1.0 (6)、Push Tester A 與已驗證的 OdooBot 對話。

先前開發簽章實機測試的收據保持原始範圍；本文件補上其 TestFlight 缺口。相機附件、定位打卡、生物辨識與網路中斷不在本輪已完成結果內。
