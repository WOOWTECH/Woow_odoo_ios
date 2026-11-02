# Apporo platform 後端修復與實機驗證

2026-11-02，台北時間，18:49 更新。**本輪要求處理的兩項後端問題均已修復並部署：審查站 Apporo 推播介面與發送路由已啟用，獨立測試站 WebSocket HTTP 500 已排除。** 實體 iPad 的 TestFlight 1.0 (6) 已收到審查站正式推播，通知點擊可冷啟動並回到正確帳號／對話；設施工作台也重新讀到既有任務 #8。沒有改動或重傳 App binary，也沒有取消審查。

## 審查站推播

`demo111-odoo.woowtech.io` 原本的 `woow_fcm_push` 為 18.0.1.2.0，缺少 `get_push_capabilities`，且只有 WOOW 推播 sidecar。一般工作台功能可使用，並不代表該站支援 Apporo 推播。

透過帳號擁有者授權的 Linux 維運 shell 完成部署，無須變更 SSH 金鑰或放寬網站登入權限：

1. 保存原始 Deployment、ConfigMap、服務設定、舊模組與資料基線；停止單一 Odoo instance 後備份 PostgreSQL。
2. 在 PostgreSQL 容器內確認 dump 可讀，並比對匯出的 SHA-256。初次透過 stdin 傳回 dump 的驗證發生工具傳輸截斷，已改用容器內驗證；未使用那份截斷檔進行升級或還原。
3. 使用 Git commit `6890b551ded11031d07e4bf6eb6a255c163f629a` 的模組，逐一核對 22 個 runtime 檔案後執行正式 Odoo `-u woow_fcm_push`。18.0.1.3.0 的 pre/post migration 均成功。
4. 保留原有 WOOW sidecar，新增獨立 Apporo sidecar 與專屬狀態 PVC。透過 Apporo central 的一次性註冊碼建立這個審查站自己的 box；沒有複製測試站的憑證。
5. 實際向兩個 sidecar 取得有效 OAuth 發送憑證後，才啟用 `woow_fcm_push.apporo.firebase_project_id=apporo-odoo-app`。審查帳號 UID 10 的能力介面現回傳 contract 2、`woowtech` 與 `apporo`。

原先 8 筆 `project.task` 及 9 筆 WOOW 裝置列在升級前後內容雜湊相同；裝置比較排除本次新增的 `app_brand` 欄位。原 WOOW 裝置均維持 inactive，沒有被重啟成收件者。資料庫新約束為 `(app_brand, fcm_token, user_id)`，品牌欄位不可空、預設 woowtech。iPad 重新連線後建立有效 Apporo iOS 裝置列 #45、UID 10。

服務於 18:27 恢復，四個容器正常運行。Apporo central 的專屬註冊已於 18:27:35 消耗一次性碼。私密備份保留於 Linux 的 `~/apporo-backend-repair-20261102/`。已用唯讀掛載確認 Apporo 憑證檔存在於專屬 PVC，再移除已消耗／到期的一次性 Kubernetes Secret；也已關閉臨時 Cloud SQL Proxy 並刪除本機暫存資料庫 URL。

## WebSocket 500

測試站的 Cloudflare Tunnel 直接指向 Odoo HTTP worker 8069，繞過現有 Nginx 8080；而 Nginx 原本已正確把 `/websocket` 轉給 evented worker 8072。Odoo 因此記錄 `KeyError: socket` 與 `Couldn't bind the websocket`。

18:03 備份並檢查 tunnel 設定版本後，只把測試站的 origin port 改為 8080。18:04 與 18:29 的公開、已登入 WebSocket 握手均回傳 HTTP 101，並收到訂閱回應；升級後審查站也通過相同驗證。iPad 的 `Real-time connection lost` 提示消失，新的 `20261102-LIVE-01` 訊息在未刷新或重開的聊天畫面出現。

部署來源 `setup-public-url.sh` 的舊 8069 設定也已修正，Linux 現用兩份部署腳本同步修正並保存備份。來源提交 `fa5a79c`、[部署修正 PR #4](https://github.com/WOOWTECH/optionH-prime-implementation/pull/4)；PR 尚待合併，現場修復已生效。Shell、內嵌 Python 語法及 diff 檢查通過。

## 審查站 iPad 端到端證據

裝置仍為 iPad 9／iPadOS 26.6.1、Apple TestFlight Beta Distribution 的 `com.apporo.odoo` 1.0 (6)，具 production APNs entitlement。本輪所有訊息只送到審查 UID 10 與 OdooBot 的既有私人對話 #11，成員核對為 partner 28 與 2。

| 驗證 | 證據 |
|---|---|
| 背景推播送達 | 18:30 建立標記 #439，OdooBot 回覆 #440。後端記錄 FCM 1/1 成功；iPad 通知中心顯示同一回覆內容。 |
| App 完全終止後送達 | 18:37 建立 #441、回覆 #442；送出前及通知送達後，裝置程序清單均沒有 odoo。後端再次記錄 FCM 1/1 成功，通知中心可見新回覆。 |
| 通知點擊冷啟動與帳號路由 | 在 App 仍終止時，18:43 從展開的通知群組點擊審查站 #440 的特定文字。App 出現 PID 2047；未使用 activate／launch 代替通知啟動。對話讀到 #439 與 #441 的兩個標記，帳號選單確認林雅婷、`app.tester.c@example.com`。此處明確區分：本次冷狀態新收件為 #442，成功點擊的是同站保留的 #440。 |
| 工作台回歸 | 通知驗證後開啟原生設施工作台，讀到 Alpha Site 及 `TestFlight iPad - lobby sensor check`（原任務 #8）；未再新增或修改任務。 |
| 測試站修復後推播 | 18:09 的 WebSocket 即時訊息測試亦產生 OdooBot 回覆 #52；後續系統通知中心仍可見其對應通知。先前背景／前景／冷啟動完整測試結果保持原始範圍。 |

工具失敗保留：首次即時更新等待早於發送而逾時；首次通知中心手勢未展開；模糊 App 名稱匹配選到較小的舊測試站通知；Apple 帳號驗證視窗曾中斷操作；跨批次的座標因畫面變更開到 Maps，已終止該 App，未選擇定位授權。另有把對話標記誤當成帳號首頁內容的等待失敗。最終改在同一批次展開通知群組、依特定回覆內容點擊，再獨立驗證程序及目的地。這些失敗沒有被當作產品通過項目，也沒有被隱藏。

## 收據與剩餘範圍

本機 `receipts/apporo-backend-repair-1102/` 保存模組檔案雜湊、升級／備份摘要、兩站 WebSocket、能力介面、發送事件、iPad 測試與最終總收據。重點為 `review-backend-after.json`、`review-capabilities-after.json`、`both-websockets-after.json`、`review-cold-process-proof.json`、`08-review-notification-center/`、`15-review-cold-notification/`、`21-review-cold-specific-open/`、`22-review-cold-route-confirm/`。

完整通知中心與系統驗證截圖含私人資訊，只保留本機；未上傳 Git 或 Apple。沒有上傳公司用印文件。

18:39 重新讀取 App Store Connect 原提交：**1.0 (6) 仍為等待審查**，沒有新的 Apple 回覆，也尚未上架。本輪沒有重測 Android、聲音實際播放或所有多帳號登出情況。另在審查站日誌看到既有 fetchmail IMAP 連線拒絕；維修前日誌已有相同錯誤，與本次推播與 WebSocket 不同，未更動郵件模組設定。
