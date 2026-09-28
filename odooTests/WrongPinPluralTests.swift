import XCTest
@testable import odoo

/// 2026-09-28 iOS 英文單複數：PIN 輸錯剩最後一次時，解鎖畫面（PinView）顯示「Wrong PIN. 1 attempts
/// remaining」。`wrong_pin_%lld` 原本是 `Localizable.strings` 的單一格式字串，不分單複數；改為
/// `Localizable.stringsdict` 複數規則：英文 one → "attempt"、other → "attempts"；繁／簡中文沒有單複數，
/// 只有 other，文字維持原樣（對齊 Android 3fb8097 的 plurals `wrong_pin_attempts_remaining`）。
final class WrongPinPluralTests: XCTestCase {

    private func bundle(_ lang: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func test_wrongPinMessage_givenEnglishOneAttemptLeft_usesSingular() throws {
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 1, bundle: try bundle("en")),
                       "Wrong PIN. 1 attempt remaining")
    }

    func test_wrongPinMessage_givenEnglishTwoAttemptsLeft_usesPlural() throws {
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 2, bundle: try bundle("en")),
                       "Wrong PIN. 2 attempts remaining")
    }

    func test_wrongPinMessage_givenEnglishFourAttemptsLeft_usesPlural() throws {
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 4, bundle: try bundle("en")),
                       "Wrong PIN. 4 attempts remaining")
    }

    func test_wrongPinMessage_givenTraditionalChinese_textUnchanged() throws {
        let zhHant = try bundle("zh-Hant")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 1, bundle: zhHant), "PIN 碼錯誤，剩餘 1 次")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 4, bundle: zhHant), "PIN 碼錯誤，剩餘 4 次")
    }

    func test_wrongPinMessage_givenSimplifiedChinese_textUnchanged() throws {
        let zhHans = try bundle("zh-Hans")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 1, bundle: zhHans), "PIN 码错误，剩余 1 次")
        XCTAssertEqual(wrongPinMessage(remainingAttempts: 3, bundle: zhHans), "PIN 码错误，剩余 3 次")
    }
}
