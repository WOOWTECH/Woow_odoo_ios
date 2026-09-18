//
//  E2E_MultiAccountAddFlow.swift
//  odooUITests
//
//  T18 / T09：新增第二個實例的完整流程，在**實機**上自動化執行。
//
//  為什麼需要這支測試
//  ──────────────────
//  2026-09-18 實機發現：點「Add Account」後畫面閃一下就回到原本的 WebView，
//  永遠新增不了第二個實例。根因是該流程借用了 `onSessionExpired()`，
//  而那個事件會先嘗試靜默自癒；目前帳號健康時自癒成功，`launchState`
//  被設回 `.authenticated`，登入表單沒機會出現。
//  （EXISTING-BASELINE 第 4 項早已記載此缺陷，對應 T18。）
//
//  修補是 `AppRootViewModel.beginAddAccount()`。單元測試只能驗
//  `beginAddAccount()` 的契約 —— 因為 `SessionReauthenticator` 是 actor
//  且未抽象化，測不出「自癒成功」的情境。**只有這支 UI 測試能驗完整路徑。**
//
//  憑證來源：全部由 launchEnvironment 傳入，測試碼內不寫死任何密碼。
//

import XCTest

final class E2E_MultiAccountAddFlow: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // 強制英文語系：否則按鈕文字會是「登出目前帳號」「新增帳號」，
        // 用英文 selector 一定找不到（既有 E2E_HighPriority_Tests 同樣做法）。
        app.launchArguments += ["-AppleLanguages", "(en)", "-WoowTestRunner"]
        // 憑證一律由環境變數注入，不寫進原始碼
        for key in ["WT_A_SERVER", "WT_A_DB", "WT_A_USER", "WT_A_PASS",
                    "WT_B_SERVER", "WT_B_DB", "WT_B_USER", "WT_B_PASS"] {
            if let v = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = v
            }
        }
    }

    private func env(_ key: String) throws -> String {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else {
            throw XCTSkip("缺少環境變數 \(key) —— 測試需要由執行者注入憑證")
        }
        return v
    }

    /// 通用登入步驟。`fromServerStep` 為 true 時表示畫面已在空白的伺服器資訊步驟。
    private func performLogin(server: String, db: String, user: String, pass: String) {
        let serverField = app.textFields["example.odoo.com"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 20),
                      "伺服器欄位沒有出現 —— 畫面不在登入表單")
        serverField.tap()
        serverField.typeText(server)

        let dbField = app.textFields["Enter database name"]
        XCTAssertTrue(dbField.waitForExistence(timeout: 5))
        dbField.tap()
        dbField.typeText(db)

        app.buttons["Next"].tap()

        let userField = app.textFields["Username or email"]
        XCTAssertTrue(userField.waitForExistence(timeout: 15),
                      "憑證步驟沒有出現")
        userField.tap()
        userField.typeText(user)

        let passField = app.secureTextFields["Enter password"]
        passField.tap()
        passField.typeText(pass)

        app.buttons["Login"].tap()
    }

    private func waitForMainScreen(_ timeout: TimeInterval = 60) {
        // ⚠️ 不能用 app 名稱判斷：登入頁的標題與主畫面的工具列**都**顯示
        // "woowtech platform"，用它判斷會在還停在登入頁時就誤判為成功。
        // 改用主畫面獨有的漢堡選單按鈕。
        let menu = app.buttons["line.3.horizontal"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout),
                      "登入後沒有進到主畫面（主畫面專屬的選單按鈕未出現）")
    }

    /// 把 App 帶到「登入表單」這個已知起點。
    ///
    /// 為什麼需要這一步：iOS 模擬器與實機的 App 資料容器**不會**因為重新安裝而清空
    /// （容器與鑰匙圈要 `simctl erase` 才會消失，而清資料在本輪禁止清單內）。
    /// 實測模擬器與 iPad 上都殘留著先前的帳號，App 一啟動就直接進主畫面，
    /// 測試若假設「一開始在登入頁」必然在第一步就失敗。
    ///
    /// 這裡用**產品自己的登出流程**逐一登出（不是直接改資料庫），
    /// 直到伺服器欄位出現為止。登出只移除本機連線，不影響任何 ERP 帳號。
    private func ensureAtLoginForm(maxAccounts: Int = 5) {
        for _ in 0..<maxAccounts {
            if app.textFields["example.odoo.com"].waitForExistence(timeout: 8) { return }

            let menu = app.buttons["line.3.horizontal"]
            guard menu.waitForExistence(timeout: 20) else { return }
            menu.tap()

            // SwiftUI 的 Label(_:systemImage:) 會把 identifier 設成 SF Symbol 名稱、
            // label 設成文字，兩者都可能被匹配到 —— 兩條路都試。
            let logoutByText = app.buttons["Log out current account"]
            let logoutBySymbol = app.buttons["rectangle.portrait.and.arrow.right"]
            let logoutRow = logoutByText.waitForExistence(timeout: 10) ? logoutByText : logoutBySymbol
            guard logoutRow.exists else {
                if app.buttons["xmark"].exists { app.buttons["xmark"].tap() }
                return
            }
            logoutRow.tap()

            let confirm = app.alerts.buttons["Log out"]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            sleep(3)
        }
    }

    /// 開啟 ConfigView 並回傳 Add Account 按鈕；失敗時回 nil。
    ///
    /// 需要重試的原因：登入後主畫面的 WebView 仍在載入，此時點選單有機會落空，
    /// 或 sheet 只開到一半就被重繪打斷。每輪都重新查詢元素，並在必要時先把
    /// 半開的 sheet 關掉再重來。
    private func openConfigAndFindAddAccount(retries: Int = 4) -> XCUIElement? {
        for attempt in 0..<retries {
            // 已經開著就直接找
            if app.staticTexts["Configuration"].waitForExistence(timeout: 2) {
                if app.buttons["Add Account"].waitForExistence(timeout: 5) {
                    return app.buttons["Add Account"]
                }
                if app.buttons["plus.circle"].exists { return app.buttons["plus.circle"] }
                // 開著卻找不到 → 關掉重來
                if app.buttons["xmark"].exists { app.buttons["xmark"].tap() }
                sleep(2)
                continue
            }

            let menu = app.buttons["line.3.horizontal"]
            guard menu.waitForExistence(timeout: 20) else {
                sleep(3); continue
            }
            // 等主畫面穩定下來再點，避免 WebView 重繪把點擊吃掉
            sleep(UInt32(2 + attempt * 2))
            // ⚠️ 不可用 `isHittable` 當閘門。實測（run1.log t=49.79/60.77/73.71/88.61）：
            // 登入後主畫面的 line.3.horizontal 連續 4 次 isHittable == false，tap() 從未執行；
            // 但**同一顆按鈕**在 ensureAtLoginForm() 內（沒有這道閘門）t=20.65 tap() 是成功的。
            // 元素樹顯示它是 NavigationBar 內、被多層透明 Other 包住的 SwiftUI toolbar item，
            // 命中點落在覆蓋層上 → isHittable 誤判為 false。實際 tap() 會自行處理。
            print("=====MENU-\(attempt): exists=\(menu.exists) hittable=\(menu.isHittable)=====")
            menu.tap()

            if app.buttons["Add Account"].waitForExistence(timeout: 8) {
                return app.buttons["Add Account"]
            }
            if app.buttons["plus.circle"].exists { return app.buttons["plus.circle"] }

            print("=====RETRY-\(attempt)-FAILED: 點了選單但沒等到 Add Account=====")
            print("  Configuration 標題 = \(app.staticTexts["Configuration"].exists)")
            print("  選單按鈕 = \(app.buttons["line.3.horizontal"].exists)")
            print("  伺服器欄位 = \(app.textFields["example.odoo.com"].exists)")
            print("  可見按鈕數 = \(app.buttons.count)")
            for i in 0..<min(app.buttons.count, 12) {
                let b = app.buttons.element(boundBy: i)
                print("    btn[\(i)] id='\(b.identifier)' label='\(b.label)'")
            }
        }
        print("=====ALL-RETRIES-EXHAUSTED — 最終元素樹=====")
        print(app.debugDescription)
        return nil
    }

    /// T18 + T09：登入 A → 新增 B → 兩個實例並存。
    func test_addSecondAccount_givenHealthyFirstAccount_showsBlankFormAndSavesBoth() throws {
        let aServer = try env("WT_A_SERVER"), aDB = try env("WT_A_DB")
        let aUser = try env("WT_A_USER"), aPass = try env("WT_A_PASS")
        let bServer = try env("WT_B_SERVER"), bDB = try env("WT_B_DB")
        let bUser = try env("WT_B_USER"), bPass = try env("WT_B_PASS")

        app.launch()

        // ── 0. 前置：把 App 帶到登入表單（容器可能殘留先前帳號）──
        ensureAtLoginForm()
        attach("0_at_login_form")

        // ── 1. 登入實例 A ──
        performLogin(server: aServer, db: aDB, user: aUser, pass: aPass)
        waitForMainScreen()
        attach("1_A_logged_in")

        // ── 2. 開啟選單 → Add Account ──
        // 剛登入完 WebView 仍在載入，主畫面尚未穩定；選單點擊可能落空或 sheet
        // 開到一半。這裡重試數次，每次都重新查詢元素（XCUIElement 是惰性查詢）。
        let addButton = openConfigAndFindAddAccount()
        XCTAssertNotNil(addButton,
                        "ConfigView 內找不到 Add Account（重試 4 次，text 與 plus.circle 兩種 selector 都試過）")
        attach("2_config_sheet")
        addButton!.tap()

        // ── 3. ★核心斷言：必須出現空白的伺服器表單 ──
        // 修補前，自癒會成功並把畫面彈回 WebView，這裡會逾時失敗。
        let serverField = app.textFields["example.odoo.com"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 20),
                      "點 Add Account 後沒有進到伺服器資訊表單 —— " +
                      "新增實例被 self-heal 攔截彈回主畫面（T18 缺陷重現）")
        XCTAssertEqual(serverField.value as? String ?? "", "example.odoo.com",
                       "新增實例的伺服器欄位必須是空的（顯示 placeholder），不得預填現有帳號")
        attach("3_blank_server_form")

        // ── 4. 填入實例 B ──
        performLogin(server: bServer, db: bDB, user: bUser, pass: bPass)
        waitForMainScreen()
        attach("4_B_logged_in")

        // ── 5. 驗證兩個實例並存 ──
        // 單次 tap 會落空：run2.log t=85.22 「Computed hit point {-1, -1}」，
        // sheet 根本沒開，於是帳號清單斷言必然失敗。改用步驟 2 同一套重試開啟法。
        XCTAssertNotNil(openConfigAndFindAddAccount(),
                        "登入 B 之後開不了 ConfigView，無法檢查帳號清單")
        sleep(2)
        attach("5_both_accounts")
        print("=====ACCOUNT-LIST-TREE=====")
        print(app.debugDescription)

        // 實測觀察到的帳號清單長相（run3.log 的 ACCOUNT-LIST-TREE，元素樹原文）：
        //   目前帳號 B → 最上方 Cell
        //       StaticText '黃測試 App Tester B' / StaticText 'app.tester.b@woowtest.invalid'
        //   帳號 A    → "Switch Account" 區的一列
        //       Button label '林測試 App Tester A, https://demo111-odoo.woowtech.io'
        //         ├ StaticText '林測試 App Tester A'
        //         └ StaticText 'https://demo111-odoo.woowtech.io'
        //
        // 關鍵：**非目前帳號的那一列不顯示 email**，只有顯示名稱 + 伺服器 URL。
        // 原本兩個帳號都用 email 去找，對 A 而言是拿一個 UI 上根本不存在的字串當 oracle，
        // 永遠不會成立。改用伺服器 URL 認 A —— 它一樣唯一、一樣來自注入的 WT_A_SERVER，
        // 而且比純文字更強：比對的是「可切換的帳號列」這顆 Button 本身。
        let aRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", aServer)).firstMatch
        let bText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", bUser)).firstMatch
        XCTAssertTrue(aRow.waitForExistence(timeout: 10),
                      "Switch Account 區找不到實例 A 的帳號列（\(aServer)）—— 新增 B 後 A 沒有被保留")
        XCTAssertTrue(bText.exists,
                      "帳號清單中找不到目前帳號 B（\(bUser)）")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
