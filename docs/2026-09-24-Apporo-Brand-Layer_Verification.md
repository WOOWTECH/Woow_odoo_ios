# Apporo iOS 階段 2 本機驗證紀錄

最新狀態（2026-09-25）：**兩品牌普通Debug／Release已build成功，隔離Swift unit各441 PASS／0 FAIL／1既有SKIP（共442），43條Python source contracts通過。** 最新完整證據見 `2026-09-25-Offline-Unit-Host_Verification.md`；以下保留初次建置／修復歷史。正式簽章、正常UI/bootstrap與真推播/E2E仍未驗收，不是可發布聲明。

- 起點：`a50c4df`（ios-1.0-b3）；分支 `feat/apporo-platform-brand-layer`。
- HEAD：`b077db4`，只提交 Implementation_Plan／Test_Plan。所有產品改動留工作目錄 diff，staged files = 0。
- 初次實作未跑重型建置；後續擁有者批准正常Xcode必要套件連線／下載（鎖版不升級），已完成下列無簽章build。仍未操作裝置／模擬器安裝／啟動、登入、部署／商店／網站；未建立Firebase或signing/APNs資源，原repo／其他工作線不修改。

## 真實 Xcode 建置發現與修正（最新）

1. 正常package解析成功後，build發現三語InfoPlist.strings同時由CopyStringsFile與品牌script產生，exit65。
2. 嘗試追加language-independent membership exception，静態測試通過但實際build仍失敗；此假設已撤回，不將靜態綠燈當修好。
3. 改採唯一來源：新worktree只保留 `BrandResources/woowtech/{en,zh-Hans,zh-Hant}.lproj/InfoPlist.strings`，刪除同步source root內3份重複來源；刪除前驗證與a50c4df、BrandResources逐位元組一致。原受保護repo未動。GoogleService-Info.plist仍由原membership exclusion排除。
4. 回歸測試確認同步root不再有InfoPlist.strings、共用Localizable.strings仍在、兩品牌外部來源齊全、WOOW來源與tag bytes一致。
5. `xcodebuild ... -configuration Debug build`：**BUILD SUCCEEDED**（68.7秒）；`Debug -only-testing:odooTests build-for-testing`：**TEST BUILD SUCCEEDED**（21.4秒），僅編譯測試，未執行任何Swift tests。
6. `Release build`：**BUILD SUCCEEDED**（51.4秒）；Release simulator binary hook audit實際跑且PASS。這不是正式簽章archive驗收。
7. Debug／Release實際.app的bundle `io.woowtech.odoo`、1.0／3、scheme `woowodoo`與Firebase非秘密身份均正確；三語InfoPlist.strings與tag及所選來源bytes相同。
8. 全33條離線測試PASS（指定唯讀原稿），plutil與diff檢查PASS，14個pins未變。無產品code commit。

完整命令／執行log與產物檢查見 `~/WOOW-mobile-app-analysis/research/apporo-odoo/validation/ios-woow-debug-unsigned-build-{2,3,4}.{log,json}`、`ios-woow-debug-build-for-testing.{log,json}`、`ios-woow-release-unsigned-build.{log,json}`、`ios-resource-copy-fix-tests.log`、`ios-resource-copy-fix-artifacts.json`。以下初次實作／review round 1為歷史證據，不覆蓋本節結果。

## 初次實作驗證（歷史紀錄；本輪修正證據見下節）

| 命令／檢查 | PASS | FAIL | 說明 |
|---|---:|---:|---|
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_brand_layer.py' -v` | 20 | 0 | 四配置、project/targets/schemes、資源單一輸出、缺配置與錯品牌拒絕、WOOW 原資源、三語、provider 接線、FCM/validator 不變、素材、對比、hooks、測試工具保護 |
| `bash -n scripts/select_brand_resources.sh scripts/audit_release_archive.sh scripts/audit_test_hook_naming.sh scripts/audit_theme_color_usage.sh` | 4 | 0 | 四檔語法，非 archive binary audit |
| Python `ast.parse` 六檔（brand_test_target、generate_apporo_assets、tests/test_brand_layer、verify_all、e2e-fcm-test、ios_chaos_hprime） | 6 | 0 | 只解析；不執行 legacy E2E |
| `plutil -lint odoo.xcodeproj/project.pbxproj odoo/Info.plist` | 2 | 0 | Xcode project/plist 結構，不代表 Xcode build |
| `bash scripts/audit_test_hook_naming.sh` | 1 | 0 | 實查 8 個既有 hook，兩份 registry 同步補齊；無新增 hook |
| `bash scripts/audit_theme_color_usage.sh` | 1 | 0 | 主色 provider 直接繞過 theme 亦納入稽核 |
| `git diff --check` | 1 | 0 | 工作目錄 diff 空白檢查 |
| `git diff --cached --name-only`（空） | 1 | 0 | 無 staged files |
| **合計：本輪離線檢查** | **36** | **0** | 非 36 個 Swift/Xcode tests；其中 unittest 是 20 tests |

素材生成命令（成功）：

```sh
python3 scripts/generate_apporo_assets.py --source /Users/elmolin/WOOW-mobile-app-analysis/sources/Woow_apporo_ha_app/tools/brand/assets/apporo-mark.png
```

只讀原 PNG；1024×1024 mark 不裁切、不縮放，alpha 疊白底後輸出 RGB opaque icon/logo。輸入／输出 SHA256 在 `BrandResources/asset-manifest.json`。Apporo 主色白字 WCAG 對比 **4.969:1**；iOS 現有設計無獨立 dark/light 色階，保留 `WoowTheme.scheme(for:)` 與系統 dark mode，未發明額外色階或改 WOOW 色值。

## BLOCKED（6 類門檻；全部未執行）

1. Apporo Firebase 真 client 檔／經核實 project ID 尚無（兩 variant 均故意 fail-fast）；signing profiles/APNs 配置尚未建立。
2. 四配置 Xcode build／實際 asset 打包：主代理因可用磁碟約 5.4 GiB 暫緩重型建置，非擁有者明文禁止所有 build；Apporo Firebase 缺失亦獨立阻擋。
3. 兩 scheme 全 Swift unit suite：同上磁碟因素暫緩；新增 `AppBrandTests` **7 個**方法及既有測試調整均未编譯／執行。
4. 兩 Release archive／實際 binary hook audit：重型建置暫緩且無產物／簽章；靜態檢查不能代替真正 binary 掃描。
5. 三語、dark mode、完整 WOOW/Apporo UI/裝置／simulator/`verify_all.py` 回歸：未授權；WOOW Debug 共用正式 ID，不可安裝。
6. live E2E／推播：階段 3 client/backend capability/register/unregister 未實作。經主代理核准，`e2e-fcm-test.py`、`ios_chaos_hprime.py` 無 bypass 地先阻擋，避免舊固定 tenant/row/config 寫錯環境。只以 AST 及純 gate 函式驗證無前置副作用，未執行兩工具。

## 設計與審查焦點

- WOOW 原 Debug/Release/scheme、bundle、URL scheme、1.0(3)、InfoPlist.strings、Firebase source、原 assets／FCM／validator／帳號語意保留。
- Apporo default/fixed theme、三語名稱、logo、六 links、mail、neutral signature 由 provider 選擇；保存色不被覆蓋。onOpenURL 僅換 scheme 判斷，無新增 host/validator 行為。
- 受控 resource phase 有 inputs/outputs、排除同步 root 舊自動拷貝來源，僅輸出一份 Firebase 及每語系一份 InfoPlist.strings；WOOW Firebase 保留原檔路徑引用，Apporo 檔位於同步 source root 外且 gitignored。
- Apporo 新 scheme 預設只跑 unit，不繼承原 LocationE2E live test plan；原 `odoo.xcscheme` byte-identical。
- `SharedTestConfig` 品牌身分與 URL scheme 取 test-target build metadata，避免舊 TestConfig 品牌值反蓋。
- 稽核已覆蓋 ApporoRelease，但 Xcode sandbox/input-output 排程及真正簽章打包仍需重型驗證。
- 未決產品選擇：無新增。已知配置／授權／review 門檻仍未解除；不推定 copyright 移轉，不捏造 Firebase 值。

## Review round 1：三項修正及重新驗證

- P1 iV07b/iV36：新增 `scripts/brand_verification.py`，四配置固定期望值驗 provider 主色／theme 接線、Firebase 所選來源、BUNDLE_ID／PROJECT_ID／GOOGLE_APP_ID／GCM_SENDER_ID。`verify_all.py` 僅擷取非秘密欄位；沒有 client 或 verified project、WOOW 來源／身分、錯 dev/prod、sender/app 不匹配均不能 PASS。未 import／execute live main。
- P1 六個 URL 入口：`project.pbxproj` 四個 UI-test 配置加入 TestAppURLScheme；`SharedTestConfig.appURLScheme` 無 fallback 且檢查 bundle/scheme 配對。`E2E_HighPriority_Tests.swift` UX26/27、`E2E_MediumPriority_Tests.swift` UX72–75 使用所選 scheme。`AppBrandTests` 保留並加強純函式雙向跨品牌／dev 拒絕，不啟動另一品牌。
- P2 provenance：`test_brand_layer.py` 分離原稿查核，`APPORO_ASSET_SOURCE` 為顯式輸入。manifest 原歷史來源保留，非必要作者路徑；未指定只有 provenance SKIP。所有 repo-contained 產物 SHA256／1024×1024／RGB opaque／白底角落檢查照跑。資源腳本原有 tests 改以臨時 mock client 執行，不讀實際 Firebase credential。
- 本輪新增 `test_brand_verification.py` 11 條回歸；原 20 條保留，另拆出 provenance 1 條，共 **32 tests**。Swift 仍為 7 個方法，僅加強既有 scheme 案例。

### 實際命令與結果（不把重跑累加為測試條數）

| 命令 | PASS | FAIL | SKIP | 備註 |
|---|---:|---:|---:|---|
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_brand*.py' -v` | 31 | 0 | 1 | 32 tests；原稿未指定只 skip provenance，產物照跑 |
| `APPORO_ASSET_SOURCE=/Users/elmolin/WOOW-mobile-app-analysis/sources/Woow_apporo_ha_app/tools/brand/assets/apporo-mark.png PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p 'test_brand*.py' -v` | 32 | 0 | 0 | 本機顯式原稿唯讀核對；命令路徑只是本次證據，不是 checkout 必備 |
| `for script in scripts/select_brand_resources.sh scripts/audit_release_archive.sh scripts/audit_test_hook_naming.sh scripts/audit_theme_color_usage.sh; do bash -n "$script" || exit; done` | 4 | 0 | 0 | 逐檔解析，非執行 archive audit |
| Python `ast.parse`（下列 8 檔） | 8 | 0 | 0 | 只解析、不 import live main |
| `plutil -lint odoo.xcodeproj/project.pbxproj odoo/Info.plist` | 2 | 0 | 0 | 非 Xcode build |
| `bash scripts/audit_test_hook_naming.sh` | 1 | 0 | 0 | 8 registered hooks，無新增 hook |
| `bash scripts/audit_theme_color_usage.sh` | 1 | 0 | 0 | source audit |
| `git diff --check` | 1 | 0 | 0 | 工作目錄空白檢查 |
| `test -z "$(git diff --cached --name-only)"` | 1 | 0 | 0 | staged files = 0 |

AST 命令：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import ast
from pathlib import Path
files = ['brand_test_target.py', 'brand_verification.py', 'generate_apporo_assets.py',
         'tests/test_brand_layer.py', 'tests/test_brand_verification.py',
         'verify_all.py', 'e2e-fcm-test.py', 'ios_chaos_hprime.py']
for file in files:
    ast.parse((Path('scripts') / file).read_text(), filename=file)
    print('PASS AST', file)
PY
```

首次 round-1 suite 為 30 PASS／1 FAIL／1 SKIP：`test_missing_verified_project_fails_before_output` 改用 mock input 後，舊斷言誤把 fixture 本身視作腳本 output。修為「目錄僅含已建立 fixture、無 app output」後，以上兩次全套重跑皆通過；不隱藏初次失敗，不把預期負向拒絕列 FAIL。

**BLOCKED 未解除：** Xcode build/unit/archive 因主代理磁碟不足暫緩（非使用者一律禁 build）；Firebase／signing 缺設定；runtime、裝置／simulator／Odoo／線上寫入仍未授權；phase 3 未做；獨立 reviewer 複審仍必要。本輪無網路、下載、裝置、雲端／商店、其他工作線寫入，無 stage/commit/push。此證據不表示階段 2 完成或可發布。
