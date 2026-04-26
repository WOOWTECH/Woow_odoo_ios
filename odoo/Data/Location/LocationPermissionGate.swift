import CoreLocation
import Foundation

// MARK: - CLLocationManager abstraction (enables unit testing without real CLLocationManager)

/// Provides the subset of CLLocationManager state that LocationPermissionGate needs.
/// Conforming CLLocationManager directly avoids a heavyweight protocol ceremony —
/// the real type is extended below, and tests inject a stub.
@MainActor
protocol LocationManagerStatusProvider: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
}

@MainActor
extension CLLocationManager: LocationManagerStatusProvider {}

// MARK: - LocationPermissionGate

/// Decides whether a geolocation request from the WebView should be granted, rejected,
/// or deferred to a runtime OS permission prompt.
///
/// Resolution order (per v2 spec):
/// 1. Origin must be HTTPS and its host must match the active account host.
/// 2. The user must not have disabled location in app settings.
/// 3. CLAuthorizationStatus must be `.authorizedWhenInUse` or `.authorizedAlways` (grant),
///    `.notDetermined` (needs runtime prompt), or `.denied`/`.restricted` (reject).
///
/// Reduced accuracy (`accuracyAuthorization == .reducedAccuracy`) is accepted as a grant —
/// coordinates are passed through with a warning log. Full-accuracy promotion is out of scope for v1.
@MainActor
final class LocationPermissionGate {

    /// The outcome of evaluating a location request.
    enum Decision: Equatable {
        /// Allow the request — proceed to CLLocationManager.requestLocation().
        case grant
        /// Block the request — call __woowRejectGeo with the given reason code.
        case reject(reason: String)
        /// Block until the OS prompt resolves, then re-evaluate.
        case needsRuntimePrompt
    }

    private let statusProvider: LocationManagerStatusProvider
    private let settingsProvider: () -> AppSettings

    /// Creates a gate with injectable dependencies for testability.
    ///
    /// - Parameters:
    ///   - statusProvider: Provides the current CLAuthorizationStatus. Defaults to a real CLLocationManager.
    ///   - settingsProvider: Returns the current AppSettings on each call (avoids stale snapshots).
    init(
        statusProvider: LocationManagerStatusProvider? = nil,
        settingsProvider: @escaping () -> AppSettings = { SecureStorage.shared.getSettings() }
    ) {
        // CLLocationManager() must be allocated on the main thread.
        self.statusProvider = statusProvider ?? CLLocationManager()
        self.settingsProvider = settingsProvider
    }

    /// Evaluates whether a geolocation request from the given origin URL should be granted.
    ///
    /// - Parameters:
    ///   - origin: The `window.location.origin` of the requesting frame. Must be non-nil, HTTPS,
    ///             and its host must match `activeAccountHost`.
    ///   - activeAccountHost: The hostname of the currently signed-in Odoo account (e.g. "company.odoo.com").
    /// - Returns: `.grant`, `.reject(reason:)`, or `.needsRuntimePrompt`.
    func resolve(origin: URL?, activeAccountHost: String?) -> Decision {
        // 1. Origin validation
        guard let origin else {
            return .reject(reason: "origin-nil")
        }
        guard origin.scheme?.lowercased() == "https" else {
            return .reject(reason: "origin-not-https")
        }
        guard let originHost = origin.host, !originHost.isEmpty else {
            return .reject(reason: "origin-no-host")
        }
        guard let accountHost = activeAccountHost, !accountHost.isEmpty else {
            return .reject(reason: "no-active-account")
        }
        guard originHost.caseInsensitiveCompare(accountHost) == .orderedSame else {
            return .reject(reason: "origin-host-mismatch")
        }

        // 2. User preference
        let settings = settingsProvider()
        guard settings.locationEnabled else {
            return .reject(reason: "user-opted-out")
        }

        // 3. OS authorization status
        switch statusProvider.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return .grant
        case .notDetermined:
            return .needsRuntimePrompt
        case .denied:
            return .reject(reason: "os-denied")
        case .restricted:
            return .reject(reason: "os-restricted")
        @unknown default:
            return .reject(reason: "os-unknown")
        }
    }
}
