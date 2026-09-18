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
    /// The caller-supplied request id, echoed back verbatim in the JS callback.
    ///
    /// This is NOT the dictionary key: `pendingRequests` is keyed by a coordinator-generated
    /// token so that two frames of the same page reusing one request id cannot displace each
    /// other's in-flight request.
    let requestId: String
    /// The `window.location.origin` string from the JS postMessage.
    let origin: String
    /// The document generation that was current when the request arrived.
    ///
    /// A single WKWebView outlives the documents loaded into it (self-heal re-login, deep-link
    /// navigation, reload). A fix that arrives after the document changed belongs to a page that
    /// no longer exists, so it must never be handed to whatever is on screen now.
    let generation: UInt64
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
    /// Closure that returns the currently active account's explicit port, or nil for the
    /// HTTPS default. Read on every request for the same reason as `activeAccountHost`.
    private let activeAccountPort: () -> Int?
    private let locationManager: CLLocationManager

    // MARK: - Pending requests

    /// In-flight requests, keyed by a token this coordinator generates — never by the
    /// caller-supplied request id. Any frame in the page can post to the message handler
    /// (the shim and handler are installed with `forMainFrameOnly: false`), so a caller-
    /// supplied key lets one frame silently overwrite another frame's pending request.
    private var pendingRequests: [UUID: PendingRequest] = [:]

    /// Incremented every time the hosting WebView starts loading a new document or is rebuilt
    /// for a different account. Requests stamped with an older generation are discarded.
    private var currentGeneration: UInt64 = 0

    // MARK: - Init

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - gate: The `LocationPermissionGate` that decides whether to grant each request.
    ///   - activeAccountHost: A closure returning the current active account's hostname.
    ///                        Evaluated on every request — never captured at init time.
    ///   - locationManager: The `CLLocationManager` instance (injectable for testing).
    ///   - activeAccountPort: A closure returning the active account's explicit port, or nil
    ///                        when the server URL carries none. Defaults to `{ nil }` (the
    ///                        HTTPS default port) so existing callers are unaffected.
    init(
        gate: LocationPermissionGate,
        activeAccountHost: @escaping () -> String?,
        activeAccountPort: @escaping () -> Int? = { nil },
        locationManager: CLLocationManager = CLLocationManager()
    ) {
        self.gate = gate
        self.activeAccountHost = activeAccountHost
        self.activeAccountPort = activeAccountPort
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

        // The request id is interpolated into a JavaScript string literal on both the
        // resolve and the reject path, and the reject path runs for requests the gate
        // REFUSED — i.e. it needs no permission at all. Accept only the shape the shim
        // generates, and never echo a malformed id back into the page.
        guard Self.isShimGeneratedRequestId(requestId) else {
            AppLogger.location.error("Rejected geolocation request: malformed requestId")
            return
        }

        let originURL = URL(string: originString)
        let decision = gate.resolve(
            origin: originURL,
            activeAccountHost: activeAccountHost(),
            activeAccountPort: activeAccountPort()
        )

        switch decision {
        case .grant:
            pendingRequests[UUID()] = PendingRequest(
                requestId: requestId, origin: originString,
                generation: currentGeneration, webView: webView)
            locationManager.requestLocation()

        case .reject(let reason):
            if reason == "os-denied" {
                NotificationCenter.default.post(name: .locationPermanentlyDenied, object: nil)
            }
            evaluateReject(requestId: requestId, code: 1, message: reason, in: webView)

        case .needsRuntimePrompt:
            // Stash the request and ask the OS for permission.
            // After the status changes, locationManagerDidChangeAuthorization re-resolves.
            pendingRequests[UUID()] = PendingRequest(
                requestId: requestId, origin: originString,
                generation: currentGeneration, webView: webView)
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Re-evaluate all pending requests that were deferred awaiting a runtime prompt.
        let pendingCopy = pendingRequests
        for (token, request) in pendingCopy {
            guard let webView = request.webView else {
                pendingRequests.removeValue(forKey: token)
                continue
            }
            let originURL = URL(string: request.origin)
            let decision = gate.resolve(
                origin: originURL,
                activeAccountHost: activeAccountHost(),
                activeAccountPort: activeAccountPort()
            )
            switch decision {
            case .grant:
                // Status is now authorised — request one location fix.
                // The existing entry in pendingRequests is reused for the CLLocation callback.
                locationManager.requestLocation()
            case .reject(let reason):
                pendingRequests.removeValue(forKey: token)
                evaluateReject(requestId: request.requestId, code: 1, message: reason, in: webView)
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
            AppLogger.location.info("Delivering reduced-accuracy location (~1-3km centroid)")
        }

        let lat = location.coordinate.latitude
        let lng = location.coordinate.longitude
        let accuracy = location.horizontalAccuracy

        // Deliver the fix — but only to requests that are STILL entitled to it.
        //
        // A grant is checked when the request arrives; the fix lands later. In between the user
        // can revoke consent (app switch or OS permission), or the page can be replaced. The
        // gate must therefore be re-run at delivery time, otherwise a position is handed over
        // after consent was withdrawn — which also contradicts "location only on an explicit
        // clock-in, no background tracking".
        let pendingCopy = pendingRequests
        pendingRequests.removeAll()
        for (_, request) in pendingCopy {
            guard let webView = request.webView else { continue }

            // Stale generation: the document that asked is gone. It was already answered once by
            // `invalidateActiveDocument()`, so answering again would break callback-exactly-once.
            guard request.generation == currentGeneration else {
                AppLogger.location.info("Discarding location for a replaced document")
                continue
            }

            // Consent may have been withdrawn while the fix was in flight.
            let decision = gate.resolve(
                origin: URL(string: request.origin),
                activeAccountHost: activeAccountHost(),
                activeAccountPort: activeAccountPort()
            )
            guard case .grant = decision else {
                let reason: String
                switch decision {
                case .reject(let r): reason = r
                case .needsRuntimePrompt: reason = "permission-not-determined"
                case .grant: reason = ""  // unreachable: guarded above
                }
                AppLogger.location.info("Withholding location: gate no longer grants this request")
                evaluateReject(requestId: request.requestId, code: 1, message: reason, in: webView)
                continue
            }

            let safeRequestId = Self.jsStringLiteralEscaped(request.requestId)
            let js = "__woowResolveGeo('\(safeRequestId)', \(lat), \(lng), \(accuracy));"
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    AppLogger.location.error("evaluateJavaScript resolve failed: \(error.localizedDescription, privacy: .public)")
                }
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
        let safeRequestId = Self.jsStringLiteralEscaped(requestId)
        let safeMessage = Self.jsStringLiteralEscaped(message)
        let js = "__woowRejectGeo('\(safeRequestId)', \(code), '\(safeMessage)');"
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                AppLogger.location.error("evaluateJavaScript reject failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func failAllPending(code: Int, message: String) {
        let pendingCopy = pendingRequests
        pendingRequests.removeAll()
        for (_, request) in pendingCopy {
            guard let webView = request.webView else { continue }
            evaluateReject(requestId: request.requestId, code: code, message: message, in: webView)
        }
    }

    // MARK: - Document lifecycle

    /// Invalidates every in-flight request that belongs to the document being replaced.
    ///
    /// Called by the hosting WebView when a new document starts loading or the WebView is rebuilt
    /// for another account. Each outstanding request is answered ONCE with a rejection rather than
    /// being dropped silently, so a clock-in button waiting on `getCurrentPosition` cannot hang
    /// forever; the subsequent CLLocation fix then finds no matching generation and is discarded.
    func invalidateActiveDocument() {
        currentGeneration &+= 1
        let superseded = pendingRequests.filter { $0.value.generation < currentGeneration }
        for (token, request) in superseded {
            pendingRequests.removeValue(forKey: token)
            guard let webView = request.webView else { continue }
            evaluateReject(requestId: request.requestId, code: 1, message: "context-changed", in: webView)
        }
    }

    // MARK: - Request id hardening

    /// Accepts only the request id shape `geolocation_shim.js` produces: a UUID-style
    /// 8-4-4-4-12 hex string.
    ///
    /// The shim is not a trust boundary — page JavaScript can call
    /// `webkit.messageHandlers.requestLocation.postMessage(...)` directly, and every frame
    /// in the page can reach the handler. Constraining the id to a hex/dash alphabet means
    /// no caller-controlled character can survive into the JavaScript the coordinator builds.
    private static func isShimGeneratedRequestId(_ requestId: String) -> Bool {
        let groups = requestId.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
              groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    /// Escapes a value for embedding in a single-quoted JavaScript string literal.
    ///
    /// Belt-and-braces behind `isShimGeneratedRequestId`: the backslash must be escaped
    /// first, otherwise a trailing backslash would escape the closing quote instead of
    /// itself. (The previous implementation escaped only the quote, and only for the
    /// reject message — not for the request id.)
    private static func jsStringLiteralEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
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
