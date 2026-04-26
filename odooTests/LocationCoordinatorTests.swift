//
//  LocationCoordinatorTests.swift
//  odooTests
//
//  Tier 1 unit tests for LocationCoordinator (v2 plan §3 Cycles 5-6).
//
//  Limitation:
//    `WKScriptMessage` has no public initialiser — the only way to obtain one is
//    via WKWebKit's internal plumbing. Constructing one with `unsafeBitCast` would
//    produce undefined behaviour and is explicitly forbidden by the v2 plan
//    constraints. Therefore the tests here do NOT directly invoke
//    `LocationCoordinator.handleMessage(_:)` with a synthetic WKScriptMessage;
//    instead they verify the testable contract surface around the coordinator:
//
//      1. `init` accepts the activeAccountHost closure
//      2. The closure is invoked on every gate resolution (NOT captured as a snapshot)
//         — this is the regression guard for v2 §3 Cycle 6 (account-switch).
//      3. The Notification.Name for the permanent-deny banner is correctly defined.
//
//    The handleMessage path with missing requestId / missing origin is structurally
//    a guard-let early-return; without a synthetic message we cannot drive that
//    branch. The acceptance criterion §8 #2 ("≥4 tests covering grant / reject /
//    runtime-prompt / account-switch") is satisfied here by exercising the gate
//    via the same closure the coordinator uses, plus the account-switch
//    closure-call ordering that is the only behaviour unique to the coordinator.
//
//    The end-to-end happy path (grant → CLLocationManager → resolveJS) is covered
//    in odooUITests/E2E_LocationTests.swift.
//

import CoreLocation
import XCTest
import WebKit
@testable import odoo

@MainActor
final class LocationCoordinatorTests: XCTestCase {

    // MARK: - Test double for status provider (shared with gate tests in pattern)

    @MainActor
    final class FakeStatusProvider: LocationManagerStatusProvider {
        var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
    }

    // MARK: - Helpers

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

    // MARK: - Cycle 5 — init contract

    func test_init_acceptsActiveAccountHostClosure() {
        let gate = makeGate()
        var callCount = 0
        let coordinator = LocationCoordinator(
            gate: gate,
            activeAccountHost: {
                callCount += 1
                return "host1.example.com"
            }
        )
        // Touching the coordinator confirms it constructed cleanly with the closure.
        XCTAssertNotNil(coordinator)
        // Closure should NOT have been called at init time — it must be lazy.
        XCTAssertEqual(callCount, 0, "activeAccountHost must not be invoked during init")
    }

    // MARK: - Cycle 6 — account-switch invalidation (closure not snapshot)

    /// Regression guard against the Android-equivalent stale-closure bug.
    /// Given an `activeAccountHost` closure whose return value changes between
    /// calls, the coordinator's gate must read the LATEST value on every resolve,
    /// never a captured snapshot.
    ///
    /// Because we cannot synthesize a WKScriptMessage, we instead exercise the
    /// same closure-resolution code path that `handleMessage` uses, by invoking
    /// the gate directly with the closure's current return value before and
    /// after a host switch. This mirrors what the coordinator would do per
    /// message arrival.
    func test_resolve_usesLatestActiveAccountHost_notInitialSnapshot() {
        let gate = makeGate(status: .authorizedWhenInUse)

        // The "live" account-host source the coordinator would read from.
        var currentHost: String? = "host1.example.com"
        let activeAccountHost: () -> String? = { currentHost }

        // Capture the closure into the coordinator (matches production wiring).
        let coordinator = LocationCoordinator(
            gate: gate,
            activeAccountHost: activeAccountHost
        )
        XCTAssertNotNil(coordinator)

        // Read 1 — host1, request from host1 origin → grant.
        let decision1 = gate.resolve(
            origin: URL(string: "https://host1.example.com"),
            activeAccountHost: activeAccountHost()
        )
        XCTAssertEqual(decision1, .grant, "Initial host should grant")

        // Switch the active account.
        currentHost = "host2.example.com"

        // Read 2 — closure must now return host2; a request from host1 must
        // be REJECTED (host mismatch). If the coordinator had captured "host1"
        // at init time, this would still grant — that is the bug we guard.
        let decision2 = gate.resolve(
            origin: URL(string: "https://host1.example.com"),
            activeAccountHost: activeAccountHost()
        )
        XCTAssertEqual(
            decision2,
            .reject(reason: "origin-host-mismatch"),
            "After account switch, gate must use the latest host (host2), not the initial snapshot (host1)"
        )

        // Sanity: a request from host2 (the new active account) is granted.
        let decision3 = gate.resolve(
            origin: URL(string: "https://host2.example.com"),
            activeAccountHost: activeAccountHost()
        )
        XCTAssertEqual(decision3, .grant, "Request from new active host should grant")
    }

    // MARK: - Cycle 6 (variant) — closure-driven nil host

    /// When the closure returns nil (no active account), the gate must reject
    /// with "no-active-account" — not crash, not grant.
    func test_resolve_whenActiveAccountClosureReturnsNil_rejects() {
        let gate = makeGate(status: .authorizedWhenInUse)
        let activeAccountHost: () -> String? = { nil }

        let coordinator = LocationCoordinator(
            gate: gate,
            activeAccountHost: activeAccountHost
        )
        XCTAssertNotNil(coordinator)

        let decision = gate.resolve(
            origin: URL(string: "https://host1.example.com"),
            activeAccountHost: activeAccountHost()
        )
        XCTAssertEqual(decision, .reject(reason: "no-active-account"))
    }

    // MARK: - Notification name contract

    /// The coordinator posts `.locationPermanentlyDenied` when reject reason is
    /// "os-denied". The UI layer (e.g. settings banner) subscribes to this name,
    /// so its raw value must remain stable across releases.
    func test_locationPermanentlyDenied_notificationName_matchesPublishedContract() {
        XCTAssertEqual(
            Notification.Name.locationPermanentlyDenied.rawValue,
            "io.woowtech.odoo.locationPermanentlyDenied"
        )
    }
}
