import XCTest
@testable import odoo

/// PinSetupView's "Enter Current PIN" step showed "Incorrect PIN" for every refusal — including a
/// lockout, when even the correct PIN is refused. The user then kept typing the right PIN, kept
/// being told it was wrong, and never learned they had to wait. During a lockout the step now shows
/// the unlock screen's existing countdown string (`lockout_timer_%lld`), like CurrentPinPromptView.
@MainActor
final class PinSetupVerifyOldLockoutTests: XCTestCase {

    private func bundle(_ lang: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func test_verifyOld_givenLockedOut_showsCountdownNotIncorrectPin() throws {
        let en = try bundle("en")
        XCTAssertEqual(pinSetupVerifyOldResult(for: .lockedOut(remainingSeconds: 30), bundle: en),
                       .stay(error: "Try again in 30s"))
        let zhHant = try bundle("zh-Hant")
        XCTAssertEqual(pinSetupVerifyOldResult(for: .lockedOut(remainingSeconds: 30), bundle: zhHant),
                       .stay(error: "30 秒後重試"))
    }

    func test_verifyOld_givenIncorrectPin_showsIncorrectPin() throws {
        XCTAssertEqual(pinSetupVerifyOldResult(for: .incorrectPin, bundle: try bundle("en")),
                       .stay(error: "Incorrect PIN"))
    }

    func test_verifyOld_givenAccepted_advances() throws {
        XCTAssertEqual(pinSetupVerifyOldResult(for: .accepted, bundle: try bundle("en")), .advance)
    }

    /// End to end through the real ViewModel: five wrong entries lock out, and the correct PIN
    /// entered during the lockout is answered with the countdown, not "Incorrect PIN".
    func test_verifyOld_correctPinDuringRealLockout_showsCountdown() throws {
        var clock: TimeInterval = 1_800_000_000
        let repo = SettingsRepository(now: { clock })
        repo.removePin()
        repo.resetFailedAttempts()
        XCTAssertTrue(repo.setPin("864200"))
        defer {
            repo.removePin()
            repo.resetFailedAttempts()
        }
        let vm = SettingsViewModel(settingsRepo: repo)
        for _ in 0..<PinHasher.maxAttemptsPerTier {
            _ = vm.authorizePinChange(verifyingCurrentPin: "000000")
        }
        clock += 1

        let outcome = vm.authorizePinChange(verifyingCurrentPin: "864200")
        guard case .lockedOut(let seconds) = outcome else {
            return XCTFail("鎖定期間正確 PIN 也必須被拒絕，實得 \(outcome)")
        }
        XCTAssertEqual(pinSetupVerifyOldResult(for: outcome, bundle: try bundle("en")),
                       .stay(error: "Try again in \(seconds)s"))
    }
}
