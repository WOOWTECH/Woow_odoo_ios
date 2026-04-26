import CoreLocation
import Foundation
import WebKit

// MARK: - Notifications

extension Notification.Name {
    /// Posted on the main thread when the OS has permanently denied location access
    /// and the app should surface a "Open Settings" banner to the user.
    static let locationPermanentlyDenied = Notification.Name("io.woowtech.odoo.locationPermanentlyDenied")
}

// MARK: - PendingRequest

/// Holds the context for an in-flight geolocation request received from the JS shim.
struct PendingRequest {
    /// The `window.location.origin` string from the JS postMessage.
    let origin: String
    /// A weak reference to the WKWebView that sent the request (to avoid retain cycles).
    weak var webView: WKWebView?
}

// MARK: - LocationCoordinator

/// Bridges the JS shim message handler with CLLocationManager and LocationPermissionGate.
///
/// Lifecycle:
/// - Installed once per WKWebViewConfiguration in OdooWebView.makeUIView.
/// - Receives `{requestId, origin}` messages via the "requestLocation" handler.
/// - Resolves the gate, fetches a single location via CLLocationManager.requestLocation(),
///   then calls back into the WebView with __woowResolveGeo / __woowRejectGeo.
///
/// Thread safety: all mutable state and CLLocationManager calls are confined to @MainActor.
/// The WKScriptMessageHandler entry point is `nonisolated` (WKWebKit requirement) and
/// dispatches to the main actor immediately.
@MainActor
final class LocationCoordinator: NSObject, CLLocationManagerDelegate {

    // MARK: - Dependencies

    private let gate: LocationPermissionGate
    /// Closure that returns the currently active account's server host.
    /// Must be a closure (not a captured value) so it always reflects the latest
    /// account after an account switch — avoids the iOS equivalent of the Android
    /// stale-closure bug identified in the v2 architect review.
    private let activeAccountHost: () -> String?
    private let locationManager: CLLocationManager

    // MARK: - Pending requests (keyed by per-request UUID from the shim)

    private var pendingRequests: [String: PendingRequest] = [:]

    // MARK: - Init

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - gate: The `LocationPermissionGate` that decides whether to grant each request.
    ///   - activeAccountHost: A closure returning the current active account's hostname.
    ///                        Evaluated on every request — never captured at init time.
    ///   - locationManager: The `CLLocationManager` instance (injectable for testing).
    init(
        gate: LocationPermissionGate,
        activeAccountHost: @escaping () -> String?,
        locationManager: CLLocationManager = CLLocationManager()
    ) {
        self.gate = gate
        self.activeAccountHost = activeAccountHost
        self.locationManager = locationManager
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    // MARK: - WKScriptMessageHandler entry (registered via MessageHandlerProxy)

    /// Processes an incoming `{requestId, origin}` message from the geolocation shim.
    /// Must be called on the main actor — `MessageHandlerProxy` ensures this.
    func handleMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let requestId = body["requestId"] as? String,
              let originString = body["origin"] as? String,
              let webView = message.webView
        else {
            return
        }

        let originURL = URL(string: originString)
        let decision = gate.resolve(origin: originURL, activeAccountHost: activeAccountHost())

        switch decision {
        case .grant:
            pendingRequests[requestId] = PendingRequest(origin: originString, webView: webView)
            locationManager.requestLocation()

        case .reject(let reason):
            if reason == "os-denied" {
                NotificationCenter.default.post(name: .locationPermanentlyDenied, object: nil)
            }
            evaluateReject(requestId: requestId, code: 1, message: reason, in: webView)

        case .needsRuntimePrompt:
            // Stash the request and ask the OS for permission.
            // After the status changes, locationManagerDidChangeAuthorization re-resolves.
            pendingRequests[requestId] = PendingRequest(origin: originString, webView: webView)
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Re-evaluate all pending requests that were deferred awaiting a runtime prompt.
        let pendingCopy = pendingRequests
        for (requestId, request) in pendingCopy {
            guard let webView = request.webView else {
                pendingRequests.removeValue(forKey: requestId)
                continue
            }
            let originURL = URL(string: request.origin)
            let decision = gate.resolve(origin: originURL, activeAccountHost: activeAccountHost())
            switch decision {
            case .grant:
                // Status is now authorised — request one location fix.
                // The existing entry in pendingRequests is reused for the CLLocation callback.
                locationManager.requestLocation()
            case .reject(let reason):
                pendingRequests.removeValue(forKey: requestId)
                evaluateReject(requestId: requestId, code: 1, message: reason, in: webView)
            case .needsRuntimePrompt:
                // Still not determined — leave in pending; will be triggered again on next change.
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        if location.horizontalAccuracy < 0 {
            // Negative accuracy means the location is invalid.
            failAllPending(code: 2, message: "location-invalid-accuracy")
            return
        }

        if manager.accuracyAuthorization == .reducedAccuracy {
            #if DEBUG
            print("[LocationCoordinator] Delivering reduced-accuracy location (~1-3km centroid)")
            #endif
        }

        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        let accuracy = location.horizontalAccuracy

        // Deliver to all pending requests — a single CLLocation fix serves them all.
        let pendingCopy = pendingRequests
        pendingRequests.removeAll()
        for (requestId, request) in pendingCopy {
            guard let webView = request.webView else { continue }
            let js = "__woowResolveGeo('\(requestId)', \(lat), \(lng), \(accuracy));"
            webView.evaluateJavaScript(js) { _, error in
                #if DEBUG
                if let error {
                    print("[LocationCoordinator] evaluateJavaScript resolve failed: \(error.localizedDescription)")
                }
                #endif
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let clError = error as? CLError
        let code: Int
        let message: String
        switch clError?.code {
        case .denied:
            code = 1
            message = "location-denied"
        case .locationUnknown:
            code = 2
            message = "location-unknown"
        default:
            code = 2
            message = "location-error"
        }
        failAllPending(code: code, message: message)
    }

    // MARK: - Private helpers

    private func evaluateReject(requestId: String, code: Int, message: String, in webView: WKWebView) {
        let safeMessage = message.replacingOccurrences(of: "'", with: "\\'")
        let js = "__woowRejectGeo('\(requestId)', \(code), '\(safeMessage)');"
        webView.evaluateJavaScript(js) { _, error in
            #if DEBUG
            if let error {
                print("[LocationCoordinator] evaluateJavaScript reject failed: \(error.localizedDescription)")
            }
            #endif
        }
    }

    private func failAllPending(code: Int, message: String) {
        let pendingCopy = pendingRequests
        pendingRequests.removeAll()
        for (requestId, request) in pendingCopy {
            guard let webView = request.webView else { continue }
            evaluateReject(requestId: requestId, code: code, message: message, in: webView)
        }
    }
}

// MARK: - MessageHandlerProxy

/// A lightweight proxy that satisfies WKScriptMessageHandler (nonisolated) while
/// forwarding to the @MainActor-confined LocationCoordinator.
///
/// Without this proxy, WKWebKit would retain `LocationCoordinator` directly through
/// the message handler, creating a retain cycle (WKWebView → config → handler → coordinator
/// → webView). The proxy is retained by WebKit; coordinator is held weakly.
final class LocationMessageHandlerProxy: NSObject, WKScriptMessageHandler {

    private weak var coordinator: LocationCoordinator?

    init(coordinator: LocationCoordinator) {
        self.coordinator = coordinator
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let coordinator else { return }
        Task { @MainActor in
            coordinator.handleMessage(message)
        }
    }
}
