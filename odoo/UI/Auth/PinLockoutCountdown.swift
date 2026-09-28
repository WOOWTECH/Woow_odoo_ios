import Combine
import Foundation

/// The PIN lockout countdown line ("Try again in 30s" → 29s → … → gone), shared by every PIN entry
/// screen: the unlock screen (`PinView`), Settings' change-PIN "Enter Current PIN" step
/// (`PinSetupView`) and `CurrentPinPromptView`.
///
/// A run-loop timer re-reads the remaining seconds once a second and publishes them, so the shown
/// number actually moves; at zero the countdown stops itself and `message` turns nil. Previously the
/// Settings screens wrote the message once when the PIN was refused (frozen number that never
/// cleared), and `PinView`'s timer only flipped state at expiry, so its number did not move either.
///
/// `now` is injectable so the countdown is testable without waiting (`tick()` re-reads it).
@MainActor
final class PinLockoutCountdown: ObservableObject {
    /// Whole seconds left; 0 when not locked out.
    @Published private(set) var remainingSeconds = 0

    private let now: () -> TimeInterval
    private var source: (@MainActor () -> Int)?
    private var timer: Timer?

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
    }

    var isLockedOut: Bool { remainingSeconds > 0 }

    /// The countdown line (`lockout_timer_%lld`, the unlock screen's string), or nil once it is over.
    func message(bundle: Bundle = .main) -> String? {
        guard isLockedOut else { return nil }
        return String(format: String(localized: "lockout_timer_%lld", bundle: bundle), remainingSeconds)
    }

    /// Counts down from a remaining time reported once (a refused current-PIN check). At least one
    /// second: the refusal itself proves the lockout is still on.
    func start(remainingSeconds seconds: Int) {
        let deadline = now() + TimeInterval(max(1, seconds))
        let now = self.now
        start(source: { max(0, Int((deadline - now()).rounded(.up))) })
    }

    /// Counts down a live source of remaining seconds (the unlock screen reads the repository).
    func start(source: @escaping @MainActor () -> Int) {
        self.source = source
        tick()
        guard isLockedOut else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.tick()
            }
        }
    }

    /// Re-reads the remaining seconds; at zero the countdown stops and the message clears.
    func tick() {
        remainingSeconds = max(0, source?() ?? 0)
        if remainingSeconds == 0 { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source = nil
        remainingSeconds = 0
    }

    /// Shows a refused current-PIN check on a Settings PIN prompt: a lockout counts down here (and
    /// clears itself when it ends) and returns nil; any other refusal stops the countdown and returns
    /// its static message. `.accepted` returns nil.
    func errorMessage(for outcome: CurrentPinOutcome, bundle: Bundle = .main) -> String? {
        if case .lockedOut(let seconds) = outcome {
            start(remainingSeconds: seconds)
            return nil
        }
        stop()
        return outcome.errorMessage(bundle: bundle)
    }
}
