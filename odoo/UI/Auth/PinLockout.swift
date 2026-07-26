import Foundation

/// Pure lockout decisions for PIN entry, extracted so they are unit-testable with an injected clock
/// (no Keychain, no real wall-clock).
///
/// The failure COUNTER is the durable primary gate: `isPinLockedOut` requires
/// `failedAttempts >= PinHasher.maxAttemptsPerTier`, and `failedPinAttempts` resets only on a
/// correct PIN (never on lockout expiry). So even if the device clock is moved forward to escape the
/// timed window, the counter stays tripped and the escalating tiers (`PinHasher.lockoutDuration`)
/// keep growing the wait — a clock-forward yields at most one guess per jump, not free access.
/// Time can only SHORTEN the wait, never grant attempts.

/// Whether PIN entry is currently locked out. Counter-gated AND time-gated: the counter must be at
/// or above the tier threshold AND the timed window must not yet have elapsed.
func isPinLockedOut(failedAttempts: Int, lockoutUntil: TimeInterval?, now: TimeInterval) -> Bool {
    guard failedAttempts >= PinHasher.maxAttemptsPerTier else { return false }
    guard let end = lockoutUntil else { return false }
    return now < end
}

/// Seconds remaining on the current lockout window (0 if none / already elapsed).
func pinLockoutRemainingSeconds(lockoutUntil: TimeInterval?, now: TimeInterval) -> Int {
    guard let end = lockoutUntil else { return 0 }
    return max(0, Int(end - now))
}
