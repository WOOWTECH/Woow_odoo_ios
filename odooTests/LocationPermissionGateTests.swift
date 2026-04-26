//
//  LocationPermissionGateTests.swift
//  odooTests
//
//  Tier 1 unit tests for LocationPermissionGate (v2 plan §3 Cycles 1-3).
//
//  Covers:
//    - Cycle 1 (origin/host validation): 3 tests
//    - Cycle 2 (user preference): 1 test
//    - Cycle 3 (CL authorization status): 4 tests
//
//  Total: 8 tests, all expected to pass on the production code in
//  odoo/Data/Location/LocationPermissionGate.swift.
//
//  Reject reason strings are taken verbatim from the production code.
//

import CoreLocation
import XCTest
@testable import odoo

@MainActor
final class LocationPermissionGateTests: XCTestCase {

    // MARK: - Test double

    /// Stub provider — lets us inject any CLAuthorizationStatus without touching the OS.
    /// Conforms to the production protocol so it slots into the gate's init.
    @MainActor
    final class FakeStatusProvider: LocationManagerStatusProvider {
        var authorizationStatus: CLAuthorizationStatus = .notDetermined
    }

    // MARK: - Helpers

    /// Builds a gate wired to a fake status provider and an in-memory AppSettings.
    private func makeGate(
        status: CLAuthorizationStatus = .authorizedWhenInUse,
        locationEnabled: Bool = true
    ) -> LocationPermissionGate {
        let provider = FakeStatusProvider()
        provider.authorizationStatus = status
        var settings = AppSettings()
        settings.locationEnabled = locationEnabled
        return LocationPermissionGate(
            statusProvider: provider,
            settingsProvider: { settings }
        )
    }

    // MARK: - Cycle 1 — origin / host validation

    func test_reject_whenOriginIsHTTP() {
        let gate = makeGate()
        let decision = gate.resolve(
            origin: URL(string: "http://x.com")!,
            activeAccountHost: "x.com"
        )
        XCTAssertEqual(decision, .reject(reason: "origin-not-https"))
    }

    func test_reject_whenOriginIsNil() {
        let gate = makeGate()
        let decision = gate.resolve(
            origin: nil,
            activeAccountHost: "x.com"
        )
        XCTAssertEqual(decision, .reject(reason: "origin-nil"))
    }

    func test_reject_whenOriginHostMismatchesActiveAccount() {
        let gate = makeGate()
        let decision = gate.resolve(
            origin: URL(string: "https://attacker.com")!,
            activeAccountHost: "x.com"
        )
        XCTAssertEqual(decision, .reject(reason: "origin-host-mismatch"))
    }

    // MARK: - Cycle 2 — user preference

    func test_reject_whenLocationDisabled() {
        let gate = makeGate(locationEnabled: false)
        let decision = gate.resolve(
            origin: URL(string: "https://x.com")!,
            activeAccountHost: "x.com"
        )
        XCTAssertEqual(decision, .reject(reason: "user-opted-out"))
    }

    // MARK: - Cycle 3 — OS authorization status

    func test_grant_whenAuthorizedWhenInUse() {
        let gate = makeGate(status: .authorizedWhenInUse)
        let decision = gate.resolve(
            origin: URL(string: "https://x.com")!,
            activeAccountHost: "x.com"
        )
        XCTAssertEqual(decision, .grant)
    }

    func test_grant_whenAuthorizedAlways() {
        let gate = makeGate(status: .authorizedAlways)
        let decision = gate.resolve(
            origin: URL(string: "https://x.com")!,
            activeAccountHost: "x.com"
        )
        XCTAssertEqual(decision, .grant)
    }

    func test_needsRuntimePrompt_whenNotDetermined() {
        let gate = makeGate(status: .notDetermined)
        let decision = gate.resolve(
            origin: URL(string: "https://x.com")!,
            activeAccountHost: "x.com"
        )
        XCTAssertEqual(decision, .needsRuntimePrompt)
    }

    func test_reject_whenDenied() {
        let gate = makeGate(status: .denied)
        let decision = gate.resolve(
            origin: URL(string: "https://x.com")!,
            activeAccountHost: "x.com"
        )
        XCTAssertEqual(decision, .reject(reason: "os-denied"))
    }
}
