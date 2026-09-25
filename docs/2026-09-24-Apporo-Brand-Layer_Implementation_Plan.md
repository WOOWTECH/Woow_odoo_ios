# Apporo iOS 階段 2 品牌層實作計畫

狀態：已完成本機 diff，離線檢查通過；未編譯／runtime 未驗證、待 reviewer，不宣稱完成驗收。基線 a50c4df（ios-1.0-b3），分支 feat/apporo-platform-brand-layer。

## 範圍與順序

1. 保留 odoo target/module、WOOW Debug/Release/scheme/1.0(3)，新增 Config xcconfig、ApporoDebug/ApporoRelease 與 apporoodoo shared scheme（1.0/1）。同步 project/app/test configurations、DEBUG、APNs 與 release audit。
2. 新增 App/AppBrand.swift 單一 provider；接 AppSettings、WoowColors/WoowTheme、Login、Settings、權限相關本地化、SecureStorage 與既有 onOpenURL scheme。保存使用者選色與認證／validator 語意。
3. BrandResources（同步 source root 外）選用 InfoPlist.strings 與 Firebase config；排除原自動資源拷貝，宣告 build inputs/outputs。既有 WOOW Firebase 僅引用路徑，Apporo 缺真實配置即阻擋，不造值、不 fallback。AppDelegate 僅 configure 一份並檢查身分。
4. 唯讀來源 Apporo mark 產生獨立 icon/logo/accent assets，記錄 hash/尺寸/處理；所有語系名稱 Apporo platform，品牌署名 APPORO UNION INC. 不推定著作權。
5. 新增 Swift 單元及 Python stdlib／shell 靜態契約驗證；scripts 顯式 bundle/scheme、寫入授權與 WOOW 保護。不執行裝置工具。經主代理追加核准：兩支 legacy live E2E 有固定後端 row/tenant/config，入口無 bypass 地 fail-closed（在 imports／憑證讀取／副作用之前），留待階段 3 另批修復，不假裝改 bundle 即可安全執行。
6. 更新本機驗證紀錄／context 補充，由主代理安排獨立唯讀審查。產品 diff 保持未 commit、無 staged files。

## 不做

階段 3 register/unregister/capability、plugin/central/aiot、網路、登入、部署、網站／商店、裝置／模擬器、金鑰、依賴安裝均不做。原 worktrees 不修改。Firebase client config 不印內容。主代理因開工時磁碟僅約 5.4 GiB 暫緩 Xcode 重型 build/unit/archive，並非擁有者明文禁止所有 build。裝置／模擬器／E2E／線上寫入仍未授權；Apporo Firebase／簽章缺失亦獨立列 BLOCKED，不宣稱可發布。

## 獨立審查修正 round 1（僅三項）

1. `scripts/brand_verification.py` 提供可離線匯入的品牌色／Firebase 身分 validators；`verify_all.py` iV07b/iV36 依 TARGET.configuration 驗 provider 接線、專屬來源路徑與非秘密識別欄位。不刪斷言，不匯入／執行 live main；WOOW 來源、錯品牌、缺設定均不通過。
2. 四個 UI-test configuration 增加 `TestAppURLScheme`；`SharedTestConfig.appURLScheme` 驗 bundle/scheme 配對且無舊 fixture fallback。UX26/27/72–75 六處只開所選 scheme；跨品牌拒絕保留於無 OS 啟動的 `AppBrandTests`。
3. 素材產物 hash／尺寸／RGB opaque 白底檢查留在 repo-contained test；原稿 provenance 獨立以 `APPORO_ASSET_SOURCE` 指定，未指定只 SKIP 該條。manifest 歷史來源記錄保留，不把作者絕對路徑當必要輸入。資源腳本測試改用臨時 synthetic client，避免讀取真實憑證。

完整指令、實際數目及首次測試失敗／修正紀錄見 Verification.md；不 stage/commit/push，其他已審產品碼不動。

## 主要檔案

Config/*.xcconfig；odoo.xcodeproj/project.pbxproj、xcshareddata/xcschemes/apporoodoo.xcscheme；odoo/Info.plist、App/{AppBrand,AppDelegate}.swift、odooApp.swift、Data/Storage/SecureStorage.swift、Domain/Models/AppSettings.swift、UI/{Theme,Login,Settings}；三語 Localizable.strings、BrandResources/*；Apporo assets；odooTests 品牌／theme／settings 測試；scripts/select_brand_resources.sh、品牌契約與既有驗證腳本。
