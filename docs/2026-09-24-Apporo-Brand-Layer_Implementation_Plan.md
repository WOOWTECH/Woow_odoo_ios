# Apporo iOS 階段 2 品牌層實作計畫

狀態：已核准範圍，本機實作／尚未驗收。基線 a50c4df（ios-1.0-b3），分支 feat/apporo-platform-brand-layer。

## 範圍與順序

1. 保留 odoo target/module、WOOW Debug/Release/scheme/1.0(3)，新增 Config xcconfig、ApporoDebug/ApporoRelease 與 apporoodoo shared scheme（1.0/1）。同步 project/app/test configurations、DEBUG、APNs 與 release audit。
2. 新增 App/AppBrand.swift 單一 provider；接 AppSettings、WoowColors/WoowTheme、Login、Settings、權限相關本地化、SecureStorage 與既有 onOpenURL scheme。保存使用者選色與認證／validator 語意。
3. BrandResources（同步 source root 外）選用 InfoPlist.strings 與 Firebase config；排除原自動資源拷貝，宣告 build inputs/outputs。既有 WOOW Firebase 僅引用路徑，Apporo 缺真實配置即阻擋，不造值、不 fallback。AppDelegate 僅 configure 一份並檢查身分。
4. 唯讀來源 Apporo mark 產生獨立 icon/logo/accent assets，記錄 hash/尺寸/處理；所有語系名稱 Apporo platform，品牌署名 APPORO UNION INC. 不推定著作權。
5. 新增 Swift 單元及 Python stdlib／shell 靜態契約驗證；scripts 顯式 bundle/scheme、寫入授權與 WOOW 保護。不執行裝置工具。
6. 更新本機驗證紀錄／context 補充，由主代理安排獨立唯讀審查。產品 diff 保持未 commit、無 staged files。

## 不做

階段 3 register/unregister/capability、plugin/central/aiot、網路、登入、部署、網站／商店、裝置／模擬器、金鑰、依賴安裝均不做。原 worktrees 不修改。Firebase client config 不印內容。Xcode build/unit/E2E 因磁碟與授權列 BLOCKED，不宣稱可發布。

## 主要檔案

Config/*.xcconfig；odoo.xcodeproj/project.pbxproj、xcshareddata/xcschemes/apporoodoo.xcscheme；odoo/Info.plist、App/{AppBrand,AppDelegate}.swift、odooApp.swift、Data/Storage/SecureStorage.swift、Domain/Models/AppSettings.swift、UI/{Theme,Login,Settings}；三語 Localizable.strings、BrandResources/*；Apporo assets；odooTests 品牌／theme／settings 測試；scripts/select_brand_resources.sh、品牌契約與既有驗證腳本。
