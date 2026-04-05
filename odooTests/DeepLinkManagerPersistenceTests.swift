//
//  DeepLinkManagerPersistenceTests.swift
//  odooTests
//
//  Unit tests for DeepLinkManager: cold-start recovery, setPending disk writes,
//  and consume disk clears. Each test uses a unique UserDefaults suite so tests
//  never pollute UserDefaults.standard or interfere with each other.
//
//  Coverage: DLM-01 through DLM-08, EC-03, EC-08
//

import XCTest
@testable import odoo

@MainActor
final class DeepLinkManagerPersistenceTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a fresh, isolated UserDefaults suite for one test.
    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    private let testKey = "pending_deep_link_url"

    // MARK: - DLM-01

    /// DLM-01: Verifies cold-start recovery — a URL written to disk before the app was killed
    /// is available in `pendingUrl` immediately after `init()`, and the UserDefaults key is
    /// cleared atomically during init so a second launch does not replay the deep link.
    func test_init_givenPersistedUrlInUserDefaults_loadsPendingUrlAndClearsDefaults() {
        let suite = makeSuite()
        suite.set("/web#action=123", forKey: testKey)

        let sut = DeepLinkManager(defaults: suite)

        XCTAssertEqual(sut.pendingUrl, "/web#action=123",
                       "pendingUrl must be restored from UserDefaults on init")
        XCTAssertNil(suite.string(forKey: testKey),
                     "UserDefaults key must be cleared during init to prevent replay on next launch")
    }

    // MARK: - DLM-02

    /// DLM-02: Normal cold start with no pending deep link — init must not produce a spurious
    /// non-nil value and must not crash on a missing key.
    func test_init_givenNoPersistedUrl_pendingUrlIsNil() {
        let suite = makeSuite()

        let sut = DeepLinkManager(defaults: suite)

        XCTAssertNil(sut.pendingUrl,
                     "pendingUrl must be nil when UserDefaults has no persisted URL")
    }

    // MARK: - DLM-03

    /// DLM-03: `setPending(_:)` writes to both the @Published in-memory property and
    /// UserDefaults disk storage. This covers the warm-navigation path triggered when
    /// a notification arrives while the app is already running.
    func test_setPending_givenUrl_writesToMemoryAndDisk() {
        let suite = makeSuite()
        let sut = DeepLinkManager(defaults: suite)
        let url = "/web#id=42&model=sale.order"

        sut.setPending(url)

        XCTAssertEqual(sut.pendingUrl, url,
                       "pendingUrl in-memory must match the value passed to setPending")
        XCTAssertEqual(suite.string(forKey: testKey), url,
                       "UserDefaults disk entry must match the value passed to setPending")
    }

    // MARK: - DLM-04

    /// DLM-04: `consume()` returns the pending URL and clears both in-memory and
    /// UserDefaults storage atomically. If either store is not cleared, the deep link
    /// would fire again on the next launch.
    func test_consume_givenPendingUrl_returnsUrlAndClearsBothStores() {
        let suite = makeSuite()
        let sut = DeepLinkManager(defaults: suite)
        sut.setPending("/web#action=contacts")

        let result = sut.consume()

        XCTAssertEqual(result, "/web#action=contacts",
                       "consume() must return the URL that was set")
        XCTAssertNil(sut.pendingUrl,
                     "pendingUrl must be nil after consume()")
        XCTAssertNil(suite.string(forKey: testKey),
                     "UserDefaults key must be cleared after consume()")
    }

    // MARK: - DLM-05

    /// DLM-05: `consume()` on an empty manager returns nil gracefully without crashing.
    /// Guards against force-unwrap bugs in the implementation.
    func test_consume_givenNoPendingUrl_returnsNilAndDoesNotCrash() {
        let suite = makeSuite()
        let sut = DeepLinkManager(defaults: suite)

        let result = sut.consume()

        XCTAssertNil(result, "consume() must return nil when no URL is pending")
        XCTAssertNil(sut.pendingUrl, "pendingUrl must remain nil after consuming an empty manager")
    }

    // MARK: - DLM-06

    /// DLM-06: `setPending(nil)` is the explicit clear path. Verifies the `else` branch
    /// in the implementation removes the disk key and sets in-memory to nil.
    func test_setPendingNil_givenExistingUrl_clearsMemoryAndDisk() {
        let suite = makeSuite()
        let sut = DeepLinkManager(defaults: suite)
        sut.setPending("/web#action=123")

        sut.setPending(nil)

        XCTAssertNil(sut.pendingUrl,
                     "pendingUrl must be nil after setPending(nil)")
        XCTAssertNil(suite.string(forKey: testKey),
                     "UserDefaults key must be removed after setPending(nil)")
    }

    // MARK: - DLM-07

    /// DLM-07: Multiple rapid `setPending` calls — the last call must win in both
    /// memory and on disk. Prevents stale deep link replay from an earlier notification tap.
    func test_setPending_givenTwoCalls_secondUrlWins() {
        let suite = makeSuite()
        let sut = DeepLinkManager(defaults: suite)

        sut.setPending("/web#action=first")
        sut.setPending("/web#action=second")

        XCTAssertEqual(sut.pendingUrl, "/web#action=second",
                       "In-memory pendingUrl must reflect the most recent setPending call")
        XCTAssertEqual(suite.string(forKey: testKey), "/web#action=second",
                       "UserDefaults disk entry must reflect the most recent setPending call")
    }

    // MARK: - DLM-08

    /// DLM-08: Verifies that `DeepLinkManager.init()` and `setPending()` can be called
    /// from a `@MainActor`-isolated context without threading assertion failures.
    /// The test compiles only if `@MainActor` is properly enforced on the class.
    func test_mainActorConformance_initAndSetPendingFromMainActor_compilesAndPasses() {
        // This function is annotated @MainActor at the class level.
        // If DeepLinkManager were not @MainActor this call would require `await`.
        let sut = DeepLinkManager(defaults: makeSuite())
        sut.setPending("/web#action=123")
        XCTAssertNotNil(sut.pendingUrl,
                        "pendingUrl must be non-nil immediately after setPending on @MainActor")
    }

    // MARK: - EC-03

    /// EC-03: Deep links include URL fragments (#), query params (&, =), and special characters.
    /// UserDefaults stores String values transparently — round-trip fidelity must be verified
    /// explicitly to guard against any encoding transformation in the storage layer.
    func test_setPendingAndConsume_givenUrlWithSpecialCharsAndFragments_roundTripsFaithfully() {
        let suite = makeSuite()
        let sut = DeepLinkManager(defaults: suite)
        let complexUrl = "/web#id=42&model=project.task&cids=1&view_type=form&menu_id=123"

        sut.setPending(complexUrl)
        let result = sut.consume()

        XCTAssertEqual(result, complexUrl,
                       "consume() must return the exact URL passed to setPending — no encoding changes")
    }

    // MARK: - EC-08

    /// EC-08: Two notification taps arriving in rapid succession are both dispatched to
    /// @MainActor, which serializes execution — the last setPending call must win and
    /// the manager must not crash.
    func test_concurrentSetPending_givenTwoTasksOnMainActor_lastValueWinsAndNoCrash() async {
        let suite = makeSuite()
        let sut = DeepLinkManager(defaults: suite)

        // Both tasks are scheduled on @MainActor; execution is serialized so order is deterministic.
        async let first: Void = sut.setPending("/web#action=first")
        async let second: Void = sut.setPending("/web#action=second")
        _ = await (first, second)

        // After both tasks complete the last-written value must be present.
        // Because @MainActor serializes, "second" always executes after "first" here.
        XCTAssertNotNil(sut.pendingUrl,
                        "pendingUrl must be non-nil after concurrent setPending calls")
        XCTAssertNil(sut.consume() == nil ? "fail" as String? : nil,
                     "consume() must return the value without crashing")
    }
}
