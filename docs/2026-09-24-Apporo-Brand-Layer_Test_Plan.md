# Apporo iOS 階段 2 測試計畫

狀態：未驗證；不得以靜態測試取代完整 runtime 驗收。

## 本輪可執行（離線低磁碟）

- Python stdlib unittest：四 config 身分／版號／scheme／資源選擇；project/test 映射；Release 無 DEBUG、production APNs 與 audit 必執行。
- 受控資源腳本：缺 Apporo config fail-fast；未知品牌／variant 拒絕；WOOW 原來源不變；三語 Apporo 名稱／中文權限／六 links；不存在同名自動 resource output。
- provider 使用正向＋無散落品牌字面值負向斷言；保持 onOpenURL validator、FCM 協定未改。
- PNG stdlib 解析尺寸／不透明白底、來源與輸出 SHA256；品牌色白字對比。
- shell 語法、Python AST、plist／strings／scheme 結構、git diff --check、hook/theme audit（真實執行條數記錄）。
- 腳本目標明確且 WOOW 寫入拒絕；未知 bundle 不允許自動清除。

## 新增但本輪禁止執行

Swift XCTest：provider 固定期望值、錯配置拒絕、兩品牌 links 與 scheme、預設與固定色、保存色不被覆蓋。更新既有 WOOW 專用預設斷言支援 Apporo，同時保留 WOOW 明確期望。

## BLOCKED 門檻

1. 四配置 Xcode build（磁碟／未授權）；Apporo 真實 Firebase client 設定缺失。
2. 兩 scheme 完整 Swift unit suite（禁止重型 build/test）。
3. Release archive/debug-hook binary audit、簽章/APNs/profile（未授權及配置缺失）。
4. 三語、dark mode、兩品牌 runtime 回歸／verify_all／UI/E2E（裝置、模擬器、demo 寫入禁止）；WOOW Debug 不安裝。
5. 階段 3 推播契約未做，Apporo 不得連正式／舊後端宣稱可用。
6. 獨立 reviewer 檢查後方可判斷本機 checked acceptance；完整階段 2／發布門檻仍未通過。

每次命令記錄 PASS/FAIL/BLOCKED 及實際測試數，零測試不算 PASS；不印 secrets、不執行既有 E2E 作為語法檢查。
