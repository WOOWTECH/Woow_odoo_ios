import XCTest
@testable import odoo

/// verify-20260928 iOS（低）：設定頁「變更 PIN」的驗證目前 PIN 步驟（PinSetupView）與 CurrentPinPromptView
/// 在鎖定時只寫一次「Try again in 30s」，數字不會動、到期也不會消失；解鎖畫面 PinView 雖有每秒計時器，
/// 但計時器只在到期時改狀態，畫面上的秒數同樣不動。三處改為共用 `PinLockoutCountdown`：每秒重算剩餘秒數、
/// 到期自動清除訊息。
@MainActor
final class PinLockoutCountdownTests: XCTestCase {

    private var clock: TimeInterval = 1_800_000_000
    private var countdown: PinLockoutCountdown!

    override func setUp() {
        super.setUp()
        countdown = PinLockoutCountdown(now: { [unowned self] in self.clock })
    }

    override func tearDown() {
        countdown.stop()
        countdown = nil
        super.tearDown()
    }

    private func bundle(_ lang: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: SettingsViewModel.self).path(forResource: lang, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func test_tick_givenLockoutReportedAt30s_countsDownEverySecondThenClears() throws {
        let en = try bundle("en")
        countdown.start(remainingSeconds: 30)
        XCTAssertTrue(countdown.isLockedOut)
        XCTAssertEqual(countdown.message(bundle: en), "Try again in 30s")

        clock += 1
        countdown.tick()
        XCTAssertEqual(countdown.message(bundle: en), "Try again in 29s")

        clock += 28.5
        countdown.tick()
        XCTAssertEqual(countdown.message(bundle: en), "Try again in 1s")

        clock += 0.5
        countdown.tick()
        XCTAssertFalse(countdown.isLockedOut)
        XCTAssertNil(countdown.message(bundle: en), "到期後訊息必須自動清除")
    }

    func test_message_givenTraditionalChinese_returnsLocalizedCountdown() throws {
        countdown.start(remainingSeconds: 30)
        XCTAssertEqual(countdown.message(bundle: try bundle("zh-Hant")), "30 秒後重試")
    }

    /// Driven by the real run-loop timer, not by manual ticks: the shown seconds change on their own.
    func test_timer_givenRealClock_updatesEachSecondWithoutManualTicks() {
        let live = PinLockoutCountdown()
        defer { live.stop() }
        live.start(remainingSeconds: 2)
        XCTAssertEqual(live.remainingSeconds, 2)

        // No manual tick() anywhere: only the run loop runs. A generous deadline keeps the test
        // stable on a loaded machine while still proving the value changes on its own.
        XCTAssertTrue(runMainLoop(until: { live.remainingSeconds == 1 }, timeout: 3),
                      "計時器每秒必須自行更新顯示的秒數")
        XCTAssertTrue(runMainLoop(until: { live.remainingSeconds == 0 && !live.isLockedOut }, timeout: 3),
                      "倒數到期後必須自行解除鎖定")
    }

    private func runMainLoop(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func test_start_givenLockedOutReportedAsZeroSeconds_stillShowsOneSecond() {
        // A refusal proves the lockout is still on even when the whole seconds left round down to 0.
        countdown.start(remainingSeconds: 0)
        XCTAssertEqual(countdown.remainingSeconds, 1)
    }

    func test_startSource_givenLiveSource_followsItAndStopsAtZero() {
        var repositorySeconds = 12
        countdown.start(source: { repositorySeconds })
        XCTAssertEqual(countdown.remainingSeconds, 12)

        repositorySeconds = 11
        countdown.tick()
        XCTAssertEqual(countdown.remainingSeconds, 11)

        repositorySeconds = 0
        countdown.tick()
        XCTAssertFalse(countdown.isLockedOut)

        repositorySeconds = 5
        countdown.tick()
        XCTAssertFalse(countdown.isLockedOut, "停止後不可再被舊的來源重新點亮")
    }

    // MARK: - Shared handling of a refused current-PIN check (PinSetupView / CurrentPinPromptView)

    func test_errorMessage_givenLockedOut_returnsNilAndCountsDown() throws {
        let en = try bundle("en")
        XCTAssertNil(countdown.errorMessage(for: .lockedOut(remainingSeconds: 30), bundle: en))
        XCTAssertEqual(countdown.message(bundle: en), "Try again in 30s")

        clock += 1
        countdown.tick()
        XCTAssertEqual(countdown.message(bundle: en), "Try again in 29s")
    }

    func test_errorMessage_givenIncorrectPinAfterLockout_returnsIncorrectPinAndStopsCountdown() throws {
        let en = try bundle("en")
        _ = countdown.errorMessage(for: .lockedOut(remainingSeconds: 30), bundle: en)

        XCTAssertEqual(countdown.errorMessage(for: .incorrectPin, bundle: en), "Incorrect PIN")
        XCTAssertFalse(countdown.isLockedOut)
        XCTAssertNil(countdown.message(bundle: en))
    }

    func test_errorMessage_givenAccepted_returnsNilAndStopsCountdown() throws {
        let en = try bundle("en")
        _ = countdown.errorMessage(for: .lockedOut(remainingSeconds: 30), bundle: en)

        XCTAssertNil(countdown.errorMessage(for: .accepted, bundle: en))
        XCTAssertFalse(countdown.isLockedOut)
    }

    /// End to end through the real ViewModel and repository clock: the countdown the Settings
    /// prompt shows after a real lockout reaches zero when the repository's lockout ends.
    func test_errorMessage_givenRealLockout_clearsWhenRepositoryLockoutEnds() throws {
        let repo = SettingsRepository(now: { [unowned self] in self.clock })
        repo.removePin()
        repo.resetFailedAttempts()
        XCTAssertTrue(repo.setPin("864200"))
        defer {
            repo.removePin()
            repo.resetFailedAttempts()
        }
        let vm = SettingsViewModel(settingsRepo: repo)
        var outcome = CurrentPinOutcome.accepted
        for _ in 0..<PinHasher.maxAttemptsPerTier {
            outcome = vm.authorizePinChange(verifyingCurrentPin: "000000")
        }
        guard case .lockedOut = outcome else { return XCTFail("第 5 次錯誤必須鎖定，實得 \(outcome)") }

        XCTAssertNil(countdown.errorMessage(for: outcome, bundle: try bundle("en")))
        XCTAssertTrue(countdown.isLockedOut)

        clock += TimeInterval(repo.getLockoutRemainingSeconds() + 1)
        countdown.tick()
        XCTAssertFalse(countdown.isLockedOut)
        XCTAssertFalse(repo.isLockedOut())
    }
}
