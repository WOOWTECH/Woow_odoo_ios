# 階段3 iOS 本機驗證／review handoff

基線：`feat/apporo-platform-brand-layer`，HEAD `ee87a55`，保留階段2 dirty diff。產品與文件均未stage/commit/push。此為逾時恢復後的完成交付，**待獨立review及Swift編譯/runtime，不是發布或部署驗收**。

## 實作邊界

- `PushDeviceRegistrar`集中所有register/unregister（含PushTokenRepository rotation及AccountRepository logout/remove）。Apporo每次write前cap>=2且support apporo，固定brand；register驗echo/version。WOOW不查cap、不傳brand，舊register self-heal及unregister語意保留。
- Apporo顯式SID request停用cookie自動讀寫並拒redirect；cap/write用同一account綁定snapshot，expiry最多一次isolated heal後**重cap**。新credential以account ID＋完整base URL/DB/username/uid綁定，不借legacy host+username keys。
- 依PHASE3-CONTRACT §2.4：manual auth只有同一次回應的有效SID才可成功。缺/非法SID回三語session建立錯誤，**不新增/activate、不改credential、不清/覆蓋原B cookie**。有效SID但cap缺失仍登入成功，只push notConfigured。
- 勝出manual-login attempt在同一MainActor區段更新active、credential及WebView jar；晚到completion/明確選帳會失效。push reauth不發布jar。新login generation只重置該帳號的circuit/single-flight歸屬。
- register檢查account仍存在/身分一致；已捕捉cleanup可在移除後使用原SID完成，原SID失效且row已移除不再reauth。本地logout/remove始終best-effort。
- Settings依active account ID讀推播狀態，三語明示ACK不等於送達；不呈現raw push error。

## 實際檢查

| 命令／檢查 | 結果 |
|---|---|
| 初次 `python3 -m unittest discover -s scripts/tests -v` | 原43：40 PASS、2 FAIL、1既有SKIP。FAIL為stage2 push整檔freeze及新mock不在transport inventory，非隱藏略過；log保留 |
| 更新政策後同命令（無provenance） | 51：50 PASS、1原provenance SKIP，未新增skip |
| 下列帶唯讀PNG來源的完整source命令 | **51 PASS、0 FAIL、0 SKIP**（原43＋新8） |
| 下列Swift parse命令 | exit 0；11檔語法檢查。**不是typecheck/build/XCTest** |
| `bash scripts/audit_test_hook_naming.sh` | PASS，8個既有registered hooks；未動TestHookGate |
| `bash scripts/audit_theme_color_usage.sh` | PASS |
| `git diff --check` | PASS，exit 0 |
| `git diff --cached --name-only` | 空，0 staged |
| `grep -c '    func test_' odooTests/PushDeviceRegistrarTests.swift` | **34個新XCTest方法**；尚未編譯/執行 |

```bash
APPORO_ASSET_SOURCE=/Users/elmolin/WOOW-mobile-app-analysis/sources/Woow_apporo_ha_app/tools/brand/assets/apporo-mark.png python3 -m unittest discover -s scripts/tests -v

swiftc -frontend -parse odoo/Data/API/OdooAPIClient.swift odoo/Data/Push/PushCredential.swift odoo/Data/Push/PushDeviceRegistrar.swift odoo/Data/Push/PushRegistrationStatus.swift odoo/Data/Push/PushTokenRepository.swift odoo/Data/Repository/AccountRepository.swift odoo/Data/Storage/SecureStorage.swift odoo/UI/Settings/SettingsView.swift odooTests/PushDeviceRegistrarTests.swift odooTests/HonestLogoutS4Tests.swift odooTests/LogoutUnregisterURLTests.swift

bash scripts/audit_test_hook_naming.sh
bash scripts/audit_theme_color_usage.sh
git diff --check
git diff --cached --name-only
```

## 測試與source政策

`odooTests/PushDeviceRegistrarTests.swift`的34個方法使用唯一`PushContractURLProtocol`捕捉所有request，script耗盡直接本地失敗、絕不forward：old/new WOOW、cap shape/version/brand拒絕零write、echo錯誤、cap/write expiry與上限、healed cap拒絕、同host不同DB/port/user、jar隔離、legacy拒絕、removed register/captured cleanup、rotation/empty replay、logout/remove、單次manual auth、缺/非法SID保留B、有效SID但cap缺失、晚到completion、明確選帳與single-flight/circuit generation。方法內資料迴圈不另虛報測試數。

兩個舊logout wire fixtures顯式指定`.woowtech`，讓Apporo scheme仍可驗舊wire契約；未刪測試或新增skip。`MockPushTokenRepository`同步lock、Safari DI、default offline guard、UNIT_TEST_HOST與TestHookGate原候選保留。

主代理核准將過期stage2『PushTokenRepository/AccountRepository整檔不變』freeze改為stage3集中adapter/no-bypass/cap/WOOW及負向mutation檢查。未授權的DeepLinkValidator/TestHookGate/PrivacyInfo/root保護仍在；SessionHealingRegistrar/SessionReauthenticator對HEAD不變。transport allowlist**只新增已稽核的新測試URLProtocol constructor**，未允許任意URLSession。額外驗顯式Cookie、停用jar、拒redirect、response SID驗證與缺SID fail-closed的正負mutation。

## 本階段實際changed paths（不含既有階段2-only diff）

- `CLAUDE.md`
- `_bmad-output/project-context.md`
- `docs/2026-09-25-Apporo-Push_Implementation_Plan.md`
- `docs/2026-09-25-Apporo-Push_Test_Plan.md`
- `docs/2026-09-25-Apporo-Push_Verification.md`
- `docs/phase3-ios-validation/source-initial.log`
- `docs/phase3-ios-validation/source-contracts.log`
- `docs/phase3-ios-validation/swift-parse.log`
- `docs/phase3-ios-validation/hook-audit.log`
- `docs/phase3-ios-validation/theme-audit.log`
- `docs/phase3-ios-validation/diff-check.log`
- `odoo/Data/API/OdooAPIClient.swift`
- `odoo/Data/Push/PushCredential.swift`
- `odoo/Data/Push/PushDeviceRegistrar.swift`
- `odoo/Data/Push/PushRegistrationStatus.swift`
- `odoo/Data/Push/PushTokenRepository.swift`
- `odoo/Data/Repository/AccountRepository.swift`
- `odoo/Data/Storage/SecureStorage.swift`
- `odoo/UI/Settings/SettingsView.swift`
- `odoo/Resources/en.lproj/Localizable.strings`
- `odoo/Resources/zh-Hans.lproj/Localizable.strings`
- `odoo/Resources/zh-Hant.lproj/Localizable.strings`
- `odooTests/PushDeviceRegistrarTests.swift`
- `odooTests/HonestLogoutS4Tests.swift`
- `odooTests/LogoutUnregisterURLTests.swift`
- `scripts/tests/test_brand_layer.py`
- `scripts/tests/test_offline_unit_host.py`
- `scripts/tests/test_push_contract.py`

## Log SHA256

位於`docs/phase3-ios-validation/`。空log表示對應工具成功且無stdout/stderr，不是runtime測試證據。

| log | SHA256 |
|---|---|
| source-initial.log | fd88b83eba9bce8e27ad787699de3715f8832a7f08be9c9b6ba99c1cb147fd7b |
| source-contracts.log | 4f9e39036ab493564de7c0f61236f777b766a846b78b9e4c931674208fac47cf |
| swift-parse.log | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
| hook-audit.log | 3c521ca09e117cf469f020c9bfe45a8290a799a6b2f83287a22d14c14a1ef961 |
| theme-audit.log | ef9833318b7805f0bbd78a5b6613f2219f71ca533184f75d619da1de5acf9a0f |
| diff-check.log | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |

## NOT RUN／風險／下一步

- Swift typecheck、Xcode build、34個新XCTest及完整既有suite、兩scheme runtime、archive/簽章均**NOT RUN**，由父代理後續序列驗證。parse/source contracts不能取代它們。
- 獨立review尚未完成，尤其需檢視async/account生命週期、cookie API實際行為、Core Data併發與測試fixture隔離；目前只完成本機來源層自查。
- cap/write間server降版仍是契約禁止的部署競態；已送出的遠端request無法僅靠本地account刪除回收。best-effort cleanup失敗可能留server row，並未宣稱送達/撤銷保證。
- Firebase/profiles/秘密檔未讀；未操作真服務、裝置、Simulator、容器、原repo、商店或部署。只有指定既有PNG原稿做唯讀hash/provenance驗證。
- 下一步：父代理先確認diff/報告完整，再做獨立review及核准的離線Swift序列驗證；不可直接部署或宣稱release-ready。

## 本輪 accepted review 修正交付

上述原 34 XCTest／51 source counts 為上一輪歷史。本輪限定修正 review 全部四項：

1. MainActor 成為所有 PushCredentialStorage instance 的共同 transaction owner（protocol 和 SecureStorage witness 明確隔離）；heal check/save、manual 更新、Apporo 本地 remove 無 await 同區執行。沒有各 instance 私鎖或 lock→actor hop。
2. operation 保存完整 identity／generation／revision；回應/錯誤在同一 MainActor 區段重驗再提交 status＋tenant。舊 cleanup 可以 remote best-effort，但不覆蓋新 generation 或其 revision。Apporo remove 本地交易先完成，remote 清理不再刪除後來 manual login。
3. response cookie properties snapshot 保留 Path/Domain/Secure/HttpOnly/expiry 等 Foundation 已解析政策；Max-Age 凍結 expiry，不製造 root cookie。manual commit 再驗 expiry；WebView Apporo 分支使用 account-bound snapshot。WOOW 舊分支不改。
4. typed heal outcome 區分拒絕、superseded、網路/server 暫錯；暫錯為 temporarilyUnavailable，保留 credential/circuit 可重試。

實際驗證：
- `APPORO_ASSET_SOURCE=/Users/elmolin/WOOW-mobile-app-analysis/sources/Woow_apporo_ha_app/tools/brand/assets/apporo-mark.png python3 -m unittest discover -s scripts/tests -v`：**57 PASS／0 FAIL／0 SKIP**（新增6 source tests），見 `review-source-contracts.log`。
- `swiftc -frontend -parse`：10檔 exit 0，見 `review-swift-parse.log`；**不是 typecheck/XCTest/runtime**。
- `bash scripts/audit_test_hook_naming.sh`：PASS，8 hooks；`bash scripts/audit_theme_color_usage.sh`：PASS。
- `git diff --check`：PASS；`git diff --cached --name-only`：空，0 staged。
- `odooTests/PushDeviceRegistrarTests.swift`：**47 XCTest 方法（本輪＋13）尚未編譯／執行**，包含 deterministic hold/release 正反交錯及 cookie policy／transient cases，沒有 sleep 或新增 skip。

本輪產品檔：`AuthResult.swift`、`OdooAPIClient.swift`、`PushCredential.swift`、`PushDeviceRegistrar.swift`、`PushRegistrationStatus.swift`、`PushTokenRepository.swift`、`AccountRepository.swift`、`SecureStorage.swift`、`OdooWebView.swift`。測試檔：`PushDeviceRegistrarTests.swift`、`scripts/tests/test_push_contract.py`；另更新這三份 push plan/verification，新增 `docs/phase3-ios-validation/review-*.log`。

剩餘 gate：獨立 review；父代理序列 Swift typecheck/build、兩 scheme XCTest 及 URLSession/WKWebView cookie 實際政策驗證。未跑 Xcode/simctl、真登入、裝置、容器、部署；未讀真 Firebase/私鑰/密碼；未 stage/commit/push。source/parse PASS 不宣稱 runtime PASS，也不宣稱 release-ready。

## 最後複查 P1/P2 限定修正交付

本節取代前節的最新數量（歷史結果保留），只處理 recheck 剩餘兩項，不改 Android/backend、WOOW 分支或 session schema。

- **P1**：`AccountRepository.switchApporoAccount` 使用 matching account-scoped password 做同一次 isolated auth；回應 cookie policy 隨 SID 一起保存。在同一 MainActor commit 重驗 manual/switch 共用 attempt、完整 row identity、credential generation、cookie 尚有效且 SID 一致，才 activate、保存 scoped credential、發布原政策 cookie、通知 consumer。不靠 FCM/push heal、不借 jar SID、不製造 root cookie。與 manual login 雙向及 switch/switch 晚到互斥。
- 主代理協調核准：沒有安全 matching scoped credential 時 fail-closed，保留原 active/credential/jar，需手動登入、不借 legacy host-key password。matching credential 無 password 時僅有效 bound cookie 可不再認證選帳；WOOW 無密碼分支不改。
- consumer 測試使用真 repository → switch → coordinator.apply → 真 WK cookie store completion（不是 helper-only），A 舊 cookie 已失效→B→A，無 FCM token，驗新 SID、Domain/Path/Secure/HttpOnly/expiry。最小 DI 預設仍原品牌、SecureStorage、dataStore 與 WK load；指定測試注入 nonPersistent stores 與 base-load 攔截，**不讀/清共享 WK store、不 load、不開 Safari**。offline inventory 只允許這個具名測試的三個 apply 並驗攔截；其他網路/transport 規則不放寬。
- **P2**：`PushDeviceRegistrar.begin` 同一 MainActor 區段先驗 current row identity，過時一般 Apporo caller 直接 superseded，未取得/更改 revision。captured cleanup 在 identity/generation 過時時仍可遠端 best-effort，但不 supersede 新 operation。原 CAS、typed transient、完整 cookie policy 保留。

### 本輪檔案與測試

產品 3：`odoo/Data/Repository/AccountRepository.swift`、`odoo/Data/Push/PushDeviceRegistrar.swift`、`odoo/UI/Main/OdooWebView.swift`。
測試 3：`odooTests/PushDeviceRegistrarTests.swift`、`scripts/tests/test_push_contract.py`、`scripts/tests/test_offline_unit_host.py`。
文件 3：本 verification 與同日期 Apporo-Push Implementation/Test Plan。
證據 6：`docs/phase3-ios-validation/last-{source-contracts,swift-parse,hook-audit,theme-audit,diff-check,staged-files}.log`。

- XCTest **47→56 方法（+9）**，全部 **NOT RUN / 未編譯**。新增 consumer chain、缺/非法 SID、缺 scoped、無 password bound cookie、switch/manual 雙向、switch/switch、held identity/generation、hold 新 ACK→舊 snapshot register/unregister→release 新 ACK 的 status/tenant 提交。
- 2 個既有 removed cleanup 測試改成明確傳入動作前捕捉 credential，維持遠端例外驗證；不是刪測試/skip。
- Python **57→62（+5）PASS，0 FAIL/0 SKIP**，含 switch/identity ordering 的正向及負向 mutation、具名 consumer audit；不代表 runtime PASS。

### 實際命令

```bash
APPORO_ASSET_SOURCE=/Users/elmolin/WOOW-mobile-app-analysis/sources/Woow_apporo_ha_app/tools/brand/assets/apporo-mark.png python3 -m unittest discover -s scripts/tests -v
swiftc -frontend -parse odoo/Data/Repository/AccountRepository.swift odoo/Data/Push/PushDeviceRegistrar.swift odoo/UI/Main/OdooWebView.swift odooTests/PushDeviceRegistrarTests.swift
bash scripts/audit_test_hook_naming.sh
bash scripts/audit_theme_color_usage.sh
git diff --check
git diff --cached --name-only
grep -c '    func test_' odooTests/PushDeviceRegistrarTests.swift
```

結果：62 source PASS；4 Swift 檔 parse exit 0；8 registered hooks audit PASS；theme audit PASS；diff check exit 0；cached files 空（0 staged）；56 XCTest 方法。`last-*.log` 空檔表示 parse/diff/cached 成功但無輸出，不是 XCTest 證據。

### Review 入口／尚未通過的 gate

- `AccountRepository.swift:301`：selection/identity/generation/cookie 無 await commit；WOOW switch 分支保留。
- `PushDeviceRegistrar.swift:34`：先驗 identity 再 revision，captured cleanup 例外。
- `OdooWebView.swift:108`：最小 consumer DI；`PushDeviceRegistrarTests.swift:735` 真 cookie consumer chain、`:950` held ACK regression。
- `scripts/tests/test_offline_unit_host.py:43`：具名 non-network consumer exception；`scripts/tests/test_push_contract.py:95` switch/begin mutations。
- **待獨立 reviewer gate**；父序列 typecheck/build、兩 scheme XCTest、真 WK cookie API 行為仍 NOT RUN。未 Xcode/simctl/網路/裝置/部署、未讀真配置/秘密、未 stage/commit/push。只 source/parse 自查，不宣稱 merge-ready/release-ready。
