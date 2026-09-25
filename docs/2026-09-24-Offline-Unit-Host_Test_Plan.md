# 離線 unit host 測試計畫

日期：2026-09-24。此 worker 不執行 Xcode/simctl/network。

## 新增驗證

- XCTest：離線宿主 didFinish 成功且 Firebase 未 configure、remote registration 未啟動、TestHookGate 無 marker 仍 false；HTTP/HTTPS 預設 API callKw 拒絕且錯誤具離線 guard 身分；直接 protocol 正反方案判斷；顯式注入 canned mock 仍成功，確認全域 registration 不遮蔽 mock。
- 修正現有外部 navigation 測試：spy 收到精確 URL 一次、cancel 一次；不呼叫 Safari。
- Python stdlib source contract：真實 Swift 條件分支與 Release #error；didFinish/WindowGroup 單一離線分支，普通分支保留 Firebase/root；預設 config guard 與注入 init 原狀；一般 config/scheme 無旗標、TestHookGate 不變；session 建構與 mock 清單/非網路 web delegate 呼叫形狀鎖定；正反 mutation tests 防止契約測試成自我證明。
- 跑既有 scripts/tests 離線套件、hook naming audit、git diff --check；最後 index 必須空。

## 主代理待執行門檻

1. 獨立 review（重點：離線分支不可初始化業務依賴、mock precedence、Safari DI 預設等價）。
2. 每品牌一次性 `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG UNIT_TEST_HOST`（shell 需 quote，使 $(inherited) 不被 shell 展開），同時對 app + unit target 生效。Debug / ApporoDebug 的原配置旗標保留；不要把旗標保存一般 xcconfig/scheme。也可在一次性 OTHER_SWIFT_FLAGS 後附 `-DUNIT_TEST_HOST`，但需確認 DEBUG 原旗標存在且兩 target 一致。
3. build-for-testing 必須 `-only-testing:odooTests`；不直接 test 原 WOOW scheme，因其 LocationE2E plan 帶 live UI target/env。不得關閉套件驗證換綠燈。
4. 以新產物的 xctestrun 複本為專用 runner：每 TestConfigurations 只保留 odooTests 的 TestTargets，IsEnabled=true；UI target 完全移除，OnlyTestIdentifiers/SkipTestIdentifiers 不得刪減 unit cases；清除 live 的 EnvironmentVariables/CommandLineArguments，TestHostAdditionalEnvironmentVariables 僅留 XCTest 必需注入。保留新生成 TestBundlePath/TestHostPath/DependentProductPaths/框架 loader metadata；逐項確認無 -WoowTestRunner、WOOW_TEST_*/WOOW_SEED_* 或 live RUN_*。不同格式以實際 schema 為準，不編造欄位。僅專用全新 destination，parallel testing 關閉。
5. 完整兩品牌 unit suite 實跑；新增 host 測試必須被 discovery，既有 TestHookGateTest 四條全通過，既有 skip 需單獨記錄，不新增 skip。若任何漏 stub/guard failure，先分析實際依賴，不取消 guard。
6. Release/ApporoRelease 注入 UNIT_TEST_HOST 且不帶 DEBUG 的 compile 負向 gate 必須失敗於 #error；普通四配置不帶旗標的 compile 回歸。僅 source contract 通過不等於 Swift 編譯已通過。

## 結果分類

本輪 worker 的 Python/source/diff 檢查可報 PASS；Swift runtime、Release compile-negative、兩品牌完整執行未跑，必須標 NOT RUN。offline-host 不覆蓋正常 bootstrap/通知權限/APNs/真 WebView load/Safari 真開啟/E2E/OS 全域封網。

## 本輪輕量結果與實際 runner 結構

- 兩份計畫已先提交：`ee87a55`（原 HEAD `b077db4`）；產品不 stage/commit。
- 新增 6 條 XCTest，尚未編譯／執行；既有外部導航 case 改為 spy，不減少 cases。
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_offline_unit_host.py' -v`：10/10 PASS（含破壞 launch/default guard/mock 的負向 mutation checks）。
- 完整 suite 使用 repo 內 TMPDIR、未設定外部 provenance 輸入：43 條 = 42 PASS + 既有 provenance 1 SKIP，0 failures/errors。SKIP 非 Swift case，也不是新增豁免。
- `bash scripts/audit_test_hook_naming.sh`：8 個原 hook 註冊完整；無新增 runtime hook。
- `git diff --check`、`git diff --cached --exit-code` 通過；原 TestHookGate/TestHookGateTest/WOOW scheme 均無 diff。
- 唯讀檢查已生成外接碟 Apporo xctestrun：實際為 format-1，頂層 `odooTests` 與 `__xctestrun_metadata__`，非 TestConfigurations 格式。現有 EnvironmentVariables/TestingEnvironmentVariables 只列出欄位名稱供稽核，未輸出任何值；沒有 OnlyTestIdentifiers/SkipTestIdentifiers，CommandLineArguments 為空。
- 專用 runner 若維持 format-1，只保留 `odooTests` 和 `__xctestrun_metadata__`。從新編譯結果保留 `TestBundlePath`、`TestHostPath`、`TestHostBundleIdentifier`、`DependentProductPaths`、`IsAppHostedTestBundle`、`TestingEnvironmentVariables` 的 XCTest loader 注入（DYLD/XCInjectBundleInto 等）；`EnvironmentVariables` 不繼承 live/custom 項，`CommandLineArguments=[]`，`InProcessParallelizationEnabled=false`。原產物不可重用作離線證據，必須新編譯 app+tests 並看到 6 條 OfflineUnitHostTests。
- 主代理執行期仍需 `-only-testing:odooTests -parallel-testing-enabled NO` 與唯一專用 destination，不可傳 `-WoowTestRunner`。WOOW 若輸出 format-2，按上節 TestConfigurations/TestTargets 規則移除 UI target，但完整保留 unit cases。保留 XCTest framework injection 與路徑，不靠刪 loader／關驗證換綠燈。
