import XCTest
@testable import WoowOdoo

/// Unit tests for DeepLinkValidator — direct port from Android DeepLinkValidatorTest.kt.
/// Same test cases, same expected results.
final class DeepLinkValidatorTests: XCTestCase {

    private let serverHost = "odoo.example.com"

    // MARK: - Malicious URLs (must reject)

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

    // MARK: - Valid Odoo paths (must accept)

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

    // MARK: - External hosts (must reject)

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
