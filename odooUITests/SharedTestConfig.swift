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

    /// The app's user-visible display name, as rendered in the LoginView title and
    /// the MainView toolbar.
    ///
    /// Single source of truth so a rename does not silently rot a dozen XCUITest
    /// selectors. It was hardcoded as "WoowTech Odoo" in 13 places across 7 files;
    /// the 2026-09-17 rename to "woowtech platform" (AP-15) broke every one of them.
    ///
    /// Keep in sync with the `"WoowTech Odoo"` VALUE in
    /// `odoo/Resources/*.lproj/Localizable.strings` — the key stays as the old name
    /// because `LoginView`/`MainView` use the string literal as the localization key.
    /// The brand wordmark is intentionally identical across all locales.
    static let appDisplayName = ProcessInfo.processInfo.environment["TEST_APP_DISPLAY_NAME"]
        ?? plist["AppDisplayName"] as? String
        ?? "woowtech platform"

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
}

/// Dummy class to locate the test bundle
private class BundleToken {}
