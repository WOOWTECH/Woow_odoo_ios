import XCTest
@testable import odoo

/// Replacing an existing PIN used to need no proof of the current one at the ViewModel:
/// `SettingsViewModel.setPin` wrote whatever it was given, and the only check was PinSetupView's own
/// `.verifyOld` step on a separate ViewModel instance. Anyone who could reach `setPin` could
/// replace the PIN and then pass "turn App Lock off" with the new one. Android 9f5f007 fixed the
/// same gap. Now, with a PIN set, `setPin` is refused unless `authorizePinChange(verifyingCurrentPin:)`
/// just verified the current PIN (unlock path: same counter and lockout); the authorization is
/// single-use and `cancelPinChange()` revokes it. First-time setup needs no verification.
///
/// Uses the real `SettingsRepository` (simulator Keychain) with an injected clock, cleaned in both
/// setUp and tearDown like `PinRemovalVerificationTests`.
@MainActor
final class ChangePinRequiresCurrentPinTests: XCTestCase {

    private static let currentPin = "246801"
    private static let newPin = "975312"
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

    private func assertPinUnchanged(file: StaticString = #filePath, line: UInt = #line) {
        let hash = repo.getSettings().pinHash
        XCTAssertNotNil(hash, "PIN 不可被移除", file: file, line: line)
        XCTAssertFalse(PinHasher.verify(pin: Self.newPin, against: hash ?? ""), "新 PIN 不可生效", file: file, line: line)
        XCTAssertTrue(PinHasher.verify(pin: Self.currentPin, against: hash ?? ""), "原 PIN 必須仍有效", file: file, line: line)
    }

    // MARK: - Unverified change is refused

    func test_setPin_givenPinSetAndNotVerified_refusesAndKeepsPin() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertFalse(vm.setPin(Self.newPin), "已設 PIN 時未驗證目前 PIN 不可變更")
        assertPinUnchanged()
    }

    func test_authorizePinChange_givenWrongPin_countsFailureAndRefusesChange() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertEqual(vm.authorizePinChange(verifyingCurrentPin: "000000"), .incorrectPin)
        XCTAssertEqual(repo.getFailedAttempts(), 1, "錯誤嘗試必須計入與解鎖相同的失敗計數")
        XCTAssertFalse(vm.setPin(Self.newPin))
        assertPinUnchanged()
    }

    // MARK: - Verified change

    func test_authorizePinChange_givenCorrectPin_allowsOneChange() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertEqual(vm.authorizePinChange(verifyingCurrentPin: Self.currentPin), .accepted)
        XCTAssertTrue(vm.setPin(Self.newPin))
        let hash = repo.getSettings().pinHash ?? ""
        XCTAssertTrue(PinHasher.verify(pin: Self.newPin, against: hash), "驗證後新 PIN 必須生效")
        XCTAssertTrue(vm.settings.pinEnabled)
    }

    func test_authorizePinChange_isSingleUse() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertEqual(vm.authorizePinChange(verifyingCurrentPin: Self.currentPin), .accepted)
        XCTAssertTrue(vm.setPin(Self.newPin))
        XCTAssertFalse(vm.setPin("111111"), "一次驗證只授權一次變更")
        let hash = repo.getSettings().pinHash ?? ""
        XCTAssertTrue(PinHasher.verify(pin: Self.newPin, against: hash))
    }

    func test_cancelPinChange_revokesAuthorization() {
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertEqual(vm.authorizePinChange(verifyingCurrentPin: Self.currentPin), .accepted)
        vm.cancelPinChange()
        XCTAssertFalse(vm.setPin(Self.newPin), "取消變更後授權必須失效")
        assertPinUnchanged()
    }

    /// Brute-forcing the change prompt hits the unlock screen's lockout, and a correct PIN during
    /// the lockout neither authorizes nor changes anything.
    func test_authorizePinChange_duringLockout_refusesCorrectPin() {
        let vm = SettingsViewModel(settingsRepo: repo)
        for _ in 1..<PinHasher.maxAttemptsPerTier {
            XCTAssertEqual(vm.authorizePinChange(verifyingCurrentPin: "000000"), .incorrectPin)
        }
        guard case .lockedOut(let seconds) = vm.authorizePinChange(verifyingCurrentPin: "000000") else {
            return XCTFail("第 \(PinHasher.maxAttemptsPerTier) 次錯誤必須進入鎖定")
        }

        XCTAssertEqual(vm.authorizePinChange(verifyingCurrentPin: Self.currentPin), .lockedOut(remainingSeconds: seconds),
                       "鎖定期間即使 PIN 正確也不可授權變更")
        XCTAssertFalse(vm.setPin(Self.newPin))
        assertPinUnchanged()
    }

    // MARK: - First-time setup

    func test_setPin_givenNoPinYet_storesWithoutVerification() {
        repo.removePin()
        let vm = SettingsViewModel(settingsRepo: repo)

        XCTAssertTrue(vm.setPin(Self.newPin), "首次設定不需驗證")
        let hash = repo.getSettings().pinHash ?? ""
        XCTAssertTrue(PinHasher.verify(pin: Self.newPin, against: hash))
        XCTAssertTrue(vm.settings.pinEnabled)
    }
}
