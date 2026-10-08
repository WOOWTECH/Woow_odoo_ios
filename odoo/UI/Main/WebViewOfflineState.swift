import Combine
import Foundation
import Network

/// Whether the main screen covers the WebView with the app's own offline screen (W2-4 L1).
///
/// Owned by `MainView` (a `@StateObject`) and driven only by `OdooWebViewCoordinator`: the
/// coordinator shows it when the current account's main-frame load fails for a network reason and
/// hides it on the next committed page, account switch or retirement. The retry button calls
/// `retry()`, which the coordinator wires to its own `retryAfterLoadFailure()` — so a retry always
/// reloads the coordinator's *current* account WebView and never a replaced one.
///
/// The screen never shows the server address or the WebKit / `NSURLError` text: before this the
/// failed load left a blank page with no way to retry (iOS), or WebView's built-in error page with
/// the server URL and `net::ERR_…` code (Android).
final class WebViewOfflineState: ObservableObject {
    @Published private(set) var isShowingOfflineScreen = false

    /// Set by the coordinator. Weakly captures it, so a stale coordinator is a no-op.
    var retryAction: (() -> Void)?

    func setShowing(_ showing: Bool) {
        guard isShowingOfflineScreen != showing else { return }
        isShowingOfflineScreen = showing
    }

    func retry() {
        retryAction?()
    }
}

// MARK: - Network recovery

/// Watches the network after a failed load and reports, once, when it comes back.
protocol NetworkRecoveryMonitoring: AnyObject {
    /// Starts (or restarts) watching. `onRecovered` runs at most once, on the main queue, the first
    /// time the network becomes usable after having been unusable since this call.
    func start(onRecovered: @escaping () -> Void)
    func stop()
}

/// Pure transition rule behind `NWPathRecoveryMonitor`: fire once on unsatisfied → satisfied.
///
/// `NWPathMonitor` reports the current path immediately on start. When that first report is
/// already satisfied (the network is up but the server is unreachable, or the network came back
/// before monitoring started) nothing fires — otherwise a failing server would be retried in a
/// loop. The user still has the retry button.
struct NetworkRecoveryDetector {
    private var sawUnusable = false
    private(set) var hasFired = false

    /// Feeds one path report; returns `true` exactly once, on the first recovery.
    mutating func observe(isSatisfied: Bool) -> Bool {
        guard !hasFired else { return false }
        guard isSatisfied else {
            sawUnusable = true
            return false
        }
        guard sawUnusable else { return false }
        hasFired = true
        return true
    }
}

/// `NetworkRecoveryMonitoring` backed by `NWPathMonitor` (no network I/O; it only observes the
/// system's path state). One monitor per `start`; `stop` cancels it.
final class NWPathRecoveryMonitor: NetworkRecoveryMonitoring {
    private var monitor: NWPathMonitor?
    private var detector = NetworkRecoveryDetector()
    private var onRecovered: (() -> Void)?

    func start(onRecovered: @escaping () -> Void) {
        stop()
        detector = NetworkRecoveryDetector()
        self.onRecovered = onRecovered
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            // A report queued by a monitor that has since been replaced or cancelled is ignored.
            guard let self, let monitor, self.monitor === monitor else { return }
            self.handle(isSatisfied: path.status == .satisfied)
        }
        self.monitor = monitor
        monitor.start(queue: .main)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        onRecovered = nil
    }

    private func handle(isSatisfied: Bool) {
        guard detector.observe(isSatisfied: isSatisfied), let action = onRecovered else { return }
        stop()
        action()
    }

    deinit {
        monitor?.cancel()
    }
}
