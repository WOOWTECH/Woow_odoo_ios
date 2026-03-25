import XCTest
@testable import WoowOdoo

/// Unit tests for domain models — verifies M1 deliverables.
final class DomainModelTests: XCTestCase {

    // MARK: - OdooAccount

    func testOdooAccountCreation() {
        let account = OdooAccount(
            serverUrl: "odoo.example.com",
            database: "test_db",
            username: "admin",
            displayName: "Administrator"
        )
        XCTAssertFalse(account.id.isEmpty)
        XCTAssertEqual(account.serverUrl, "odoo.example.com")
        XCTAssertEqual(account.database, "test_db")
        XCTAssertFalse(account.isActive)
    }

    func testOdooAccountFullServerUrl_addsHttps() {
        let account = OdooAccount(
            serverUrl: "odoo.example.com",
            database: "db",
            username: "admin",
            displayName: "Admin"
        )
        XCTAssertEqual(account.fullServerUrl, "https://odoo.example.com")
    }

    func testOdooAccountFullServerUrl_keepsExistingHttps() {
        let account = OdooAccount(
            serverUrl: "https://odoo.example.com",
            database: "db",
            username: "admin",
            displayName: "Admin"
        )
        XCTAssertEqual(account.fullServerUrl, "https://odoo.example.com")
    }

    func testOdooAccountEquality() {
        let id = "test-id"
        let a = OdooAccount(id: id, serverUrl: "s", database: "d", username: "u", displayName: "n")
        let b = OdooAccount(id: id, serverUrl: "s", database: "d", username: "u", displayName: "n")
        XCTAssertEqual(a, b)
    }

    // MARK: - AuthResult

    func testAuthResultSuccess() {
        let result = AuthResult.success(.init(
            userId: 1, sessionId: "abc", username: "admin", displayName: "Admin"
        ))
        XCTAssertTrue(result.isSuccess)
    }

    func testAuthResultError() {
        let result = AuthResult.error("Network error", .networkError)
        XCTAssertFalse(result.isSuccess)
    }

    // MARK: - AppSettings

    func testAppSettingsDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.themeColor, "#6183FC")
        XCTAssertEqual(settings.themeMode, .system)
        XCTAssertFalse(settings.appLockEnabled)
        XCTAssertFalse(settings.biometricEnabled)
        XCTAssertFalse(settings.pinEnabled)
        XCTAssertNil(settings.pinHash)
        XCTAssertEqual(settings.language, .system)
    }

    func testAppLanguageDisplayNames() {
        XCTAssertEqual(AppLanguage.system.displayName, "System Default")
        XCTAssertEqual(AppLanguage.english.displayName, "English")
        XCTAssertEqual(AppLanguage.chineseTW.displayName, "繁體中文")
        XCTAssertEqual(AppLanguage.chineseCN.displayName, "简体中文")
    }

    func testThemeModeAllCases() {
        XCTAssertEqual(ThemeMode.allCases.count, 3)
    }

    func testAppLanguageAllCases() {
        XCTAssertEqual(AppLanguage.allCases.count, 4)
    }
}
