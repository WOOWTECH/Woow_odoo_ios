//
//  StoreScreenshotTests.swift
//  odooUITests
//
//  App Store / Play 送審截圖擷取器。
//
//  為什麼是 XCUITest 而不是 screencapture / AppleScript
//  ────────────────────────────────────────────────
//  2026-09-18 EP-05 實測結論（已記錄在 screenshots-store/INVENTORY.md）：
//    • AppleScript `keystroke` 送不進模擬器文字欄位（實測三次，欄位停在 placeholder）
//    • `xcrun simctl` 沒有文字輸入 API
//    • `simctl privacy` 的 service 清單不含 `notifications`，
//      所以通知授權對話框無法用指令關掉，只能「點」
//    • iPad 上用純座標點擊關不掉那個對話框 → `ipad-13-01-login.png` 整張被遮住報廢
//  只有 XCUITest 同時具備「能打字」和「能點 Springboard 上的系統對話框」。
//
//  預設不執行
//  ─────────
//  整個 class 在 `setUpWithError()` 就 `XCTSkipUnless(storeScreenshotsEnabled)`，
//  未設 `RUN_STORE_SCREENSHOTS=1` 時一律 skip，不會污染一般回歸。
//
//  執行方式（憑證與參數全部走 `TEST_RUNNER_` 前綴才會抵達 runner 行程）
//  ─────────────────────────────────────────────────────────────
//    TEST_RUNNER_RUN_STORE_SCREENSHOTS=1 \
//    TEST_RUNNER_STORE_SHOT_PREFIX=ios-69 \
//    TEST_RUNNER_STORE_SHOT_LOCALE=zh-Hant \
//    TEST_RUNNER_STORE_SHOT_DIR=/abs/path/screenshots-store \
//    xcodebuild test-without-building \
//      -project odoo.xcodeproj -scheme odoo \
//      -destination 'platform=iOS Simulator,id=<UDID>' \
//      -only-testing:odooUITests/StoreScreenshotTests
//
//  祕密處置
//  ───────
//  密碼只從 `SharedTestConfig.storeShotPassword`（env / plist）讀取，
//  **沒有預設值**、不印進 log、不寫進檔名。沒給密碼就 skip 登入後的畫面，
//  絕不以假資料或 mock 冒充已登入畫面。
//

import XCTest

final class StoreScreenshotTests: XCTestCase {

    // MARK: - 本地化字串表
    //
    // 送審素材要跟 App Store 該語系的列表一致，所以截圖流程必須能切語系；
    // 一旦切了語系，英文 selector 就全數失效（既有 E2E 之所以硬鎖 `-AppleLanguages (en)`
    // 就是為了規避這件事）。這裡把 selector 需要的字串按語系列表，
    // 值全部取自 `odoo/Resources/<locale>.lproj/Localizable.strings` 的實際譯文。
    private struct UIStrings {
        let appleLanguages: String
        let appleLocale: String
        /// 伺服器欄位 placeholder。三個語系的 .strings 都沒有這個 key，
        /// SwiftUI 會原樣回傳 key 本身，所以各語系相同。
        let serverPlaceholder = "example.odoo.com"
        let databasePlaceholder: String
        let next: String
        let usernamePlaceholder: String
        let passwordPlaceholder: String
        let login: String
        let configurationTitle: String
        let addAccount: String
        let logoutCurrentAccount: String
        let logoutAction: String

        static let zhHant = UIStrings(
            appleLanguages: "(zh-Hant)",
            appleLocale: "zh_TW",
            databasePlaceholder: "輸入資料庫名稱",
            next: "下一步",
            usernamePlaceholder: "使用者名稱或電子郵件",
            passwordPlaceholder: "輸入密碼",
            login: "登入",
            configurationTitle: "設定",
            addAccount: "新增帳號",
            logoutCurrentAccount: "登出目前帳號",
            logoutAction: "登出"
        )

        static let english = UIStrings(
            appleLanguages: "(en)",
            appleLocale: "en_US",
            databasePlaceholder: "Enter database name",
            next: "Next",
            usernamePlaceholder: "Username or email",
            passwordPlaceholder: "Enter password",
            login: "Login",
            configurationTitle: "Configuration",
            addAccount: "Add Account",
            logoutCurrentAccount: "Log out current account",
            logoutAction: "Log out"
        )

        static func forLocale(_ locale: String) -> UIStrings {
            locale.lowercased().hasPrefix("zh") ? .zhHant : .english
        }
    }

    private var app: XCUIApplication!
    private var strings: UIStrings!
    /// 寫得進去的輸出目錄；`nil` 代表兩條路都失敗，只剩 XCTAttachment。
    private var resolvedOutputDir: URL?

    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    // MARK: - Setup

    override func setUpWithError() throws {
        try XCTSkipUnless(
            SharedTestConfig.storeScreenshotsEnabled,
            "商店截圖流程預設關閉 —— 需 RUN_STORE_SCREENSHOTS=1（xcodebuild 請用 TEST_RUNNER_ 前綴）"
        )
        continueAfterFailure = false

        strings = UIStrings.forLocale(SharedTestConfig.storeScreenshotLocale)
        resolvedOutputDir = Self.prepareOutputDirectory()

        app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", strings.appleLanguages,
            "-AppleLocale", strings.appleLocale,
            // 這支測試**刻意不帶** `-WoowTestRunner`。
            //
            // CLAUDE.md § Debug Test Hooks 要求的是「每一次讀取 WOOW_TEST_* /
            // WOOW_SEED_* 都必須經過 TestHookGate」，而本流程一個 hook 都沒有注入，
            // 所以不帶旗標並未繞過任何把關。
            //
            // 帶了反而會壞事：旗標會開啟 `E2EWebViewProbe`，它在 key window 上掛一排
            // 半透明的診斷標籤（y=60 起），把 WebView 當前網址與裝置識別字串畫在畫面
            // 最上方。那些字會**進到截圖裡**，等於把示範站主機名與裝置識別碼印在
            // 公開的商店素材上（ios-69 run4 實際拍到）。商店素材必須是正式外觀。
            // 關掉系統鍵盤的拼字檢查／自動修正／預測。
            // 送審素材不得出現紅色波浪線，而 `app.tester.a@woowtest.invalid`
            // 這種帳號在拼字檢查下一定會被畫線（ipad-run3 的 03 實拍到）。
            // 這三個是 Apple 的 NSGlobalDomain 鍵，用 `-key value` 當啟動參數
            // 只影響這一次執行，不改模擬器的任何持久設定，
            // 也不是 App 自己的 debug hook（與 WOOW_TEST_* 註冊表無關）。
            "-KeyboardCheckSpelling", "NO",
            "-KeyboardAutocorrection", "NO",
            "-KeyboardPrediction", "NO",
        ]

        print("[StoreShot] locale=\(SharedTestConfig.storeScreenshotLocale) " +
              "prefix=\(SharedTestConfig.storeScreenshotPrefix) " +
              "outputDir=\(resolvedOutputDir?.path ?? "<attachment only>")")
    }

    // MARK: - 測試一：不需要任何密碼就能拍的兩個畫面

    /// 畫面 1（登入頁）、2（伺服器資訊已填）、3（憑證輸入，密碼欄位已填）。
    ///
    /// `LoginViewModel.goToNextStep()` 只做本機格式驗證、不連線，
    /// 所以憑證步驟不需要任何真實密碼就能抵達，這裡填的是一串佔位字元。
    ///
    /// ⚠️ 實拍結果：**密碼欄位在截圖裡是空的，連圓點都沒有**。
    /// `SecureField` 底層是 `isSecureTextEntry` 的 UITextField，iOS 會把它的
    /// 內容排除在系統截圖與螢幕錄影之外（`XCUIScreen.screenshot()` 走的就是
    /// 系統截圖服務）。欄位確實有值 —— ipad-run4 / iphone-run1 的
    /// `[StoreShot][Field]` log 量到 value 長度 10 —— 只是畫不出來。
    /// 這是平台行為，不是流程失誤；反過來說也保證了截圖永遠不可能洩漏密碼。
    func test_captureLoginAndCredentialScreens() throws {
        app.launch()

        dismissSystemAlertsIfPresent(reason: "launch")
        try goToLoginForm()

        let serverField = app.textFields[strings.serverPlaceholder]
        try assertExists(serverField, "登入頁的伺服器欄位沒有出現")
        capture("01-login")

        fillField(serverField, with: SharedTestConfig.storeShotServer, label: "伺服器網址")

        let dbField = app.textFields[strings.databasePlaceholder]
        try assertExists(dbField, "資料庫欄位沒有出現（locale=\(SharedTestConfig.storeScreenshotLocale)）")
        fillField(dbField, with: SharedTestConfig.storeShotDatabase, label: "資料庫")

        // 收鍵盤，避免鍵盤蓋掉半張截圖
        dismissKeyboard()
        capture("02-server-filled")

        let nextButton = app.buttons[strings.next]
        try assertExists(nextButton, "「\(strings.next)」按鈕沒有出現")
        nextButton.tap()

        let userField = app.textFields[strings.usernamePlaceholder]
        try assertExists(userField, "憑證步驟沒有出現")
        fillField(userField, with: SharedTestConfig.storeShotUser, label: "使用者名稱")

        let passField = app.secureTextFields[strings.passwordPlaceholder]
        try assertExists(passField, "密碼欄位沒有出現")
        // 故意不是真密碼，而且不會按下登入。
        // 用 ASCII —— XCUITest 的 typeText 只能送模擬器鍵盤打得出來的字元。
        fillField(passField, with: "XXXXXXXXXX", label: "密碼（佔位）")

        dismissKeyboard()
        capture("03-credentials")

        // 不按登入 —— 這支測試不做任何認證請求。
    }

    // MARK: - 測試二：需要真實密碼才能拍的兩個畫面

    /// 畫面 4（主畫面，真實 Odoo 內容）、5（帳號清單 / 多帳號）。
    ///
    /// 沒有注入密碼就 skip。**不會**用 mock、假畫面或舊素材頂替。
    func test_captureLoggedInScreens() throws {
        guard let password = SharedTestConfig.storeShotPassword else {
            throw XCTSkip(
                "缺少 STORE_SHOT_PASSWORD —— 主畫面與帳號清單這兩張截圖無法擷取。" +
                "請由 owner 以 TEST_RUNNER_STORE_SHOT_PASSWORD 環境變數注入後重跑；" +
                "本流程不會以 mock 或舊素材頂替。"
            )
        }

        app.launch()
        dismissSystemAlertsIfPresent(reason: "launch")
        try goToLoginForm()

        let serverField = app.textFields[strings.serverPlaceholder]
        try assertExists(serverField, "登入頁的伺服器欄位沒有出現")
        fillField(serverField, with: SharedTestConfig.storeShotServer, label: "伺服器網址")

        let dbField = app.textFields[strings.databasePlaceholder]
        try assertExists(dbField, "資料庫欄位沒有出現")
        fillField(dbField, with: SharedTestConfig.storeShotDatabase, label: "資料庫")

        app.buttons[strings.next].tap()

        let userField = app.textFields[strings.usernamePlaceholder]
        try assertExists(userField, "憑證步驟沒有出現")
        fillField(userField, with: SharedTestConfig.storeShotUser, label: "使用者名稱")

        let passField = app.secureTextFields[strings.passwordPlaceholder]
        try assertExists(passField, "密碼欄位沒有出現")
        fillField(passField, with: password, label: "密碼")   // 只在這裡用，不印、不存

        app.buttons[strings.login].tap()

        // 主畫面專屬的漢堡選單 —— 不能用 app 名稱判斷，登入頁與主畫面**都**顯示
        // "\(SharedTestConfig.appDisplayName)"，用它判斷會在還停在登入頁時誤判成功。
        let menu = app.buttons["line.3.horizontal"]
        try assertExists(menu, "登入後沒有進到主畫面", timeout: 90)

        // WebView 內容需要時間；等畫面穩定再拍，否則拍到空白或 loading spinner。
        sleep(8)
        dismissSystemAlertsIfPresent(reason: "post-login")
        dismissPasswordSaveSheetIfPresent()
        sleep(3)
        capture("04-main")

        guard let addAccount = openConfigSheet() else {
            captureFailureEvidence("config-sheet-not-opened")
            XCTFail("開不了 ConfigView，帳號清單畫面無法擷取")
            return
        }
        _ = addAccount        // 只用它確認 sheet 真的開了，不點
        sleep(2)
        capture("05-accounts")
    }

    // MARK: - 流程輔助

    /// 把 App 帶到「登入表單」這個已知起點。
    ///
    /// iOS 模擬器的 App 資料容器與鑰匙圈**不會**因為重新安裝而清空
    /// （要 `simctl erase` 才會消失，而清資料在本輪禁止清單內）。
    /// 容器若殘留帳號，App 一啟動就直接進主畫面，截圖流程會在第一步就失敗。
    /// 這裡走**產品自己的登出流程**，不直接改資料庫。
    private func goToLoginForm(maxAccounts: Int = 5) throws {
        for round in 0..<maxAccounts {
            if app.textFields[strings.serverPlaceholder].waitForExistence(timeout: 8) { return }

            let menu = app.buttons["line.3.horizontal"]
            guard menu.waitForExistence(timeout: 20) else {
                captureFailureEvidence("neither-login-nor-main")
                throw XCTSkip("App 既不在登入頁也不在主畫面 —— 已存證據，人工判讀")
            }
            print("[StoreShot] logout round \(round): 容器殘留帳號，走產品登出流程")
            menu.tap()

            // SwiftUI 的 Label(_:systemImage:) 會把 identifier 設成 SF Symbol 名稱、
            // label 設成文字，兩者都可能被匹配到 —— 兩條路都試。
            let byText = app.buttons[strings.logoutCurrentAccount]
            let bySymbol = app.buttons["rectangle.portrait.and.arrow.right"]
            let logoutRow = byText.waitForExistence(timeout: 10) ? byText : bySymbol
            guard logoutRow.exists else {
                if app.buttons["xmark"].exists { app.buttons["xmark"].tap() }
                continue
            }
            logoutRow.tap()

            let confirm = app.alerts.buttons[strings.logoutAction]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            sleep(3)
        }

        guard app.textFields[strings.serverPlaceholder].waitForExistence(timeout: 10) else {
            captureFailureEvidence("logout-loop-exhausted")
            throw XCTSkip("登出 \(maxAccounts) 輪後仍回不到登入頁 —— 已存證據")
        }
    }

    /// 開啟 ConfigView（帳號清單）並回傳 Add Account 按鈕；失敗回 nil。
    ///
    /// 需要重試：登入後主畫面的 WebView 仍在載入，此時點選單有機會落空，
    /// 或 sheet 只開到一半就被重繪打斷。每輪都重新查詢元素（XCUIElement 是惰性查詢）。
    private func openConfigSheet(retries: Int = 4) -> XCUIElement? {
        for attempt in 0..<retries {
            if app.staticTexts[strings.configurationTitle].waitForExistence(timeout: 2) {
                if app.buttons[strings.addAccount].waitForExistence(timeout: 5) {
                    return app.buttons[strings.addAccount]
                }
                if app.buttons["plus.circle"].exists { return app.buttons["plus.circle"] }
                if app.buttons["xmark"].exists { app.buttons["xmark"].tap() }
                sleep(2)
                continue
            }

            let menu = app.buttons["line.3.horizontal"]
            guard menu.waitForExistence(timeout: 20) else { sleep(3); continue }
            sleep(UInt32(2 + attempt * 2))
            // ⚠️ 不可用 `isHittable` 當閘門：主畫面的 line.3.horizontal 是 NavigationBar 內
            // 被多層透明 Other 包住的 SwiftUI toolbar item，命中點落在覆蓋層上，
            // isHittable 會誤判為 false，但 tap() 本身會成功（EP-D1 run1.log 實測）。
            menu.tap()

            if app.buttons[strings.addAccount].waitForExistence(timeout: 8) {
                return app.buttons[strings.addAccount]
            }
            if app.buttons["plus.circle"].exists { return app.buttons["plus.circle"] }
            print("[StoreShot] config retry \(attempt) 失敗：點了選單但沒等到 \(strings.addAccount)")
        }
        return nil
    }

    // MARK: - 系統對話框

    /// 關掉任何擋在畫面前的系統對話框（主要是啟動時的通知授權）。
    ///
    /// **不猜按鈕位置。** 先把 alert 的 label 與所有按鈕列印出來（這是 CLAUDE.md
    /// 「先 dump 再寫互動」所要求的觀察步驟，保留成常駐 log 供 CI 判讀），
    /// 再用已知的允許/不允許字樣去比對；都沒中就點最後一顆按鈕
    /// （iOS 授權對話框的慣例是「允許」在最後），並把整棵樹留存下來。
    /// 鑰匙圈的「要儲存密碼嗎？」不是 `alert`，而是一張 sheet，
    /// 因此 `dismissSystemAlertsIfPresent` 掃不到。這裡直接找 Springboard 上的
    /// 關閉字樣並點掉 —— 只關閉，絕不按「儲存」。
    private func dismissPasswordSaveSheetIfPresent() {
        let dismissLabels = ["Not Now", "稍後再說", "稍后再说", "Never", "永不"]
        for label in dismissLabels {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) {
                print("[StoreShot] dismissing password-save sheet via '\(label)'")
                button.tap()
                sleep(1)
                return
            }
            let inApp = app.buttons[label]
            if inApp.exists {
                print("[StoreShot] dismissing password-save sheet (app tree) via '\(label)'")
                inApp.tap()
                sleep(1)
                return
            }
        }
        print("[StoreShot] no password-save sheet present")
    }

    private func dismissSystemAlertsIfPresent(reason: String, rounds: Int = 3) {
        let allowLabels = ["Allow", "允許", "允许",
                           "Allow While Using App", "OK", "好", "確定", "确定",
                           // 登入後會冒出鑰匙圈的「要儲存密碼嗎？」，必須關掉而不是儲存，
                           // 否則它會蓋住主畫面那張商店截圖。
                           "Not Now", "稍後再說", "稍后再说", "Never", "永不", "Cancel", "取消"]

        for round in 0..<rounds {
            var alert = springboard.alerts.firstMatch
            if !alert.waitForExistence(timeout: round == 0 ? 8 : 2) {
                // iOS 26 起部分系統 alert 會掛在 app 的查詢樹下而非 Springboard。
                alert = app.alerts.firstMatch
                guard alert.waitForExistence(timeout: 2) else {
                    print("[StoreShot] no system alert (reason=\(reason), round=\(round))")
                    return
                }
                print("[StoreShot] system alert found under APP query tree")
            }

            let buttons = alert.buttons
            print("[StoreShot] system alert (reason=\(reason), round=\(round)) label='\(alert.label)' buttons=\(buttons.count)")
            var labels: [String] = []
            for i in 0..<buttons.count {
                let label = buttons.element(boundBy: i).label
                labels.append(label)
                print("[StoreShot]   button[\(i)] = '\(label)'")
            }

            if let match = allowLabels.first(where: { labels.contains($0) }) {
                print("[StoreShot] tapping '\(match)'")
                buttons[match].tap()
            } else if buttons.count > 0 {
                // 沒有已知字樣 —— 先存證再動作，事後才有得對照。
                captureFailureEvidence("unknown-system-alert-\(reason)")
                let last = buttons.element(boundBy: buttons.count - 1)
                print("[StoreShot] 未知的系統對話框，改點最後一顆按鈕 '\(last.label)'")
                last.tap()
            } else {
                captureFailureEvidence("system-alert-without-buttons-\(reason)")
                return
            }
            sleep(2)
        }
    }

    /// 點進欄位、**確認鍵盤焦點真的落下**、再打字。
    ///
    /// 為什麼不能直接 `tap()` + `typeText()`：iPad 首跑（ipad-run1.log:157）拿到
    /// `Failed to synthesize event: Neither element nor any descendant has keyboard focus`
    /// —— 上一個欄位的鍵盤動畫還在進行時，對下一個欄位的 tap() 會被吃掉，
    /// 元素存在、看起來也點到了，但焦點沒有轉移。`typeText()` 的失敗是
    /// XCTest 層級的例外、Swift 接不住，所以只能在打字**之前**先確認焦點。
    ///
    /// 兩種點法交替：元素中心 tap 與正規化座標 tap。前者會被 SwiftUI 的
    /// 透明覆蓋層吃掉時，後者通常能穿過去。
    private func fillField(_ element: XCUIElement, with text: String, label: String) {
        for attempt in 0..<4 {
            if hasKeyboardFocus(element) { break }
            if attempt.isMultiple(of: 2) {
                element.tap()
            } else {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            _ = waitForKeyboardFocus(element, timeout: 3)
        }

        guard waitForKeyboardFocus(element, timeout: 3) else {
            captureFailureEvidence("no-keyboard-focus-\(label)")
            XCTFail("欄位「\(label)」點了 4 次仍取不到鍵盤焦點 —— 已存畫面與元素樹")
            return
        }
        element.typeText(text)

        // 只記長度，永遠不印內容 —— 這個 helper 也會被真密碼走過。
        let typed = (element.value as? String)?.count ?? -1
        print("[StoreShot][Field] 「\(label)」輸入完成，欄位 value 長度=\(typed)（應為 \(text.count) 或遮蔽字元數）")
    }

    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        // `hasKeyboardFocus` 沒有公開 API，但是 XCUIElement 的 KVC 屬性；
        // 取不到時回 false，讓呼叫端走「多點幾次」而不是誤判成已就緒。
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    private func waitForKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasKeyboardFocus(element) { return true }
            usleep(200_000)
        }
        return hasKeyboardFocus(element)
    }

    /// 收起軟體鍵盤。送審截圖不能被鍵盤蓋掉半個版面
    /// （iPad 首跑 `ipad-13-02-server-filled.png` 下半張全是注音鍵盤）。
    ///
    /// 沒有一招通吃：iPad 鍵盤右下角有「隱藏鍵盤」鍵、iPhone 沒有；
    /// SwiftUI 的 ScrollView 點空白處也不保證收（實測 dy=0.06 的點擊無效）。
    /// 所以依序試，並記錄哪一招成功 —— 這些 `[StoreShot]` log 留著給 CI 判讀。
    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }

        let keyboard = app.keyboards.firstMatch
        let dismissLabels = ["Hide keyboard", "隱藏鍵盤", "隐藏键盘", "Dismiss", "收起鍵盤"]

        // 策略 1：鍵盤自己的隱藏鍵（iPad 才有）
        let keys = keyboard.buttons
        var seen: [String] = []
        for i in 0..<min(keys.count, 40) {
            let key = keys.element(boundBy: i)
            let id = key.identifier, label = key.label
            seen.append("id='\(id)' label='\(label)'")
            if dismissLabels.contains(id) || dismissLabels.contains(label) {
                print("[StoreShot][Keyboard] 策略1 命中隱藏鍵 id='\(id)' label='\(label)'")
                key.tap()
                sleep(1)
                if !app.keyboards.firstMatch.exists { return }
            }
        }

        // 策略 2：按鍵盤的 Return 鍵。
        // 6.9" 上沒有「隱藏鍵盤」鍵（iphone-run1.log 的鍵盤按鍵只列出
        // id='emoji' 與 id='Return'），而 LoginView 的欄位沒有掛 `.onSubmit`，
        // 所以 Return 只會收起鍵盤、不會送出表單。
        let returnKey = keyboard.buttons["Return"]
        if returnKey.exists {
            print("[StoreShot][Keyboard] 策略2 按 Return")
            returnKey.tap()
            sleep(1)
            if !app.keyboards.firstMatch.exists { return }
        }

        // 策略 3：在 ScrollView 上往下滑 —— iOS 16 起 ScrollView 預設
        // `.scrollDismissesKeyboard(.automatic)`，滑動會收鍵盤。
        let scroll = app.scrollViews.firstMatch
        if scroll.exists {
            print("[StoreShot][Keyboard] 策略3 在 ScrollView 上 swipeDown")
            scroll.swipeDown()
            sleep(1)
            if !app.keyboards.firstMatch.exists { return }
        }

        // 策略 4：點品牌標題那行文字。
        // 刻意不用「鍵盤上方的空白座標」—— 在 6.9" 上那個位置正好落在
        // 「下一步」按鈕附近，盲點一下會提前換頁、把 02 這張拍成 03。
        // 標題是純 Text，點下去在任何版面都不會觸發動作。
        let title = app.staticTexts[SharedTestConfig.appDisplayName]
        if title.exists {
            print("[StoreShot][Keyboard] 策略4 點標題文字")
            title.tap()
            sleep(1)
            if !app.keyboards.firstMatch.exists { return }
        }

        // 四招都沒收起來 —— 把鍵盤按鍵清單留下來，下次才有得對照。
        print("[StoreShot][Keyboard] 四個策略全部失敗，鍵盤仍在。鍵盤按鍵：")
        seen.forEach { print("[StoreShot][Keyboard]   \($0)") }
    }

    // MARK: - 擷取

    /// 擷取一張全裝置解析度截圖，同時存成 XCTAttachment 與 PNG 檔。
    ///
    /// `XCUIScreen.main.screenshot()` 拿到的是裝置原生像素
    /// （iPhone 17 Pro Max = 1320×2868；iPad Air 13" = 2048×2732），
    /// 正是 App Store Connect 6.9" / 13" 要的尺寸。
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let fileName = "\(SharedTestConfig.storeScreenshotPrefix)-\(name).png"

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let dir = resolvedOutputDir else {
            print("[StoreShot] \(fileName): 只存成 attachment（沒有可寫目錄）")
            return
        }
        let url = dir.appendingPathComponent(fileName)
        do {
            try screenshot.pngRepresentation.write(to: url)
            print("[StoreShot] WROTE \(url.path)")
        } catch {
            print("[StoreShot] FAILED to write \(url.path): \(error)")
        }
    }

    private func captureFailureEvidence(_ name: String) {
        capture("FAIL-\(name)")
        print("[StoreShot] ===== APP TREE (\(name)) =====")
        print(app.debugDescription)
        print("[StoreShot] ===== SPRINGBOARD TREE (\(name)) =====")
        print(springboard.debugDescription)
    }

    private func assertExists(_ element: XCUIElement,
                              _ message: String,
                              timeout: TimeInterval = 25,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws {
        guard element.waitForExistence(timeout: timeout) else {
            captureFailureEvidence("missing-element")
            XCTFail(message, file: file, line: line)
            throw XCTSkip(message)
        }
    }

    // MARK: - 輸出目錄

    /// 決定截圖要寫到哪裡。
    ///
    /// 優先用呼叫端指定的 host 目錄（`STORE_SHOT_DIR`）—— 模擬器行程**有時**
    /// 寫得進 host 路徑，但並非保證，所以這裡實際寫一個探測檔驗證，
    /// 寫不進去就退回 runner 自己的 Documents（host 端可用
    /// `simctl get_app_container <udid> io.woowtech.odooUITests.xctrunner data` 取出）。
    private static func prepareOutputDirectory() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let dir = SharedTestConfig.storeScreenshotDir {
            candidates.append(URL(fileURLWithPath: dir, isDirectory: true))
        }
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(docs.appendingPathComponent("store-screenshots", isDirectory: true))
        }

        for candidate in candidates {
            do {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: true)
                let probe = candidate.appendingPathComponent(".write-probe")
                try Data("ok".utf8).write(to: probe)
                try? fm.removeItem(at: probe)
                return candidate
            } catch {
                print("[StoreShot] 目錄不可寫，換下一個：\(candidate.path) — \(error)")
            }
        }
        return nil
    }
}
