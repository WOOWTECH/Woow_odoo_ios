# 離線 unit host 實作計畫

日期：2026-09-24；僅 `feat/apporo-platform-brand-layer` 隔離 worktree。

## 核准範圍

擁有者批准全新專用 Simulator、兩品牌完整 unit tests；此 worker 只做程式與輕量離線驗證，不跑 Xcode/simctl、不讀秘密、不登入 Odoo、不動既有裝置。產品不 stage/commit/push；僅本次兩份計畫先提交。

1. compile-only `UNIT_TEST_HOST`，限 `DEBUG && UNIT_TEST_HOST`；`UNIT_TEST_HOST && !DEBUG` 用 `#error` 拒絕編譯。一般 xcconfig/scheme 不設定旗標。
2. AppDelegate.didFinish 離線分支只安裝 URLProtocol defense-in-depth 並返回；不 processTestLaunchArguments、不 Firebase configure、通知權限/category/APNs。
3. WindowGroup 離線分支為 EmptyView，不建立 AppRootView、不 onOpenURL、不啟動 checkSession；其他 delegate 方法與業務類型保留可直接測試。
4. OdooAPIClient 預設 init 在離線模式明確指定拒絕 HTTP/HTTPS 的 URLProtocol。注入 URLSession 的 init 完全保留；無 runtime env/argument 開關，不改 TestHookGate。
5. 稽核發現 OdooWebViewCoordinatorTests 的外部導航測試會經 UIApplication.open 啟動 Safari。主代理批准 Coordinator init 末尾增加 openExternalURL closure，預設原呼叫；該測試注入 spy，保留 URL、一次 open、一次 cancel 斷言，不跳過案例。

## 安全邊界與稽核

主代理已批准以 app API transport 隔離為可驗證邊界：全域 URLProtocol.registerClass 不是 OS 網路沙箱，不保證攔截任意背景 session、WebKit、SDK。沒有為此關閉套件／簽章驗證。

- 六個原 unit URLSession 建構 seam 均指定 URLProtocol mock，startLoading 回傳本地資料／錯誤，沒有 forwarding transport。
- MultiAccountLogoutTests、ConfigViewModelLogoutTests 雖註解稱 no token，卻用 shared Keychain + 預設 API client；token 污染會觸發 unregister。MissingTests.AccountRepositoryTests 亦可能因共享 password/token 觸發 auth/unregister。離線預設 client 必須拒絕這些请求；不能以域名 grep 宣稱全是 mock。
- AppRootViewModelTests 部分只注入 account repo，push/self-heal 仍為預設；所有 Odoo transport 最終走預設 client 防線。
- WebKit 測試建立空 WKWebView、手動調 delegate 或純決策函式，未見遠端 load；唯一外部 Safari 副作用由上述 DI 消除。
- shared Core Data/Keychain/cookie 測試仍有真本機狀態；只准新專用 Simulator，不覆蓋既有安裝。

## 最小檔案

新增 `odoo/App/OfflineUnitHost.swift`、`odooTests/OfflineUnitHostTests.swift`、`scripts/tests/test_offline_unit_host.py`。
修改 `odoo/App/AppDelegate.swift`、`odoo/odooApp.swift`、`odoo/Data/API/OdooAPIClient.swift`、`odoo/UI/Main/OdooWebView.swift`、`odooTests/MissingTests.swift`，以及本次兩份計畫。

## 非本案驗收

不代表正常 Firebase bootstrap、APNs、登入、WebView/E2E、Release archive 或階段 3 推播契約驗收。原 WOOW scheme/LocationE2E plan 不變；主代理從新編譯產物建立專用 unit-only xctestrun，完整保留 odooTests，移除 UI/live target 與繼承的測試環境設定，不帶 -WoowTestRunner。
