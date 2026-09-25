# 階段3 iOS Apporo push（本機、待review）

基線 ee87a55 + 階段2 dirty；只寫本worktree，不stage/commit產品、不操作Simulator/真服務。不讀Firebase secrets。
依 PHASE3-CONTRACT.md 與 plugin/docs/apporo-push-contract.md。

- 新 PushDeviceRegistrar 集中 Apporo 每次 cap → write，驗 cap/version/brand 及 register echo；WOOW原register healing／unregister不加cap/brand。
- 主代理核准補充：Apporo專用顯式SID API，request不讀寫共享cookie jar、拒絕redirect；不改舊callKw語意。cap和write使用同一捕捉SID；expiry最多一次account-specific reauth後重跑整組。
- SecureStorage新account-ID scoped credential blob另含完整base URL、DB、username身分。只在成功manual login保存；不從host-keyed legacy憑證遷移；缺資料fail-closed、要求重新登入。account-keyed single-flight/circuit，manual login只清該account circuit。reauth不污染共享jar。
- register每次write前確認account仍存在且身分相同；logout/remove可用已捕捉session清理，失效且帳號已移除不再reauth。本地清理始終best-effort。
- PushTokenRepository全部路徑及AccountRepository直接unregister統一adapter；保留tenant回寫、rotation、空帳號replay、既有登入/switch政策。
- 新MainActor account-ID狀態store；Settings顯示當前account狀態（ACK不代表送達）；三語固定訊息不含raw error。
- 保留UNIT_TEST_HOST/default guard/Safari DI/同步MockPushTokenRepository/TestHookGate。

變更面：API scoped seam、PushCredential/PushDeviceRegistrar/PushRegistrationStatus、SecureStorage、PushTokenRepository、AccountRepository、SettingsView與三語、focused XCTest、offline source audit、文件。

## §2.4 最終核准收斂／逾時恢復

- Apporo manual login只發一次isolated authenticate，由回應Set-Cookie取得SID；無效/缺SID是登入session未建立，回本地化server/session錯誤，零新增/activate/credential/jar修改，保留原B。不得清B cookie或向jar借SID。有效SID但cap不支援時仍登入成功，僅push為notConfigured。
- 勝出的login-attempt在同一MainActor區段更新active、scoped及legacy credential與UI cookie；晚到completion不得覆蓋，明確選帳/移除亦使待處理attempt失效。WOOW普通登入保持原路徑。
- captured unregister在cap期間account/credential被刪仍可用原snapshot完成；失效SID且account已移除不得reauth。
- source政策經主代理核准：舊stage2整檔凍結不再涵蓋已授權修改的PushTokenRepository/AccountRepository；改為集中adapter/no-bypass與cap/WOOW分支正負契約。DeepLinkValidator/TestHookGate/PrivacyInfo及普通root保持原保護；legacy SessionHealingRegistrar/SessionReauthenticator對HEAD不變。
- transport inventory只增已讀過、無forwarding的PushDeviceRegistrarTests.swift／PushContractURLProtocol；不放寬任意URLSession，不新增skip。保留既有離線guard、Safari DI與同步MockPushTokenRepository。

## 接受 review 1–4 的限定修正（本轮）

- `PushCredentialStorage` 三個方法與所有 production witness 明確 `@MainActor`；MainActor 為跨所有 store instance 的唯一序列化 owner，不使用 instance lock。heal 的 account 重驗＋credential CAS＋save 在單一無 await MainActor closure；manual commit 同 owner。Apporo logout/remove 先在同 owner 同步 capture/delete/account/status 清理，再 await captured SID cleanup，沒有網路或 actor hop 藏在臨界區。
- operation 帶完整 account snapshot、credential generation、operation revision；完成時同一 MainActor 區段重驗並提交 status＋tenant。PushTokenRepository 不再按 ID 無條件寫 tenant。舊 cleanup 連 revision 都不得覆蓋新 generation。
- `PushHealOutcome` 明確 healed／credentialRejected／superseded／temporarilyUnavailable；timeout/server 暫錯保留 credential、不開 circuit、不發 relogin。
- 同次 auth 回應 cookie 的原始 Foundation properties 保存為不可變可編碼 snapshot，驗 domain/path/expiry；Max-Age 凍結為 absolute expiry，避免重載展延。manual 勝出及尚未到期才發布原 policy；Apporo WebView 消費 account-bound cookie snapshot，不再由 SID 製造 root cookie。WOOW consumer 分支保留。

## 最後複查限定 P1/P2 修正

- Apporo switch 使用 matching scoped credential，同次 isolated authenticate 回應政策；manual/switch 共用 selection attempt，在 MainActor 無 await commit 重驗 attempt、完整 row identity、generation、cookie 有效性後 activate/save/publish。無安全 scoped credential fail-closed 保留原 active；不借 legacy，不改 WOOW。matching cookie 且無 password 才保留不再認證的選帳。
- begin 一般 Apporo operation 先驗 row identity 再取得 revision；captured cleanup 過時身分/generation 僅遠端、不取得新 revision。
- 核准最小 WebView DI（brand/credential/data store/base navigation），production defaults 不變；consumer-chain 使用 nonPersistent store、攔截 base load、等待 cookie completion，禁止真 load/Safari。
