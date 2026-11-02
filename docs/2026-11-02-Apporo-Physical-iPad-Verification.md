# Apporo platform build 6：實體 iPad 驗證

2026-11-02，台北時間。使用者接回 iPad 後，已實際完成本輪設施工作台的硬體驗證。測得的登入、讀取、建立及生命週期流程均通過，沒有發現需要修改送審 binary 的阻斷問題。

後續已補做真正的 TestFlight 安裝，從裝置核對 Apple Beta 簽章與 production APNs entitlement，完成新增任務 #8 及重開讀回；另以獨立測試站完成正式推播背景送達、冷啟動、前景橫幅及通知點擊跨站帳號切換。兩項後端問題已於同日完成修復，審查站正式通知與冷啟動亦已通過，詳見 [後端修復驗證](2026-11-02-Apporo-Backend-Repair-and-Verification.md)。見 [TestFlight 與正式推播實測](2026-11-02-Apporo-TestFlight-and-Push-Verification.md)。下文保留第一階段開發簽章實測的原始範圍。

## 裝置與版本

- 實體 iPad（第 9 代，iPad12,1），iPadOS 26.6.1（23G83），USB 配對且開發者模式啟用。
- 原裝 Apporo platform 1.0 (5)，更新為 `com.apporo.odoo` 1.0 (6)，保留原測試帳號，再透過 App 的新增帳號流程登入審查帳號 UID 10。
- 安裝來源為本日已送審的 `ApporoPlatform.xcarchive/Products/Applications/odoo.app`，ApporoRelease 配置，來源 commit `f9ee2071dc40063a40ff9a1b9dda2f9188aae78f`、tag `ios-apporo-1.0-b6`。
- 硬體安裝沿用 archive 的開發簽章，profile 包含此裝置，codesign 驗證通過。封存 App 與已上傳 App Store IPA 的主執行檔 UUID 同為 `4A057678-BF9A-3D2B-A5A0-4A1578F59F1E`。未重新編譯或修改產品程式。
- 這不是 TestFlight 安裝；實機開發簽章的 `get-task-allow=true`、`aps-environment=development`，不可當成正式 APNs 或商店安裝驗證。

## 實際結果

| 項目 | 結果與證據 |
|---|---|
| 更新與啟動 | 安裝後讀取裝置 App 清單，確認 1.0 (6)；原帳號仍可進入主畫面。 |
| 無可讀專案的帳號 | 原 Push Tester A 顯示專案載入／存取權提示，新增停用；未對此帳號新增任務。此畫面不單獨證明錯誤一定是權限而非其他後端設定。 |
| 審查帳號登入 | 原生 UI 輸入 demo111 伺服器、資料庫及既有審查憑證；主畫面載入，原生工作台讀到 Alpha Site 與既有任務。 |
| 必填欄位 | 空白表單、只有標題時，「送出」均為 Disabled；補齊內容後可送出。 |
| 新增高優先級請求 | 實機填寫並送出 `Physical iPad - pump room inspection`，顯示成功提示，重新整理後清單可見。 |
| 後端獨立核對 | 相同審查帳號經另一 HTTP session 讀取，確認唯一新增任務 #7、project #1、create_uid #10、priority `1`、stage New，標題及內容一致。內容中的 `<`、`&`、`>` 正確轉義為 HTML 文字。 |
| 取消已填表單 | 填入 `CANCELLED physical iPad validation` 與描述後取消；前後後端的七筆任務完全一致，沒有建立取消的草稿。 |
| 生命週期 | 回到主畫面再切回、終止並重新啟動 App，仍能讀取任務 #7，無需重新輸入帳密。 |
| 版面與外觀 | 直向及穩定橫向畫面可讀，橫向刷新成功；深色及淺色工作台／表單、鍵盤顯示時的填寫與送出皆有實機截圖。 |
| 語系 | 繁中流程完成建立；英文重新啟動後可讀任務、刷新、開啟表單並取消；已檢查的畫面未出現未翻譯的鍵值。 |

本次唯一新增資料是審查站任務 #7。未修改既有六筆示範任務。測試後已恢復繁中、原本「系統」外觀及直向畫面，停留在審查帳號工作台。未操作其他品牌 App、傳送聊天訊息或上傳公司用印文件。

## 工具問題及範圍

第一輪使用舊 Xcode 26.6 的 UI runner，在進入 App 測試之前因「Timed out while enabling automation mode」失敗。將共用 `ios-ui.sh` 的 iPad 分支改為遵循指定的 `DEVELOPER_DIR` 或目前 `xcode-select`，以 Xcode 27 重建 runner 後正常執行。保留原始失敗紀錄；沒有將工具初始化失敗列為產品測試成功。

本輪補齊的是新設施工作台及其登入／升級／生命週期的實機流程。沒有重新驗證推播送達、相機附件、定位打卡、生物辨識、所有多帳號隔離情況或網路中斷。單元測試既有 761 pass／1 skip／0 fail 的結果不冒稱為本輪重新執行。

送審版本未改動，不必因此另上傳 build 或取消審查；實機通過也不代表 Apple 已認定符合 4.3。15:10 重新載入 App Store Connect 並等待版本資料完成載入後，確認 1.0 (6) 仍為「等待審查」，尚未核准上架。

## 證據

完整收據位於工作區 `receipts/apporo-platform-validation-1102/physical-ipad/`，包括：

- `install.json`、`installed-app.json`、`binary-evidence.json`。
- `08-review-desk/`：審查帳號清單與空白表單。
- `10-create-request/`：必填狀態、已填表單、成功提示與任務清單。
- `before.json`、`after-create.json`、`after-cancel.json`、`final.json`：獨立後端核對，未保存憑證或 session cookie。
- `11-lifecycle-cancel/`：背景切回、重開讀回、穩定橫向畫面。
- `14-light-english-launch/`、`15-english-desk/`、`16-english-form/`：淺色與英文畫面。
- `18-final-state/`：恢復設定後的最終工作台畫面。
- `review-status.json`：重新載入後的 Apple 審查狀態。
- 每批 UI 操作保留 `xcodebuild.log`、`log.txt` 與 `result.xcresult`；`receipt.json` 彙總結果與界線。
