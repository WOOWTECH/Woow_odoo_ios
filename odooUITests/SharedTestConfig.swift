import Foundation

/// Shared test configuration — reads from TestConfig.plist (single source of truth).
/// To change the server URL, edit TestConfig.plist only.
/// Environment variables override plist values for CI.
enum SharedTestConfig {
    private static let plist: [String: Any] = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "TestConfig", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return [:]
        }
        return dict
    }()

    /// Identity comes from this test target's matching build configuration, not
    /// a saved TestConfig.plist from a different brand or environment.
    static let appDisplayName: String = {
        guard let name = Bundle(for: BundleToken.self).object(forInfoDictionaryKey: "TestAppDisplayName") as? String,
              !name.isEmpty else { fatalError("Missing test target brand configuration") }
        return name
    }()

    static let appBundleID: String = {
        guard let bundleID = Bundle(for: BundleToken.self).object(forInfoDictionaryKey: "TestAppBundleID") as? String,
              !bundleID.isEmpty else { fatalError("Missing test target bundle configuration") }
        return bundleID
    }()

    /// No plist/env fallback: an old test fixture must never launch another brand.
    static let appURLScheme: String = {
        guard let scheme = Bundle(for: BundleToken.self).object(forInfoDictionaryKey: "TestAppURLScheme") as? String else {
            fatalError("Missing test target URL scheme configuration")
        }
        switch (appBundleID, scheme) {
        case ("io.woowtech.odoo", "woowodoo"),
             ("com.apporo.odoo.dev", "apporoodoo-dev"),
             ("com.apporo.odoo", "apporoodoo"):
            return scheme
        default:
            fatalError("Inconsistent test target URL scheme configuration")
        }
    }()

    static let serverURL = ProcessInfo.processInfo.environment["TEST_SERVER_URL"]
        ?? plist["ServerURL"] as? String
        ?? "localhost:8069"
    static let database = ProcessInfo.processInfo.environment["TEST_DB"]
        ?? plist["Database"] as? String
        ?? "odoo18_ecpay"
    static let adminUser = ProcessInfo.processInfo.environment["TEST_ADMIN_USER"]
        ?? plist["AdminUser"] as? String
        ?? "admin"
    static let adminPass = ProcessInfo.processInfo.environment["TEST_ADMIN_PASS"]
        ?? plist["AdminPass"] as? String
        ?? "admin"
    static let senderEmail = ProcessInfo.processInfo.environment["TEST_SENDER_EMAIL"]
        ?? plist["SenderEmail"] as? String
        ?? "test@woowtech.com"
    static let senderPass = ProcessInfo.processInfo.environment["TEST_SENDER_PASS"]
        ?? plist["SenderPass"] as? String
        ?? "test1234"

    /// Primary test user for E2E login flows.
    static let testUser = ProcessInfo.processInfo.environment["TEST_USER"]
        ?? plist["TestUser"] as? String
        ?? "xctest@woowtech.com"
    static let testPass = ProcessInfo.processInfo.environment["TEST_PASS"]
        ?? plist["TestPass"] as? String
        ?? "XCTest2026!"

    /// Second test user for multi-account tests (UX-68).
    static let secondUser = ProcessInfo.processInfo.environment["TEST_SECOND_USER"]
        ?? plist["SecondUser"] as? String
        ?? "xctest2@woowtech.com"
    static let secondPass = ProcessInfo.processInfo.environment["TEST_SECOND_PASS"]
        ?? plist["SecondPass"] as? String
        ?? "XCTest2026!"

    // E8-S2: Target device for FCM push E2E tests.
    // AC4: no UDID is hardcoded here; the value comes from env or plist only.
    // AC5: set TEST_DEVICE_UDID env var or TestConfig.plist "DeviceUDID" key.
    // AC6: nil means "use the single paired device automatically".
    static let deviceUDID: String? = ProcessInfo.processInfo.environment["TEST_DEVICE_UDID"]
        ?? plist["DeviceUDID"] as? String

    // MARK: - App Store screenshot capture (StoreScreenshotTests)
    //
    // 這些鍵只給 `StoreScreenshotTests` 用。整組截圖流程預設**不執行** ——
    // 必須明確 `RUN_STORE_SCREENSHOTS=1` 才會跑，否則一律 XCTSkip，
    // 以免商店截圖流程污染一般測試回歸（與 `RUN_LOCATION_E2E=1` 同一種閘門）。
    //
    // 從 `xcodebuild test` 傳入時要加 `TEST_RUNNER_` 前綴才會抵達 runner 行程：
    //   TEST_RUNNER_RUN_STORE_SCREENSHOTS=1 TEST_RUNNER_STORE_SHOT_PREFIX=ios-69 ...

    /// 商店截圖總開關。未設為 "1" 時 `StoreScreenshotTests` 全部 skip。
    static let storeScreenshotsEnabled: Bool =
        (ProcessInfo.processInfo.environment["RUN_STORE_SCREENSHOTS"]
            ?? plist["RunStoreScreenshots"] as? String
            ?? "0") == "1"

    /// 檔名前綴，用來區分裝置尺寸，例如 `ios-69`、`ipad-13`。
    static let storeScreenshotPrefix = ProcessInfo.processInfo.environment["STORE_SHOT_PREFIX"]
        ?? plist["StoreShotPrefix"] as? String
        ?? "store"

    /// 截圖語系。`zh-Hant`（預設，與現有送審素材一致）或 `en`。
    static let storeScreenshotLocale = ProcessInfo.processInfo.environment["STORE_SHOT_LOCALE"]
        ?? plist["StoreShotLocale"] as? String
        ?? "zh-Hant"

    /// 選用：直接寫入的 host 目錄。模擬器沙箱未必允許，寫不進去時會退回
    /// runner 自己的 Documents（測試 log 會印出實際落點）。
    static let storeScreenshotDir: String? = ProcessInfo.processInfo.environment["STORE_SHOT_DIR"]
        ?? plist["StoreShotDir"] as? String

    /// 截圖裡要填進伺服器欄位的值（非機密：展示用測試站主機名）。
    static let storeShotServer = ProcessInfo.processInfo.environment["STORE_SHOT_SERVER"]
        ?? plist["StoreShotServer"] as? String
        ?? "demo111-odoo.woowtech.io"

    static let storeShotDatabase = ProcessInfo.processInfo.environment["STORE_SHOT_DB"]
        ?? plist["StoreShotDB"] as? String
        ?? "demo111"

    static let storeShotUser = ProcessInfo.processInfo.environment["STORE_SHOT_USER"]
        ?? plist["StoreShotUser"] as? String
        ?? "app.tester.a@woowtest.invalid"

    /// 密碼**沒有預設值**。沒有明確注入就代表「拍不了登入後的畫面」，
    /// 測試會 XCTSkip 並在 log 說明，絕不用假資料冒充已登入畫面。
    static let storeShotPassword: String? = {
        let raw = ProcessInfo.processInfo.environment["STORE_SHOT_PASSWORD"]
            ?? plist["StoreShotPassword"] as? String
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }()
}

/// Dummy class to locate the test bundle
private class BundleToken {}
