//
//  GeoBridgeTestDoubles.swift
//  odooTests
//
//  EP-06R (run WT-ENG-20260917A) — isolated test doubles for the geolocation bridge.
//
//  ISOLATION CONTRACT (TEST-STANDARD.md §3):
//    * No real GPS      — CLLocationManager is subclassed; requestLocation() and
//                         requestWhenInUseAuthorization() are overridden to pure counters,
//                         so no Core Location service is ever started and no OS
//                         permission prompt can be raised.
//    * No network/ERP   — WKWebView is subclassed and evaluateJavaScript is intercepted;
//                         no page is ever loaded, no URL is ever requested.
//    * No secrets       — all hosts/origins below are obviously fictitious test values.
//    * No production change — every double lives in odooTests/; nothing under odoo/ is
//                         modified. `odooTests` is a PBXFileSystemSynchronizedRootGroup,
//                         so new files join the test target with no project.pbxproj edit.
//
//  WHY SUBCLASSES AND NOT unsafeBitCast:
//    LocationCoordinatorTests.swift documents that WKScriptMessage "has no public
//    initialiser" and that unsafeBitCast is forbidden. That is correct about
//    unsafeBitCast but incomplete: WKScriptMessage is declared in WebKit as
//    `@interface WKScriptMessage : NSObject` with no NS_UNAVAILABLE on -init and all
//    properties `readonly`, so an ordinary Swift subclass overriding `body` and
//    `webView` is well-defined and does not rely on memory-layout tricks. The same
//    holds for WKWebView (`: UIView`) and CLLocationManager (`: NSObject`).
//    `frameInfo` is deliberately NOT overridden — the production code never reads it,
//    which is itself finding F2 in EP-06R-ANALYSIS.md.
//

import CoreLocation
import Foundation
import WebKit
@testable import odoo

// MARK: - Spy WKWebView

/// A WKWebView that records every `evaluateJavaScript` call instead of executing it.
///
/// This is the observation point for the bridge's reply channel: production calls
/// `webView.evaluateJavaScript(js) { _, error in … }` in
/// `LocationCoordinator.didUpdateLocations` and `LocationCoordinator.evaluateReject`.
@MainActor
final class GeoBridgeSpyWebView: WKWebView {

    /// Every JavaScript string the coordinator asked this WebView to evaluate, in order.
    private(set) var evaluatedJavaScript: [String] = []

    convenience init() {
        self.init(frame: .zero, configuration: WKWebViewConfiguration())
    }

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: ((Any?, (any Error)?) -> Void)? = nil
    ) {
        evaluatedJavaScript.append(javaScriptString)
        completionHandler?(nil, nil)
    }
}

// MARK: - Fake WKScriptMessage

/// A synthetic `{requestId, origin}` message, as the geolocation shim would post it.
///
/// Mirrors exactly what `geolocation_shim.js` sends:
/// `webkit.messageHandlers.requestLocation.postMessage({ requestId, origin })`.
@MainActor
final class GeoBridgeFakeScriptMessage: WKScriptMessage {

    private let stubBody: Any
    private weak var stubWebView: WKWebView?

    /// Creates a message with an arbitrary body — including bodies a hostile frame
    /// could send (forged origin, malformed requestId, wrong value types).
    init(body: Any, webView: WKWebView?) {
        self.stubBody = body
        self.stubWebView = webView
        super.init()
    }

    /// Convenience for the well-formed shape.
    convenience init(requestId: String, origin: String, webView: WKWebView?) {
        self.init(body: ["requestId": requestId, "origin": origin], webView: webView)
    }

    override var body: Any { stubBody }
    override var webView: WKWebView? { stubWebView }
    override var name: String { "requestLocation" }
}

// MARK: - Fake CLLocationManager

/// A CLLocationManager whose side-effecting entry points are inert counters.
///
/// `requestLocation()` and `requestWhenInUseAuthorization()` are the only two methods
/// `LocationCoordinator` calls; overriding both guarantees the test process never
/// starts location services and never raises an OS permission dialog.
@MainActor
final class GeoBridgeFakeLocationManager: CLLocationManager {

    private(set) var requestLocationCallCount = 0
    private(set) var requestWhenInUseAuthorizationCallCount = 0

    /// Drives the `accuracyAuthorization == .reducedAccuracy` branch in didUpdateLocations.
    var stubbedAccuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy

    override func requestLocation() {
        requestLocationCallCount += 1
    }

    override func requestWhenInUseAuthorization() {
        requestWhenInUseAuthorizationCallCount += 1
    }

    override var accuracyAuthorization: CLAccuracyAuthorization {
        stubbedAccuracyAuthorization
    }
}

// MARK: - Mutable status provider

/// A `LocationManagerStatusProvider` whose status can change mid-test, so revocation
/// and runtime-prompt transitions can be driven deterministically.
@MainActor
final class GeoBridgeMutableStatusProvider: LocationManagerStatusProvider {
    var authorizationStatus: CLAuthorizationStatus
    init(_ status: CLAuthorizationStatus) { self.authorizationStatus = status }
}

// MARK: - Mutable settings box

/// Holds `AppSettings` so a test can flip `locationEnabled` AFTER a request was granted,
/// which is the in-app revocation scenario in T24.
@MainActor
final class GeoBridgeSettingsBox {
    var settings: AppSettings
    init(locationEnabled: Bool) {
        var s = AppSettings()
        s.locationEnabled = locationEnabled
        self.settings = s
    }
    func setLocationEnabled(_ enabled: Bool) {
        settings.locationEnabled = enabled
    }
}

// MARK: - Fixture values

/// Obviously fictitious fixture constants. No real customer host, no real coordinate.
enum GeoBridgeFixture {

    /// The "trusted" active-account host for these tests.
    static let accountHost = "account-a.invalid"
    /// A second account host, used for the account-switch scenarios.
    static let otherAccountHost = "account-b.invalid"

    static let trustedOrigin = "https://account-a.invalid"
    static let hostileOrigin = "https://evil-third-party.invalid"
    /// Same host as the account, different port — the port-confusion probe.
    static let trustedHostOtherPort = "https://account-a.invalid:8443"
    /// `window.location.origin` of a sandboxed iframe is the literal string "null".
    static let opaqueOrigin = "null"
    static let httpOrigin = "http://account-a.invalid"

    /// A well-formed shim-style request id (the shim generates a UUID-shaped string).
    static let validRequestId = "3f7a1c2e-0b44-4e1a-9d3c-5a6b7c8d9e0f"

    /// A request id that closes the JS string literal the coordinator builds and appends
    /// attacker-controlled statements. `__woowPwn` is a sentinel that must never become
    /// an executable call.
    static let injectingRequestId = "x'),__woowPwn();//"

    /// Synthetic coordinates — deliberately not a real place, never a tester's location.
    static func syntheticLocation(
        latitude: CLLocationDegrees = 12.345678,
        longitude: CLLocationDegrees = 65.432109,
        horizontalAccuracy: CLLocationAccuracy = 10
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: 10,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

// MARK: - JS string-literal analysis

enum GeoBridgeJS {

    /// Counts single quotes that are NOT backslash-escaped.
    ///
    /// A correctly built `__woowResolveGeo('<id>', …)` call contains exactly two
    /// (the delimiters of the id literal). A correctly built
    /// `__woowRejectGeo('<id>', <code>, '<message>')` contains exactly four.
    /// More than that means an argument closed its own literal — i.e. the caller can
    /// append arbitrary JavaScript.
    static func unescapedSingleQuoteCount(in javaScript: String) -> Int {
        var count = 0
        var escaped = false
        for character in javaScript {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "'" {
                count += 1
            }
        }
        return count
    }
}
