import XCTest
@testable import odoo

/// W1-5: the Apporo push diagnostics section in Settings is Debug-only.
final class PushDiagnosticsVisibilityTests: XCTestCase {

    func test_isVisible_givenApporoDebugWithAccount_returnsTrue() {
        XCTAssertTrue(PushDiagnosticsVisibility.isVisible(brand: .apporo, hasActiveAccount: true, isDebugBuild: true))
    }

    func test_isVisible_givenApporoReleaseBuild_returnsFalse() {
        XCTAssertFalse(PushDiagnosticsVisibility.isVisible(brand: .apporo, hasActiveAccount: true, isDebugBuild: false))
    }

    func test_isVisible_givenNoActiveAccount_returnsFalse() {
        XCTAssertFalse(PushDiagnosticsVisibility.isVisible(brand: .apporo, hasActiveAccount: false, isDebugBuild: true))
        XCTAssertFalse(PushDiagnosticsVisibility.isVisible(brand: .apporo, hasActiveAccount: false, isDebugBuild: false))
    }

    func test_isVisible_givenWoowInAnyBuild_returnsFalse() {
        for debug in [true, false] {
            XCTAssertFalse(PushDiagnosticsVisibility.isVisible(brand: .woowtech, hasActiveAccount: true, isDebugBuild: debug))
        }
    }

    func test_isDebugBuild_givenUnitTestBuild_returnsTrue() {
        // Unit tests only run against Debug / ApporoDebug, which define DEBUG.
        // Release exclusion is covered by the xcconfig source contract
        // (scripts/tests/test_push_contract.py).
        XCTAssertTrue(PushDiagnosticsVisibility.isDebugBuild)
    }

    func test_statusStrings_givenNotConfigured_keepExistingLocalizedText() throws {
        // The user-facing status text is unchanged; only its visibility moved.
        let expected = [
            "en": "Server has not configured Apporo push",
            "zh-Hans": "服务器尚未配置 Apporo 推送",
            "zh-Hant": "伺服器尚未設定 Apporo 推播",
        ]
        for (lang, text) in expected {
            let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "push_status_not_configured", value: nil, table: nil), text, lang)
        }
    }
}
