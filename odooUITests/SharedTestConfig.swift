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
}

/// Dummy class to locate the test bundle
private class BundleToken {}
