//
//  odooTests.swift
//  odooTests
//
//  Consolidated test file for M1 verification.
//

import XCTest
@testable import odoo

// MARK: - Domain Model Tests

final class DomainModelTests: XCTestCase {

    func testOdooAccountCreation() {
        let account = OdooAccount(
            serverUrl: "odoo.example.com",
            database: "test_db",
            username: "admin",
            displayName: "Administrator"
        )
        XCTAssertFalse(account.id.isEmpty)
        XCTAssertEqual(account.serverUrl, "odoo.example.com")
        XCTAssertFalse(account.isActive)
    }

    func testOdooAccountFullServerUrl_addsHttps() {
        let account = OdooAccount(
            serverUrl: "odoo.example.com", database: "db",
            username: "admin", displayName: "Admin"
        )
        XCTAssertEqual(account.fullServerUrl, "https://odoo.example.com")
    }

    func testOdooAccountFullServerUrl_keepsExistingHttps() {
        let account = OdooAccount(
            serverUrl: "https://odoo.example.com", database: "db",
            username: "admin", displayName: "Admin"
        )
        XCTAssertEqual(account.fullServerUrl, "https://odoo.example.com")
    }

    func testOdooAccountEquality() {
        let id = "test-id"
        let a = OdooAccount(id: id, serverUrl: "s", database: "d", username: "u", displayName: "n")
        let b = OdooAccount(id: id, serverUrl: "s", database: "d", username: "u", displayName: "n")
        XCTAssertEqual(a, b)
    }

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

    func testAppSettingsDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.themeColor, "#6183FC")
        XCTAssertEqual(settings.themeMode, .system)
        XCTAssertFalse(settings.appLockEnabled)
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

// MARK: - DeepLinkValidator Tests

final class DeepLinkValidatorTests: XCTestCase {

    private let serverHost = "odoo.example.com"

    func testRejectJavascript() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "javascript:alert(1)", serverHost: serverHost))
    }

    func testRejectJavascriptUppercase() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "JAVASCRIPT:alert('xss')", serverHost: serverHost))
    }

    func testRejectData() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "data:text/html,<script>alert(1)</script>", serverHost: serverHost))
    }

    func testRejectDataUppercase() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "DATA:text/html;base64,PHNjcmlwdD4=", serverHost: serverHost))
    }

    func testRejectEmpty() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "", serverHost: serverHost))
    }

    func testRejectBlank() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "   ", serverHost: serverHost))
    }

    func testAcceptWebWithFragment() {
        XCTAssertTrue(DeepLinkValidator.isValid(url: "/web#id=42&model=sale.order&view_type=form", serverHost: serverHost))
    }

    func testAcceptWebAction() {
        XCTAssertTrue(DeepLinkValidator.isValid(url: "/web#action=contacts", serverHost: serverHost))
    }

    func testAcceptWebLogin() {
        XCTAssertTrue(DeepLinkValidator.isValid(url: "/web/login", serverHost: serverHost))
    }

    func testAcceptWebRoot() {
        XCTAssertTrue(DeepLinkValidator.isValid(url: "/web", serverHost: serverHost))
    }

    func testRejectExternalHost() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "https://evil.com/phish", serverHost: serverHost))
    }

    func testRejectAttackerHost() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "https://attacker.example.com/fake", serverHost: serverHost))
    }

    func testRejectFtp() {
        XCTAssertFalse(DeepLinkValidator.isValid(url: "ftp://files.example.com", serverHost: serverHost))
    }
}
