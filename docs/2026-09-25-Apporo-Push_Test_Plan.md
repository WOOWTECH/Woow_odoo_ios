# 階段3 iOS push測試計畫

只跑Python stdlib source contracts與輕量語法檢查；Xcode compile/XCTest由父代理後續序列跑，不執行裝置、Simulator、Odoo或Firebase。

新增URLProtocol injected session測試：WOOW old/new payload不cap/brand；Apporo capability缺失/錯型別/舊version/無brand零write；echo錯誤不成功；expiry在cap/write皆重cap且只heal一次；same-host不同DB/port/user account session分離、不污染共享jar；缺scoped credential拒絕且不借legacy；rotation、logout/remove best effort；account消失阻止register；狀態account keyed、ACK不等於送達。

offline-host audit更新顯式session seam inventory，仍不容許新增未稽核URLSession constructor/skip。既有43項source contracts全部重跑。Swift tests未實跑不能報PASS，source契約不等於runtime驗收。独立review必須完成。

## 最終安全對照

新增/完善缺SID及非法SID保留原B/account/scoped與legacy credential/jar的斷言；有效SID但cap缺失仍成功登入；晚到manual completion與明確選帳使舊attempt失效；captured cleanup在cap期間移除credential後仍可完成。登入失敗與push失敗分開，不以清別帳號cookie解決。

集中Swift檔最終34個XCTest方法，另2個legacy logout URLProtocol fixtures顯式固定WOOW。方法內cap/echo/cleanup迴圈涵蓋多組案例，但未以subcase虛報測試方法數。51個Python source contracts含8個stage3來源/負向mutation檢查。Swift parse僅語法，不是typecheck或XCTest PASS。

## Review 修正測試（本轮）

- 集中 XCTest 34→47 方法（新增13）；既有 single-flight 斷言僅對應 typed outcome，未放寬斷言/skip。
- URLProtocol 受控 hold/release：heal→manual/remove、舊 register/unregister ack/expiry→新 generation、同 generation revision、response 間 identity 變更、stale captured cleanup 與新 operation、remove 遠端清理中重新登入；不用 sleep。
- timeout／HTTP503 保留 credential 並可下一次 heal，與 credentialRejected circuit 區分；只 mock transport。
- cookie domain/path/Secure/HttpOnly/expiry、Max-Age 不展延、non-Secure 原政策保留、JSON persistence roundtrip、jar 範圍及 WebView consumer seam；錯 domain/path/已到期/Max-Age=0 fail-closed。
- Python 51→57 source checks，新增6（正向＋mutation），涵蓋共用 actor/CAS、generation＋revision/status＋tenant 原子提交、cookie policy／consumer；不取代 runtime。

## 最後複查 P1/P2 測試計畫

- 真 AccountRepository → switch → coordinator.apply → WK cookie store：A失效→B→A成功，無FCM，驗新SID與完整policy；injected nonPersistent store/base-load攔截，不執行網路導航。
- deterministic hold/release 驗 switch/manual 雙向及 switch/switch 晚到、identity變更、缺SID與缺scoped fail-closed。
- hold 新register ACK→舊identity snapshot register/unregister開始被superseded→release新ACK；status/tenant可提交，captured cleanup例外保留。
- source正負契約、parse、audit；所有新增XCTest NOT RUN，父序列編譯/執行。
