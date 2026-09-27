import XCTest
@testable import odoo

/// LIVE-0927-4 — "Remove PIN" removed the PIN with a single tap, no verification (live run
/// 2026-09-27, 43-pin-removed). Anyone holding an unlocked phone could strip the App Lock PIN.
/// Removal now requires the current PIN, verified through the same repository path as unlock
/// (failed-attempt counter + lockout), and the unverified removal API is gone.
///
/// Uses the real `SettingsRepository` (simulator Keychain) with an injected clock, cleaned in both
/// setUp and tearDown like `AppLockViewModelTests`.
@MainActor
final class PinRemovalVerificationTests: XCTestCase {

    private static let currentPin = "246801"
    private var clock: TimeInterval = 1_800_000_000
    private var repo: SettingsRepository!

    override func setUp() {
        super.setUp()
        repo = SettingsRepository(now: { [unowned self] in self.clock })
        repo.removePin()
        repo.resetFailedAttempts()
        XCTAssertTrue(repo.setPin(Self.currentPin))
    }

    override func tearDown() {
        repo.removePin()
        repo.resetFailedAttempts()
        repo = nil
        super.tearDown()
    }

    func test_removePin_givenCorrectCurrentPin_removesPin() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertEqual(vm.removePin(verifyingCurrentPin: Self.currentPin), .accepted)
        XCTAssertFalse(vm.settings.pinEnabled)
        XCTAssertNil(vm.settings.pinHash)
        XCTAssertNil(repo.getSettings().pinHash, "PIN 雜湊必須真的從儲存中移除")
    }

    func test_removePin_givenWrongPin_keepsPinAndCountsFailure() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertEqual(vm.removePin(verifyingCurrentPin: "000000"), .incorrectPin)
        XCTAssertTrue(vm.settings.pinEnabled, "驗證失敗不可移除 PIN")
        XCTAssertTrue(repo.getSettings().pinEnabled)
        XCTAssertEqual(repo.getFailedAttempts(), 1, "錯誤嘗試必須計入與解鎖相同的失敗計數")
    }

    /// Brute-forcing the removal screen must hit the same lockout as the unlock screen, and a
    /// correct PIN during the lockout must still be refused.
    func test_removePin_afterMaxWrongAttempts_locksOutEvenForCorrectPin() {
        let vm = SettingsViewModel(settingsRepo: repo)
        for _ in 1..<PinHasher.maxAttemptsPerTier {
            XCTAssertEqual(vm.removePin(verifyingCurrentPin: "000000"), .incorrectPin)
        }

        guard case .lockedOut(let seconds) = vm.removePin(verifyingCurrentPin: "000000") else {
            return XCTFail("第 \(PinHasher.maxAttemptsPerTier) 次錯誤必須進入鎖定")
        }
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertEqual(vm.removePin(verifyingCurrentPin: Self.currentPin), .lockedOut(remainingSeconds: seconds),
                       "鎖定期間即使 PIN 正確也不可移除")
        XCTAssertTrue(repo.getSettings().pinEnabled)
    }

    // MARK: - User-facing messages

    func test_outcomeMessage_zhHant_usesExistingPinStrings() throws {
        let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: "zh-Hant", ofType: "lproj"))
        let zhHant = try XCTUnwrap(Bundle(path: path))

        XCTAssertEqual(CurrentPinOutcome.incorrectPin.errorMessage(bundle: zhHant), "PIN 碼不正確")
        XCTAssertEqual(CurrentPinOutcome.lockedOut(remainingSeconds: 30).errorMessage(bundle: zhHant), "30 秒後重試")
        XCTAssertNil(CurrentPinOutcome.accepted.errorMessage(bundle: zhHant))
    }
}

/// LIVE-0927-4b — in Traditional Chinese the Config sheet title and its Settings row were both
/// 「設定」 (46-menu-zh-Hant). Android has the same collision, so there is no Android wording to
/// copy; the sheet title is renamed and the Settings row keeps the Android/iOS 「設定」.
final class ConfigTitleLocalizationTests: XCTestCase {

    private func string(_ key: String, _ lang: String) throws -> String {
        let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        return bundle.localizedString(forKey: key, value: "<missing>", table: nil)
    }

    func test_configTitle_differsFromSettingsRow_inEveryLanguage() throws {
        for lang in ["en", "zh-Hant", "zh-Hans"] {
            let title = try string("configuration_title", lang)
            let row = try string("Settings", lang)
            XCTAssertNotEqual(title, "<missing>", lang)
            XCTAssertNotEqual(title, row, "\(lang): 設定面板標題與其中的「設定」選項不可同名")
        }
    }

    func test_settingsRow_keepsAndroidWording() throws {
        XCTAssertEqual(try string("Settings", "zh-Hant"), "設定")
        XCTAssertEqual(try string("Settings", "zh-Hans"), "设置")
    }
}
