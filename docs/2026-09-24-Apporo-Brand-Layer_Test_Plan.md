# Apporo iOS 階段 2 測試計畫

狀態（review round 1）：原 20 條 stdlib 全數重跑，加 1 條獨立 provenance、11 條回歸，共 32 tests。指定原稿時 32 PASS／0 FAIL／0 SKIP；不指定時 31 PASS／0 FAIL／1 SKIP（只 provenance）。Swift 7 tests 未執行，完整 runtime 門檻仍 BLOCKED；見同日 Verification.md。

## 本輪可執行（離線低磁碟）

- Python stdlib unittest：四 config 身分／版號／scheme／資源選擇；project/test 映射；Release 無 DEBUG、production APNs 與 audit 必執行。
- 受控資源腳本：缺 Apporo config fail-fast；未知品牌／variant 拒絕；三語 Apporo 名稱／中文權限；不存在同名自動 resource output。資源複製／錯品牌測試只用 synthetic Firebase fixture，不讀真實 credential。
- `test_brand_verification.py`：四配置 provider 主色與接線；WOOW 色不能滿足 Apporo；Firebase 路徑、bundle/project/app/sender 身分正負測，缺 client／verified project 不得 PASS；optional local xcconfig 的 ID override；未知 config 拒絕。只匯入無頂層 I/O helper，不 import/execute `verify_all.py`。
- 四個 test-target `TestAppURLScheme` 與 app configuration 配對；SharedTestConfig 缺值／混配 fail closed；UX26/27/72–75 六處引用所選 scheme。跨品牌拒絕在 `AppBrandTests.test_scheme_givenOtherBrandOrEnvironment_returnsFalse`，不向 OS 開啟另一品牌 URL。
- PNG 產物 hash／尺寸／不透明白底總是執行；原稿 hash 為獨立 provenance test。manifest 的歷史絕對路徑不被自動讀取；可用 `APPORO_ASSET_SOURCE=/path/to/apporo-mark.png` 明確指定。未指定只 SKIP provenance；明確指定錯誤／不存在原稿則 FAIL，不假 PASS。回歸測試證明缺原稿不跳過產物檢查、錯原稿 hash 拒絕。
- shell 語法逐檔 `bash -n`、Python AST、plutil／strings／scheme 結構、git diff --check、hook/theme source audit。legacy live scripts 僅 AST，不執行。

## 已寫但本輪未執行

Swift XCTest：provider 固定期望、錯配置拒絕、兩品牌 links／scheme、預設與固定色、保存色不被覆蓋。既有跨品牌拒絕增加雙向及 Apporo dev 斷言。Swift／UI suite 均未编譯或執行，source 契約不等同 runtime 通過。

## BLOCKED 門檻

1. 四配置 Xcode build／兩 scheme 完整 Swift unit suite：主代理因可用磁碟約 5.4 GiB 暫緩重型 build/test，非擁有者明文禁止所有 build；不下載或清理他人檔案。Apporo 真實 Firebase client／verified project 缺失亦是獨立阻擋。
2. Release archive/debug-hook binary audit：重型建置暫緩且無產物；簽章/APNs/profile 尚缺，離線 source audit 不代替 binary audit。
3. 三語、dark mode、兩品牌 runtime／verify_all／UI/E2E：裝置、模擬器、demo／線上寫入仍未授權；WOOW Debug 不安裝。
4. 階段 3 推播契約未做，Apporo 不得連正式／舊後端宣稱可用。
5. 獨立 reviewer 必須複審三項修正後，方可判斷本機 checked acceptance；完整階段 2／發布門檻仍未通過。

每次記錄 PASS/FAIL/SKIP/BLOCKED 及實際條數，零測試不算 PASS；不印 secrets、不執行既有 live E2E 作為語法檢查。
