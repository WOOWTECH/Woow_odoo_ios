import XCTest
@testable import odoo

/// Tests for the pure PIN-lockout decisions with an injected clock — covers the counter-gated
/// (clock-forward-resistant) behavior and reboot/wall-clock correctness.
final class PinLockoutTests: XCTestCase {

    private let max = PinHasher.maxAttemptsPerTier // 5

    func test_belowThreshold_notLockedOut_evenWithFutureLockoutUntil() {
        // Counter-gated: fewer than max failures is never locked, regardless of a stale end time.
        XCTAssertFalse(isPinLockedOut(failedAttempts: max - 1, lockoutUntil: 10_000, now: 0))
    }

    func test_atThreshold_withinWindow_isLockedOut() {
        XCTAssertTrue(isPinLockedOut(failedAttempts: max, lockoutUntil: 100, now: 50))
    }

    func test_atThreshold_afterWindowElapsed_isNotLockedOut() {
        // Time has genuinely passed the end → window open (one guess allowed; counter persists).
        XCTAssertFalse(isPinLockedOut(failedAttempts: max, lockoutUntil: 100, now: 100))
        XCTAssertFalse(isPinLockedOut(failedAttempts: max, lockoutUntil: 100, now: 101))
    }

    func test_noLockoutUntil_isNotLockedOut() {
        XCTAssertFalse(isPinLockedOut(failedAttempts: max, lockoutUntil: nil, now: 0))
    }

    func test_remainingSeconds_decrementsWithTime_andClampsAtZero() {
        XCTAssertEqual(pinLockoutRemainingSeconds(lockoutUntil: 100, now: 40), 60)
        XCTAssertEqual(pinLockoutRemainingSeconds(lockoutUntil: 100, now: 99), 1)
        XCTAssertEqual(pinLockoutRemainingSeconds(lockoutUntil: 100, now: 100), 0)
        XCTAssertEqual(pinLockoutRemainingSeconds(lockoutUntil: 100, now: 500), 0) // clamp, never negative
        XCTAssertEqual(pinLockoutRemainingSeconds(lockoutUntil: nil, now: 0), 0)
    }

    func test_wallClock_survivesRebootStyleClockValues() {
        // With wall-clock epoch values (~1.7e9), a lockout set to now+30 is still locked 10s later —
        // unlike systemUptime which would reset to ~0 on reboot and mis-evaluate.
        let nowEpoch: TimeInterval = 1_785_000_000
        let end = nowEpoch + 30
        XCTAssertTrue(isPinLockedOut(failedAttempts: max, lockoutUntil: end, now: nowEpoch + 10))
        XCTAssertFalse(isPinLockedOut(failedAttempts: max, lockoutUntil: end, now: nowEpoch + 31))
    }
}
