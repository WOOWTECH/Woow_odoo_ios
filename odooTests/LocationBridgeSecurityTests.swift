//
//  LocationBridgeSecurityTests.swift
//  odooTests
//
//  EP-06R (run WT-ENG-20260917A) — isolated reproduction of the iOS geolocation
//  bridge security/reliability questions raised in
//  research/odoo-app-release-20260917/preparation/minimal-remediation.md §6.
//
//  MAPPING TO TEST-CASES.csv
//    T22  MAIN     / HARD-ENG      / LOCAL-BRIDGE — happy path, one-in-one-out
//    T23  NEGATIVE / HARD-RELEASE  / LOCAL-BRIDGE — forged origin, requestId sentinel,
//                                                   non-HTTPS / port / opaque origin,
//                                                   duplicate id across frames
//    T24  NEGATIVE / HARD-RELEASE  / LOCAL-BRIDGE — revocation and switch/navigation races
//
//  SCOPE AND HONESTY BOUNDARY
//    These are PURE MOCK tests. They drive `LocationCoordinator.handleMessage` with a
//    synthetic WKScriptMessage and observe the JS the coordinator asks the WebView to
//    evaluate. They prove what the NATIVE side does with a message.
//
//    They do NOT prove the end-to-end wiring: whether a real cross-origin iframe can
//    actually reach `webkit.messageHandlers.requestLocation`, and whether the reply JS
//    really lands in the MAIN frame's page world. Those require a real WKWebView plus a
//    local HTTPS fixture and are recorded as BLOCKED (needs heavy-build slot) in
//    EP-06R-EVIDENCE.md. Per TEST-STANDARD.md §3.5 a pure-gate/pure-mock PASS must not
//    be reported as a bridge-wiring PASS.
//
//  THIS IS AN R TICKET
//    Tests marked "EXPECTED RED" encode the SECURE expectation and are expected to FAIL
//    against the current implementation. That failure is the reproduction evidence; it
//    is NOT permission to change production code. Fixes belong to EP-06F and need
//    separate per-item approval. Do not "fix" these by relaxing the assertion.
//

import CoreLocation
import XCTest
import WebKit
@testable import odoo

@MainActor
final class LocationBridgeSecurityTests: XCTestCase {

    // MARK: - World builder (every test owns its own; no shared state)

    private struct World {
        let coordinator: LocationCoordinator
        let locationManager: GeoBridgeFakeLocationManager
        let statusProvider: GeoBridgeMutableStatusProvider
        let settings: GeoBridgeSettingsBox
        let webView: GeoBridgeSpyWebView
        let setActiveHost: (String?) -> Void
    }

    private final class HostBox {
        var host: String?
        init(_ host: String?) { self.host = host }
    }

    private func makeWorld(
        status: CLAuthorizationStatus = .authorizedWhenInUse,
        locationEnabled: Bool = true,
        activeHost: String? = GeoBridgeFixture.accountHost
    ) -> World {
        let statusProvider = GeoBridgeMutableStatusProvider(status)
        let settingsBox = GeoBridgeSettingsBox(locationEnabled: locationEnabled)
        let gate = LocationPermissionGate(
            statusProvider: statusProvider,
            settingsProvider: { settingsBox.settings }
        )
        let hostBox = HostBox(activeHost)
        let manager = GeoBridgeFakeLocationManager()
        let coordinator = LocationCoordinator(
            gate: gate,
            activeAccountHost: { hostBox.host },
            locationManager: manager,
            requestingOrigin: GeoBridgeFakeScriptMessage.trustedFrameOrigin
        )
        return World(
            coordinator: coordinator,
            locationManager: manager,
            statusProvider: statusProvider,
            settings: settingsBox,
            webView: GeoBridgeSpyWebView(),
            setActiveHost: { hostBox.host = $0 }
        )
    }

    /// Delivers one synthetic fix through the CLLocationManagerDelegate entry point the
    /// coordinator implements. No Core Location service is involved.
    private func deliverLocation(
        _ world: World,
        location: CLLocation = GeoBridgeFixture.syntheticLocation()
    ) {
        world.coordinator.locationManager(world.locationManager, didUpdateLocations: [location])
    }

    // MARK: - T22 · happy path (one in, one out)

    /// T22-a — a well-formed request from the active account's own HTTPS origin must
    /// cause exactly one location fix request and exactly one resolve callback.
    ///
    /// EXPECTED GREEN against current code — this is the regression guard that any
    /// EP-06F hardening must not break (attendance clock-in must keep working).
    func test_handleMessage_givenTrustedOriginAndAuthorized_returnsSingleResolveCallback() {
        let world = makeWorld()

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )

        XCTAssertEqual(world.locationManager.requestLocationCallCount, 1,
                       "A granted request must ask Core Location for exactly one fix")
        XCTAssertTrue(world.webView.evaluatedJavaScript.isEmpty,
                      "Nothing may be delivered to the page before a fix arrives")

        deliverLocation(world)

        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1,
                       "Exactly one reply must reach the page")
        let js = try? XCTUnwrap(world.webView.evaluatedJavaScript.first)
        XCTAssertTrue(js?.hasPrefix("__woowResolveGeo('\(GeoBridgeFixture.validRequestId)'") == true,
                      "Reply must resolve the originating requestId. Got: \(js ?? "<none>")")
    }

    /// T22-b — a second fix for an already-resolved request must not produce a second
    /// callback. Exactly-once delivery.
    ///
    /// EXPECTED GREEN — `didUpdateLocations` drains and clears `pendingRequests`.
    func test_didUpdateLocations_givenSecondFixAfterResolve_returnsNoAdditionalCallback() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        deliverLocation(world)
        deliverLocation(world)

        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1,
                       "A pending request must be answered exactly once")
    }

    /// T22-c — an OS-denied request must reject exactly once, must not request a fix,
    /// and must post the permanent-deny notification exactly once.
    ///
    /// EXPECTED GREEN.
    func test_handleMessage_givenOSDenied_returnsSingleRejectAndOneNotification() {
        let world = makeWorld(status: .denied)

        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .locationPermanentlyDenied, object: nil, queue: .main
        ) { _ in notificationCount += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )

        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0,
                       "A denied request must never reach Core Location")
        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1,
                       "A denied request must be rejected exactly once")
        XCTAssertTrue(world.webView.evaluatedJavaScript.first?.hasPrefix("__woowRejectGeo(") == true)
        XCTAssertEqual(notificationCount, 1,
                       "locationPermanentlyDenied must be posted exactly once")
    }

    // MARK: - T23 · origin trust

    /// T23-a — finding F2 (was EXPECTED RED; fixed in EP-06F F2).
    ///
    /// Scenario, stated explicitly: the frame that posts the message is REALLY
    /// `evil-third-party.invalid` (that is what WebKit attests in
    /// `frameInfo.securityOrigin`), but its body CLAIMS the active account's origin.
    /// Before the fix the coordinator read `body["origin"]` and granted.
    ///
    /// Secure expectation: a message whose claimed origin is not corroborated by the
    /// sending frame must obtain ZERO location fixes.
    ///
    /// NOTE ON PROOF STRENGTH: this proves the native side decides on the frame's attested
    /// origin, not the body. Proving what WebKit attests for a real third-party iframe
    /// requires the real-WKWebView fixture (BLOCKED).
    func test_handleMessage_givenForgedOriginInBody_returnsNoLocationFix() {
        let world = makeWorld()

        // A frame that is really evil-third-party.invalid claims to be the account host.
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,       // claimed by the page — forged
                frameOrigin: GeoBridgeFixture.hostileOrigin,  // attested by WebKit — the truth
                webView: world.webView
            )
        )

        XCTAssertEqual(
            world.locationManager.requestLocationCallCount, 0,
            """
            EP-06R F2: the bridge must derive the requesting origin from \
            WKScriptMessage.frameInfo.securityOrigin, not from the JS-supplied body. \
            A fix was requested for an unverified origin.
            """
        )
    }

    /// T23-a2 — EP-06F F2. When WebKit cannot attest the sending frame's origin, the
    /// request must be refused even if the body claims the account's origin: an absent
    /// attestation is never replaced by the page's claim.
    func test_handleMessage_givenUnavailableFrameOrigin_returnsRejectWithoutFix() {
        let world = makeWorld()

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,   // claimed by the page
                frameOrigin: nil,                         // WebKit attests nothing
                webView: world.webView
            )
        )

        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0,
                       "No attested frame origin must mean no location fix")
        XCTAssertEqual(world.locationManager.requestWhenInUseAuthorizationCallCount, 0,
                       "An unattested frame must not be able to raise the OS prompt")
        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1,
                       "The refused request must still be answered exactly once")
        XCTAssertTrue(world.webView.evaluatedJavaScript.first?.contains("origin-nil") == true,
                      "Got: \(world.webView.evaluatedJavaScript)")
    }

    /// T23-a3 — EP-06F F2. The body's claim may veto but never grant: a frame WebKit
    /// attests as the account origin, whose body claims some other origin, is refused.
    func test_handleMessage_givenClaimDisagreeingWithTrustedFrame_returnsRejectWithoutFix() {
        let world = makeWorld()

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.hostileOrigin,       // claimed by the page
                frameOrigin: GeoBridgeFixture.trustedOrigin,  // attested by WebKit
                webView: world.webView
            )
        )

        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0)
        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1)
        XCTAssertTrue(
            world.webView.evaluatedJavaScript.first?.contains("origin-claim-mismatch") == true,
            "Got: \(world.webView.evaluatedJavaScript)"
        )
    }

    /// T23-a4 — EP-06F F2 regression guard. A same-origin sub-frame (an iframe the Odoo
    /// page itself serves) is as trustworthy as the page: only scheme/host/port matter,
    /// not whether the sender is the main frame. The attested origin here spells out the
    /// default port, and the body omits it — still the same origin, still granted.
    func test_handleMessage_givenSameOriginSubFrame_returnsLocationFix() {
        let world = makeWorld()

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: "https://account-a.invalid:443",
                webView: world.webView
            )
        )

        XCTAssertEqual(world.locationManager.requestLocationCallCount, 1,
                       "A same-origin frame must keep working (attendance clock-in)")
        deliverLocation(world)
        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1)
        XCTAssertTrue(
            world.webView.evaluatedJavaScript.first?.hasPrefix("__woowResolveGeo('\(GeoBridgeFixture.validRequestId)'") == true,
            "Got: \(world.webView.evaluatedJavaScript)"
        )
    }

    /// T23-b — a genuinely hostile origin value must be rejected. EXPECTED GREEN
    /// (the gate does compare hosts, so an *honest* attacker is blocked; only a
    /// *lying* one gets through — which is exactly why T23-a matters).
    func test_handleMessage_givenUntrustedOriginHost_returnsRejectWithoutFix() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.hostileOrigin,
                frameOrigin: GeoBridgeFixture.hostileOrigin,
                webView: world.webView
            )
        )
        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0)
        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1)
        XCTAssertTrue(
            world.webView.evaluatedJavaScript.first?.contains("origin-host-mismatch") == true
        )
    }

    /// T23-c — non-HTTPS origin must be rejected. EXPECTED GREEN.
    func test_handleMessage_givenHttpOrigin_returnsRejectWithoutFix() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.httpOrigin,
                frameOrigin: GeoBridgeFixture.httpOrigin,
                webView: world.webView
            )
        )
        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0)
        XCTAssertTrue(
            world.webView.evaluatedJavaScript.first?.contains("origin-not-https") == true
        )
    }

    /// T23-d — an opaque origin (sandboxed iframe reports the literal "null") must be
    /// rejected. EXPECTED GREEN — `URL(string: "null")` has no https scheme.
    func test_handleMessage_givenOpaqueOrigin_returnsRejectWithoutFix() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.opaqueOrigin,
                frameOrigin: GeoBridgeFixture.opaqueOrigin,
                webView: world.webView
            )
        )
        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0,
                       "An opaque origin must never obtain a location")
    }

    /// T23-e — **EXPECTED RED** (finding F3).
    ///
    /// The gate compares only `origin.host` against the account host; `origin.port` is
    /// never compared, and `activeAccountHost` is built with `URL(…)?.host` so it carries
    /// no port either. A different origin (different port is a different web origin) is
    /// therefore treated as the same origin.
    func test_handleMessage_givenSameHostDifferentPort_returnsNoLocationFix() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedHostOtherPort,
                frameOrigin: GeoBridgeFixture.trustedHostOtherPort,
                webView: world.webView
            )
        )
        XCTAssertEqual(
            world.locationManager.requestLocationCallCount, 0,
            """
            EP-06R F3: https://host:8443 is a different web origin from https://host. \
            LocationPermissionGate compares host only, so a different port is accepted.
            """
        )
    }

    // MARK: - T23 · requestId injection

    /// T23-f — **EXPECTED RED** (finding F1, resolve path).
    ///
    /// `LocationCoordinator.didUpdateLocations` builds
    /// `"__woowResolveGeo('\(requestId)', …)"` with no validation and no escaping of
    /// `requestId`, then evaluates it. A requestId containing a single quote closes the
    /// literal and appends attacker statements.
    ///
    /// Secure expectation (minimal-remediation §6: "另限requestId格式"): a malformed
    /// requestId is refused outright — no fix, no JS.
    func test_handleMessage_givenInjectingRequestId_returnsNoLocationFixOnResolvePath() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.injectingRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        XCTAssertEqual(
            world.locationManager.requestLocationCallCount, 0,
            "EP-06R F1: a requestId that is not shim-generated UUID-shaped must be refused"
        )
    }

    /// T23-g — **EXPECTED RED** (finding F1, structural proof on the resolve path).
    ///
    /// Independent of whether the id is refused, any JS the bridge does emit must keep
    /// the id inside a single, properly-terminated string literal. Exactly two unescaped
    /// single quotes are expected in a `__woowResolveGeo('<id>', n, n, n)` call.
    func test_didUpdateLocations_givenInjectingRequestId_returnsEscapedJavaScriptLiteral() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.injectingRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        deliverLocation(world)

        guard let js = world.webView.evaluatedJavaScript.first else {
            // Refusing to emit anything is the stronger secure outcome — accept it.
            return
        }
        XCTAssertEqual(
            GeoBridgeJS.unescapedSingleQuoteCount(in: js), 2,
            """
            EP-06R F1: requestId escaped the JS string literal on the RESOLVE path. \
            Emitted: \(js)
            """
        )
    }

    /// T23-h — **EXPECTED RED** (finding F1, reject path — the ungated one).
    ///
    /// This is the more severe half: the reject path runs for requests the gate
    /// REFUSED, so no permission of any kind is needed to reach it.
    /// `evaluateReject` escapes `message` but not `requestId`.
    func test_handleMessage_givenInjectingRequestIdOnRejectedOrigin_returnsEscapedJavaScriptLiteral() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.injectingRequestId,
                origin: GeoBridgeFixture.hostileOrigin,   // gate will reject
                frameOrigin: GeoBridgeFixture.hostileOrigin,
                webView: world.webView
            )
        )

        guard let js = world.webView.evaluatedJavaScript.first else {
            return  // emitting nothing is acceptable
        }
        XCTAssertEqual(
            GeoBridgeJS.unescapedSingleQuoteCount(in: js), 4,
            """
            EP-06R F1: requestId escaped the JS string literal on the REJECT path, which \
            requires no permission at all. Emitted: \(js)
            """
        )
    }

    // MARK: - T23 · duplicate requestId

    /// T23-i — **EXPECTED RED** (finding F5).
    ///
    /// `pendingRequests` is a dictionary keyed by requestId alone. Two frames of the same
    /// page share one WKWebView, so a frame that reuses another frame's id silently
    /// replaces its entry and only one reply is produced.
    ///
    /// Secure expectation: two distinct requests produce two distinct replies.
    func test_handleMessage_givenDuplicateRequestIdFromTwoFrames_returnsTwoIndependentReplies() {
        let world = makeWorld()
        let sharedId = GeoBridgeFixture.validRequestId

        // Frame 1 (the legitimate Odoo page) asks for a position.
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: sharedId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        // Frame 2 (an embedded frame in the same WebView) reuses the same id.
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: sharedId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )

        deliverLocation(world)

        XCTAssertEqual(
            world.webView.evaluatedJavaScript.count, 2,
            """
            EP-06R F5: two in-flight requests collapsed into one because pendingRequests \
            is keyed by the caller-supplied requestId with no frame identity.
            """
        )
    }

    // MARK: - T24 · revocation after grant

    /// T24-a — **EXPECTED RED** (finding F4a).
    ///
    /// The user grants, then turns the in-app location switch OFF while the fix is in
    /// flight. `didUpdateLocations` delivers to every pending request without re-running
    /// the gate, so the position is handed to the page after consent was withdrawn.
    func test_didUpdateLocations_givenAppLocationDisabledAfterGrant_returnsNoDelivery() {
        let world = makeWorld(locationEnabled: true)

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        XCTAssertEqual(world.locationManager.requestLocationCallCount, 1)

        // User revokes consent in the app while the fix is in flight.
        world.settings.setLocationEnabled(false)

        deliverLocation(world)

        let delivered = world.webView.evaluatedJavaScript.filter { $0.hasPrefix("__woowResolveGeo(") }
        XCTAssertTrue(
            delivered.isEmpty,
            """
            EP-06R F4a: consent was withdrawn before the fix arrived, but the position was \
            still delivered. The gate is never re-evaluated at delivery time. Emitted: \(delivered)
            """
        )
    }

    /// T24-b — **EXPECTED RED** (finding F4b).
    ///
    /// The OS permission is revoked (status flips to .denied) after the grant. Same
    /// missing re-validation at delivery.
    func test_didUpdateLocations_givenOSPermissionRevokedAfterGrant_returnsNoDelivery() {
        let world = makeWorld(status: .authorizedWhenInUse)

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        world.statusProvider.authorizationStatus = .denied

        deliverLocation(world)

        let delivered = world.webView.evaluatedJavaScript.filter { $0.hasPrefix("__woowResolveGeo(") }
        XCTAssertTrue(
            delivered.isEmpty,
            "EP-06R F4b: position delivered after the OS authorisation was revoked. Emitted: \(delivered)"
        )
    }

    /// T24-c — **EXPECTED RED** (finding F4c).
    ///
    /// Account A's page issues a request; the active account switches to B before the fix
    /// arrives. The coordinator is shared across accounts (`OdooWebView` holds it as a
    /// `lazy var`) and the pending entry is not invalidated, so A's position is still
    /// delivered into whatever document that WebView now holds.
    ///
    /// SCOPE NOTE: in production, an account switch rebuilds the child WKWebView
    /// (`OdooWebView.rebuildWebView`), so the pending `weak var webView` will usually be
    /// nil by then and the delivery is dropped by accident, not by design. The reachable
    /// case is a same-WebView navigation/reload (self-heal re-login, deep link) — which
    /// this test models by keeping the same WebView alive. See EP-06R-ANALYSIS.md F4c.
    func test_didUpdateLocations_givenAccountSwitchedAfterGrant_returnsNoDeliveryToNewPage() {
        let world = makeWorld(activeHost: GeoBridgeFixture.accountHost)

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )

        // The active account switches; the same WebView is now showing account B.
        world.setActiveHost(GeoBridgeFixture.otherAccountHost)

        deliverLocation(world)

        let delivered = world.webView.evaluatedJavaScript.filter { $0.hasPrefix("__woowResolveGeo(") }
        XCTAssertTrue(
            delivered.isEmpty,
            """
            EP-06R F4c: a position requested by account A was delivered after the active \
            account became B. Pending requests are not bound to the account/document \
            generation they were issued for. Emitted: \(delivered)
            """
        )
    }

    /// T24-c2 — the document generation mechanism, isolated from the gate re-check.
    ///
    /// Everything the gate looks at is left UNCHANGED (same host, same port, same app switch,
    /// same OS status), so a delivery-time gate re-check alone would still grant. The only thing
    /// that changed is that the WebView started loading a different document — the reachable
    /// same-WebView case (self-heal re-login, deep-link navigation, reload) that an account-host
    /// comparison cannot see.
    ///
    /// Also pins T24's "callback exactly once": the superseded request must be ANSWERED once when
    /// the document is replaced — otherwise a clock-in button awaiting `getCurrentPosition` hangs
    /// forever — and must NOT be answered a second time when the fix finally arrives.
    func test_didUpdateLocations_givenDocumentReplacedAfterGrant_returnsSingleRejectAndNoDelivery() {
        let world = makeWorld()

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        XCTAssertEqual(world.locationManager.requestLocationCallCount, 1)

        // The WebView starts loading a new document. Nothing the gate inspects has changed.
        world.coordinator.invalidateActiveDocument()

        XCTAssertEqual(
            world.webView.evaluatedJavaScript.count, 1,
            "The superseded request must be answered once, or the page's callback hangs forever"
        )
        XCTAssertTrue(
            world.webView.evaluatedJavaScript.first?.hasPrefix("__woowRejectGeo(") == true,
            "Replacing the document must answer with a rejection, not a position"
        )

        // The fix arrives after the document was replaced.
        deliverLocation(world)

        XCTAssertEqual(
            world.webView.evaluatedJavaScript.filter { $0.hasPrefix("__woowResolveGeo(") }.count, 0,
            "A position requested by a replaced document must never reach the page that replaced it"
        )
        XCTAssertEqual(
            world.webView.evaluatedJavaScript.count, 1,
            "Callback exactly once: the late fix must not produce a second answer"
        )
    }

    /// T24-d — a request whose WebView has gone away must not crash and must not deliver.
    /// EXPECTED GREEN — `PendingRequest.webView` is weak and delivery guards on it.
    func test_didUpdateLocations_givenWebViewDeallocated_returnsNoDeliveryAndNoCrash() {
        let world = makeWorld()

        autoreleasepool {
            let transientWebView = GeoBridgeSpyWebView()
            world.coordinator.handleMessage(
                GeoBridgeFakeScriptMessage(
                    requestId: GeoBridgeFixture.validRequestId,
                    origin: GeoBridgeFixture.trustedOrigin,
                    frameOrigin: GeoBridgeFixture.trustedOrigin,
                    webView: transientWebView
                )
            )
        }

        deliverLocation(world)

        XCTAssertTrue(world.webView.evaluatedJavaScript.isEmpty,
                      "A dropped WebView must not receive another WebView's reply")
    }

    /// T24-e — an invalid fix (negative horizontal accuracy) must reject, not deliver
    /// a bogus coordinate. EXPECTED GREEN.
    func test_didUpdateLocations_givenNegativeAccuracy_returnsRejectNotPosition() {
        let world = makeWorld()
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        deliverLocation(world, location: GeoBridgeFixture.syntheticLocation(horizontalAccuracy: -1))

        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1)
        XCTAssertTrue(
            world.webView.evaluatedJavaScript.first?.contains("location-invalid-accuracy") == true,
            "An invalid fix must reject rather than deliver coordinates"
        )
    }

    // MARK: - T24 · runtime prompt path

    /// T24-f — a request arriving while the status is `.notDetermined` must ask for
    /// permission once and must not deliver anything until the status resolves.
    /// EXPECTED GREEN.
    func test_handleMessage_givenNotDetermined_returnsRuntimePromptAndNoDelivery() {
        let world = makeWorld(status: .notDetermined)

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )

        XCTAssertEqual(world.locationManager.requestWhenInUseAuthorizationCallCount, 1)
        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0)
        XCTAssertTrue(world.webView.evaluatedJavaScript.isEmpty)
    }

    /// T24-g — when the user denies at the runtime prompt, the deferred request must be
    /// rejected exactly once. EXPECTED GREEN.
    func test_didChangeAuthorization_givenUserDeniedAtPrompt_returnsSingleReject() {
        let world = makeWorld(status: .notDetermined)
        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )

        world.statusProvider.authorizationStatus = .denied
        world.coordinator.locationManagerDidChangeAuthorization(world.locationManager)

        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1)
        XCTAssertTrue(world.webView.evaluatedJavaScript.first?.contains("os-denied") == true)
    }

    /// T24-h — EP-06F F2, deferred path. A frame that is really third-party but claims the
    /// account origin while the OS status is `.notDetermined` must not raise the OS prompt,
    /// and must obtain no fix when the user later authorises. (Before the fix, the forged
    /// body origin was stashed in the pending request and re-resolved to a grant here.)
    func test_didChangeAuthorization_givenForgedOriginWhileNotDetermined_returnsNoFix() {
        let world = makeWorld(status: .notDetermined)

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,       // claimed by the page — forged
                frameOrigin: GeoBridgeFixture.hostileOrigin,  // attested by WebKit
                webView: world.webView
            )
        )

        XCTAssertEqual(world.locationManager.requestWhenInUseAuthorizationCallCount, 0,
                       "A third-party frame must not be able to raise the OS permission prompt")

        // The user authorises location for some other, legitimate reason.
        world.statusProvider.authorizationStatus = .authorizedWhenInUse
        world.coordinator.locationManagerDidChangeAuthorization(world.locationManager)

        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0,
                       "EP-06R F2 (deferred path): a forged origin obtained a fix after authorisation")
        XCTAssertTrue(
            world.webView.evaluatedJavaScript.filter { $0.hasPrefix("__woowResolveGeo(") }.isEmpty
        )
    }

    /// T24-i — EP-06F F2 regression guard, deferred path. A request from the account's own
    /// (attested) origin that waited on the runtime prompt must be re-resolved on that
    /// attested origin and obtain exactly one fix and one resolve once the user authorises.
    func test_didChangeAuthorization_givenTrustedFrameAfterUserAuthorizes_returnsSingleResolve() {
        let world = makeWorld(status: .notDetermined)

        world.coordinator.handleMessage(
            GeoBridgeFakeScriptMessage(
                requestId: GeoBridgeFixture.validRequestId,
                origin: GeoBridgeFixture.trustedOrigin,
                frameOrigin: GeoBridgeFixture.trustedOrigin,
                webView: world.webView
            )
        )
        XCTAssertEqual(world.locationManager.requestWhenInUseAuthorizationCallCount, 1)
        XCTAssertEqual(world.locationManager.requestLocationCallCount, 0)

        world.statusProvider.authorizationStatus = .authorizedWhenInUse
        world.coordinator.locationManagerDidChangeAuthorization(world.locationManager)

        XCTAssertEqual(world.locationManager.requestLocationCallCount, 1,
                       "The deferred request must ask for exactly one fix once authorised")

        deliverLocation(world)

        XCTAssertEqual(world.webView.evaluatedJavaScript.count, 1)
        XCTAssertTrue(
            world.webView.evaluatedJavaScript.first?.hasPrefix("__woowResolveGeo('\(GeoBridgeFixture.validRequestId)'") == true,
            "Got: \(world.webView.evaluatedJavaScript)"
        )
    }

    // MARK: - Default requesting-origin resolver

    /// EP-06F F2 — the production resolver turns WKSecurityOrigin components into the origin
    /// URL the gate checks. WKSecurityOrigin reports port 0 for the scheme default.
    func test_originURL_givenSecurityOriginComponents_returnsNormalizedOrigin() {
        XCTAssertEqual(LocationCoordinator.originURL(scheme: "https", host: "account-a.invalid", port: 0)?.absoluteString,
                       "https://account-a.invalid")
        XCTAssertEqual(LocationCoordinator.originURL(scheme: "https", host: "account-a.invalid", port: 443)?.absoluteString,
                       "https://account-a.invalid",
                       "The default port is not part of the origin string")
        XCTAssertEqual(LocationCoordinator.originURL(scheme: "https", host: "account-a.invalid", port: 8443)?.absoluteString,
                       "https://account-a.invalid:8443",
                       "A non-default port must survive so the gate can reject it")
        XCTAssertEqual(LocationCoordinator.originURL(scheme: "HTTPS", host: "account-a.invalid", port: 0)?.scheme,
                       "https")
        XCTAssertEqual(LocationCoordinator.originURL(scheme: "http", host: "account-a.invalid", port: 80)?.absoluteString,
                       "http://account-a.invalid")
    }

    /// EP-06F F2 — an opaque origin (e.g. a sandboxed iframe) has no scheme/host; the
    /// resolver must report "unavailable" rather than invent an origin.
    func test_originURL_givenOpaqueSecurityOrigin_returnsNil() {
        XCTAssertNil(LocationCoordinator.originURL(scheme: "", host: "", port: 0))
        XCTAssertNil(LocationCoordinator.originURL(scheme: "https", host: "", port: 0))
    }

    // MARK: - Malformed bodies

    /// T23-j — a body missing `requestId` or `origin`, or with wrong value types, must be
    /// dropped silently: no fix, no JS, no crash. EXPECTED GREEN (guard-let early return).
    func test_handleMessage_givenMalformedBody_returnsNoEffect() {
        let bodies: [Any] = [
            ["origin": GeoBridgeFixture.trustedOrigin],                       // no requestId
            ["requestId": GeoBridgeFixture.validRequestId],                   // no origin
            ["requestId": 42, "origin": GeoBridgeFixture.trustedOrigin],      // wrong type
            "not-a-dictionary",
            [] as [Any],
        ]

        for body in bodies {
            let world = makeWorld()
            world.coordinator.handleMessage(
                GeoBridgeFakeScriptMessage(body: body, frameOrigin: GeoBridgeFixture.trustedOrigin,
                                           webView: world.webView)
            )
            XCTAssertEqual(world.locationManager.requestLocationCallCount, 0,
                           "Malformed body must not reach Core Location: \(body)")
            XCTAssertTrue(world.webView.evaluatedJavaScript.isEmpty,
                          "Malformed body must not evaluate JS: \(body)")
        }
    }
}
