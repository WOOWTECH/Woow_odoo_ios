# 離線單元測試宿主驗證（2026-09-25）

## 結果

| 組態 | 已發現案例 | PASS | FAIL | SKIP |
|---|---:|---:|---:|---:|
| ApporoDebug＋UNIT_TEST_HOST | 442 | 441 | 0 | 1 |
| Debug（WOOW）＋UNIT_TEST_HOST | 442 | 441 | 0 | 1 |
| Python source contracts（指定原稿） | 43 | 43 | 0 | 0 |

兩品牌均實際跑到6個OfflineUnitHostTests、4個原TestHookGateTest及2個並行mock回歸，沒有0條測試假成功。唯一既有skip是私有request-id helper的直接測試，理由與原始碼保留；未新增skip／刪案例。

## 失敗修正與界限

1. 初次CODE_SIGNING_ALLOWED=NO的Simulator host缺有效application-identifier，Keychain產生-34018。改用**本機Simulator ad-hoc identity `-`**產生模擬權限後，17條安全＋Keychain smoke全部PASS；不用Apple憑證／私鑰，沒有profiles或portal操作。
2. WOOW首次全suite發現MockPushTokenRepository未同步Array的競爭，callback兩次但只記1筆。只在TestDoubles加NSLock、snapshot、鎖外callback，不改產品推播。新增256並行任務記錄完整性及callback重入測試，舊嚴格斷言不變。
3. offline host與mock修复各經獨立唯讀審查，均No issues found／OK with notes（限各自scope）。

## 普通產品回歸

新源碼不帶UNIT_TEST_HOST的Debug／Release／ApporoDebug／ApporoRelease四配置Simulator build全部成功；四個普通binary不含OfflineUnitHost.NetworkDenied marker，兩個Release的原debug-hook binary audit通過。

以Swift編譯器對OfflineUnitHost.swift加UNIT_TEST_HOST、不加DEBUG，觀察到預期#error；此為guard檔compile-negative，不是整套Xcode錯旗標build。

## 隔離與證據

僅使用新UDID `561AB997-DCD8-4DC3-BD73-3041F1FB40E8`（iPhone17／iOS26.5／en-US）。從新xctestrun保留unit-only target，清live env／args，移除WOOW的UI target及其2個runner dependencies；保留XCTest loader、關閉parallel。模擬器測完已shutdown，原13台狀態未變。

結果：
- `/Volumes/WOOW-BUILD/apporo-odoo-build/unit-tests/Results/apporo-full-unit-3.xcresult`
- `/Volumes/WOOW-BUILD/apporo-odoo-build/unit-tests/Results/woow-full-unit-2.xcresult`
- `~/WOOW-mobile-app-analysis/research/apporo-odoo/UNIT-TEST-EXECUTION.md`
- 該研究目錄 `validation/swift-unit-final-results.json`、`ios-normal-configurations-post-unit-regression.json`、`swift-unit-final-safety-check.json`。

原6個受保護repo HEAD／乾淨狀態不變。新iOS HEAD `ee87a55`只有計畫文件提交，產品碼未stage／commit／push。正常Firebase bootstrap、APNs、真Odoo登入、UI／實機、正式device archive與E2E仍未驗收；不得把本輪unit結果當作可發布聲明。
