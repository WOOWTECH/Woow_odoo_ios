import XCTest
@testable import odoo

/// 全面實測 I13（I13-wrong4.png）：英文解鎖畫面剩 1 次時顯示「Wrong PIN. 1 attempts remaining」。
/// `wrong_pin_%lld` 原本只有一條固定格式字串，數字是 1 也照樣接 attempts；改由
/// `Localizable.stringsdict` 的複數規則決定（英文 one／other，中文只有 other，文字不變）。
/// 對齊 Android 3fb8097（`<plurals name="wrong_pin_attempts_remaining">`）。
final class WrongPinMessageTests: XCTestCase {

    private func bundle(_ lang: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func test_wrongPinMessage_givenOneAttemptLeftInEnglish_returnsSingular() throws {
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 1, bundle: try bundle("en")),
                       "Wrong PIN. 1 attempt remaining")
    }

    func test_wrongPinMessage_givenSeveralAttemptsLeftInEnglish_returnsPlural() throws {
        let en = try bundle("en")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 4, bundle: en), "Wrong PIN. 4 attempts remaining")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 2, bundle: en), "Wrong PIN. 2 attempts remaining")
    }

    func test_wrongPinMessage_givenChinese_keepsCountWordingForAnyCount() throws {
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 1, bundle: try bundle("zh-Hant")), "PIN 碼錯誤，剩餘 1 次")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 4, bundle: try bundle("zh-Hant")), "PIN 碼錯誤，剩餘 4 次")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 1, bundle: try bundle("zh-Hans")), "PIN 码错误，剩余 1 次")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 4, bundle: try bundle("zh-Hans")), "PIN 码错误，剩余 4 次")
    }
}
