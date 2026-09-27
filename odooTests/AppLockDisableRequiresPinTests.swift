import XCTest
@testable import odoo

/// Turning App Lock off in Settings was one unverified tap (`SettingsView` → `toggleAppLock(false)`
/// → `setAppLock(false)`): anyone holding an unlocked phone could switch the lock off. Android
/// f9a0207 fixed the same gap. With a PIN set, turning App Lock off now requires the current PIN,
/// verified through the unlock path (same failed-attempt counter and lockout), and the ViewModel
/// refuses an unverified "off".
///
/// Uses the real `SettingsRepository` (simulator Keychain) with an injected clock, cleaned in both
/// setUp and tearDown like `PinRemovalVerificationTests`.
@MainActor
final class AppLockDisableRequiresPinTests: XCTestCase {

    private static let currentPin = "135790"
    private var clock: TimeInterval = 1_800_000_000
    private var repo: SettingsRepository!

    override func setUp() {
        super.setUp()
        repo = SettingsRepository(now: { [unowned self] in self.clock })
        repo.removePin()
        repo.resetFailedAttempts()
        XCTAssertTrue(repo.setPin(Self.currentPin))
        repo.setAppLock(true)
    }

    override func tearDown() {
        repo.removePin()
        repo.resetFailedAttempts()
        repo.setAppLock(false)
        repo = nil
        super.tearDown()
    }

    // MARK: - Unverified "off" is refused

    func test_toggleAppLockOff_givenPinSet_refusesAndStaysOn() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertFalse(vm.toggleAppLock(false), "已設 PIN 時不可未經驗證關閉 App Lock")
        XCTAssertTrue(vm.settings.appLockEnabled, "開關必須維持開啟")
        XCTAssertTrue(repo.isAppLockEnabled(), "儲存的 App Lock 必須維持開啟")
    }

    /// A lock without a PIN (legacy / biometric-only state) has nothing to verify against, so it
    /// can still be switched off directly — same as Android.
    func test_toggleAppLockOff_givenNoPin_turnsOff() {
        repo.removePin()
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertTrue(vm.toggleAppLock(false))
        XCTAssertFalse(vm.settings.appLockEnabled)
        XCTAssertFalse(repo.isAppLockEnabled())
    }

    func test_toggleAppLockOn_givenPinSet_turnsOn() {
        repo.setAppLock(false)
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertTrue(vm.toggleAppLock(true))
        XCTAssertTrue(repo.isAppLockEnabled())
    }

    // MARK: - Verified "off"

    func test_disableAppLock_givenCorrectPin_turnsOff() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertEqual(vm.disableAppLock(verifyingCurrentPin: Self.currentPin), .accepted)
        XCTAssertFalse(vm.settings.appLockEnabled)
        XCTAssertFalse(repo.isAppLockEnabled())
        XCTAssertTrue(repo.getSettings().pinEnabled, "關閉 App Lock 不應順帶移除 PIN")
    }

    func test_disableAppLock_givenWrongPin_staysOnAndCountsFailure() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertEqual(vm.disableAppLock(verifyingCurrentPin: "000000"), .incorrectPin)
        XCTAssertTrue(vm.settings.appLockEnabled)
        XCTAssertTrue(repo.isAppLockEnabled())
        XCTAssertEqual(repo.getFailedAttempts(), 1, "錯誤嘗試必須計入與解鎖相同的失敗計數")
    }

    /// Brute-forcing the "turn off" prompt hits the unlock screen's lockout, and a correct PIN
    /// during the lockout is still refused.
    func test_disableAppLock_afterMaxWrongAttempts_locksOutEvenForCorrectPin() {
        let vm = SettingsViewModel(settingsRepo: repo)
        for _ in 1..<PinHasher.maxAttemptsPerTier {
            XCTAssertEqual(vm.disableAppLock(verifyingCurrentPin: "000000"), .incorrectPin)
        }

        guard case .lockedOut(let seconds) = vm.disableAppLock(verifyingCurrentPin: "000000") else {
            return XCTFail("第 \(PinHasher.maxAttemptsPerTier) 次錯誤必須進入鎖定")
        }
        XCTAssertGreaterThan(seconds, 0)
        XCTAssertEqual(vm.disableAppLock(verifyingCurrentPin: Self.currentPin), .lockedOut(remainingSeconds: seconds),
                       "鎖定期間即使 PIN 正確也不可關閉 App Lock")
        XCTAssertTrue(repo.isAppLockEnabled())
    }

    // MARK: - Prompt subtitle (Android app_lock_disable_pin_subtitle)

    func test_disableSubtitle_isTranslatedInEveryLanguage() throws {
        let expected = [
            "en": "Enter your current PIN to turn off App Lock",
            "zh-Hant": "輸入目前的 PIN 碼以關閉應用程式鎖定",
            "zh-Hans": "输入当前的 PIN 码以关闭应用程序锁定",
        ]
        for (lang, text) in expected {
            let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "app_lock_disable_pin_subtitle", value: "<missing>", table: nil),
                           text, lang)
        }
    }
}
