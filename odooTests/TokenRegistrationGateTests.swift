import XCTest
@testable import odoo

/// MA-1: the debounce gate that prevents the login + Firebase double-trigger from
/// running the same N register_device calls twice.
final class TokenRegistrationGateTests: XCTestCase {

    /// Two concurrent passes for the SAME token: exactly one body runs; the duplicate
    /// is dropped (dedups the login + Firebase double-trigger).
    func test_run_givenSameTokenConcurrently_executesBodyOnce() async {
        let gate = TokenRegistrationGate()
        let counter = Counter()
        let token = "tok-A"

        async let a = gate.run(token: token) {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 20_000_000) // hold in-flight
        }
        try? await Task.sleep(nanoseconds: 2_000_000)      // ensure a is in-flight
        async let b = gate.run(token: token) { await counter.increment() }

        let ranA = await a
        let ranB = await b

        XCTAssertTrue(ranA, "first pass must run")
        XCTAssertFalse(ranB, "second identical-token pass must be deduplicated")
        let count = await counter.value
        XCTAssertEqual(count, 1, "body must execute exactly once for concurrent same-token passes")
    }

    /// A DIFFERENT token is never deduplicated — a genuine rotation still runs.
    func test_run_givenDifferentTokens_executesBothBodies() async {
        let gate = TokenRegistrationGate()
        let counter = Counter()

        let ran1 = await gate.run(token: "tok-A") { await counter.increment() }
        let ran2 = await gate.run(token: "tok-B") { await counter.increment() }

        XCTAssertTrue(ran1)
        XCTAssertTrue(ran2)
        let count = await counter.value
        XCTAssertEqual(count, 2, "distinct tokens must each register")
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
