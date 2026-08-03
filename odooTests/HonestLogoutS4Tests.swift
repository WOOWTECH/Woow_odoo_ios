//
//  HonestLogoutS4Tests.swift
//  odooTests
//
//  Story S4 — FCM token lifecycle: HONEST LOGOUT (LEAN / design B). AC9 / T-I2.
//
//  The demo444 incident: "logout" only cleared the session cookie but LEFT the local account row,
//  so a decommissioned tenant lingered in the local DB forever and its dead host poisoned every
//  launch reconcile. Honest logout is the whole fix:
//    (a) call `unregister_device` — the S1 server now HARD-DELETEs the (fcm_token, user_id) row, THEN
//    (b) REMOVE the local account row and clear its stored password + session id (not just the cookie).
//
//  This suite locks that contract in, plus the two properties that make it safe in practice:
//    - Multi-account isolation: logging out ONE account removes only its row + credentials + server
//      registration; the OTHER account keeps its row, its credentials, and its push.
//    - Best-effort remote unregister: if the `unregister_device` call FAILS (dead/unreachable host —
//      exactly the demo444 case), logout STILL completes — the local row + credentials are removed.
//
//  There is deliberately NO pruning counter / state machine here (that was abandoned option-A
//  machinery). Honest row removal is the entire story.
//
//  Hermetic: the REAL AccountRepository over an in-memory Core Data store, with a URLProtocol
//  seam that records (or fails) the outgoing `unregister_device` call — no real DNS, no network.
//  Credentials are asserted via the real SecureStorage.shared (local Keychain) and cleaned up in
//  tearDown. No credential values are ever logged.
//

import XCTest
@testable import odoo

@MainActor
final class HonestLogoutS4Tests: XCTestCase {

    // MARK: - Configurable URLProtocol seam (records requests; can force failure)

    /// Records every outgoing request URL and, in `.fail` mode, fails the request so the
    /// injected `OdooAPIClient` throws — letting us prove logout still completes on unregister
    /// failure (the demo444 dead-host case) without any real DNS.
    private final class LogoutURLProtocol: URLProtocol {
        enum Mode { case succeed, fail }

        static var mode: Mode = .succeed

        /// ⚠️ `startLoading()` is invoked by URLSession on ITS OWN thread, and logout fires
        /// several requests, so a bare static Array here is a data race — the same defect
        /// that made `MockPushTokenRepository` drop appends and get written off as flakiness.
        /// This suite's intermittent failures have the same shape.
        private static let lock = NSLock()
        private static var _recordedURLs: [String] = []

        static var recordedURLs: [String] { lock.withLock { _recordedURLs } }

        static func record(_ url: String) {
            lock.withLock { _recordedURLs.append(url) }
        }

        static func reset() {
            mode = .succeed
            lock.withLock { _recordedURLs = [] }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let url = request.url?.absoluteString {
                LogoutURLProtocol.record(url)
            }

            switch LogoutURLProtocol.mode {
            case .fail:
                // Simulate a dead / unreachable host (demo444): the request throws, callKw rethrows,
                // and AccountRepository.unregisterFcmToken swallows it (best-effort).
                let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
                client?.urlProtocol(self, didFailWithError: error)
            case .succeed:
                let json = #"{"jsonrpc":"2.0","id":"r1","result":true}"#
                let data = Data(json.utf8)
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://localhost")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }

        override func stopLoading() {}
    }

    // MARK: - Fixtures

    // Account A stays logged in (the sibling); account B is the one we log out.
    private let serverA = "https://demo777-odoo.woowtech.io"
    private let serverB = "https://demo888-odoo.woowtech.io"
    private let passwordA = "pw-a"
    private let passwordB = "pw-b"
    private let sessionA = "sess-a"
    private let sessionB = "sess-b"

    private var persistence: PersistenceController!
    private var secureStorage: SecureStorage!
    private var repo: AccountRepository!

    override func setUp() async throws {
        try await super.setUp()
        LogoutURLProtocol.reset()

        persistence = PersistenceController(inMemory: true)
        secureStorage = SecureStorage.shared

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LogoutURLProtocol.self]
        let session = URLSession(configuration: config)
        let apiClient = OdooAPIClient(session: session)

        repo = AccountRepository(
            persistence: persistence,
            secureStorage: secureStorage,
            apiClient: apiClient
        )

        // A stored FCM token is required so the best-effort `unregister_device` actually fires
        // (its guard is `getFcmToken() != nil`).
        secureStorage.saveFcmToken("test-fcm-token-abc123")

        // A = demo777 (inactive sibling), B = demo888 (active — the account under logout).
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: serverA, database: "demo777",
                          username: "admin", sessionCookie: sessionA, tenantId: "demo777", isActive: false),
            SeededAccount(serverURL: serverB, database: "demo888",
                          username: "admin", sessionCookie: sessionB, tenantId: "demo888", isActive: true),
        ])

        // Store passwords for both accounts (replaceAccountsForTesting only seeds session ids).
        secureStorage.savePassword(serverUrl: serverA, username: "admin", password: passwordA)
        secureStorage.savePassword(serverUrl: serverB, username: "admin", password: passwordB)
    }

    override func tearDown() async throws {
        // Clean up the shared Keychain singleton so tests stay independent.
        secureStorage.deletePassword(serverUrl: serverA, username: "admin")
        secureStorage.deletePassword(serverUrl: serverB, username: "admin")
        secureStorage.deleteSessionId(serverUrl: serverA, username: "admin")
        secureStorage.deleteSessionId(serverUrl: serverB, username: "admin")
        secureStorage.deleteFcmToken()
        LogoutURLProtocol.reset()
        repo = nil
        secureStorage = nil
        persistence = nil
        try await super.tearDown()
    }

    // MARK: - AC9 — honest logout removes the row AND clears credentials AND fires unregister

    /// The core AC9 contract in one test: logging out account B must
    ///   (a) fire a remote `unregister_device` to B's server (→ server hard-delete), AND
    ///   (b) remove B's local account row AND clear B's stored password + session id
    ///       — not merely the cookie.
    func test_honestLogout_firesUnregister_removesRow_andClearsCredentials() async {
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo888", "precondition: B active")
        XCTAssertNotNil(secureStorage.getPassword(serverUrl: serverB, username: "admin"),
                        "precondition: B's password is stored")

        await repo.logout(accountId: nil) // logs out the active account (B)

        // (a) Remote unregister fired against B's server (hard-delete on the server side).
        XCTAssertTrue(
            LogoutURLProtocol.recordedURLs.contains("https://demo888-odoo.woowtech.io/web/dataset/call_kw"),
            "logout must issue a best-effort unregister_device to B's server"
        )

        // (b1) The local account row is GONE — the demo444 fix: no lingering tenant to poison reconcile.
        XCTAssertNil(
            repo.getAllAccounts().first(where: { $0.database == "demo888" }),
            "honest logout must REMOVE the local account row, not merely clear the cookie"
        )

        // (b2) B's stored credentials are cleared.
        XCTAssertNil(secureStorage.getPassword(serverUrl: serverB, username: "admin"),
                     "honest logout must clear B's stored password")
        XCTAssertNil(secureStorage.getSessionId(serverUrl: serverB, username: "admin"),
                     "honest logout must clear B's stored session id")
    }

    // MARK: - AC9 — multi-account isolation: the sibling is untouched

    /// Logging out ONE account removes only its row + credentials + server registration; the OTHER
    /// account (A) keeps its row, is promoted to active, keeps its credentials, and its push is left
    /// alone (no unregister is issued to A's server).
    func test_honestLogout_leavesSiblingRowCredentialsAndPushIntact() async {
        await repo.logout(accountId: nil) // B out

        // A's row survives and is promoted to active (stay-authenticated fallback).
        let active = repo.getActiveAccount()
        XCTAssertEqual(active?.database, "demo777", "the remaining sibling A must be promoted to active")
        XCTAssertEqual(repo.getAllAccounts().count, 1, "only the logged-out account B is removed")

        // A's credentials are intact.
        XCTAssertEqual(secureStorage.getPassword(serverUrl: serverA, username: "admin"), passwordA,
                       "the sibling A's stored password must be untouched")
        XCTAssertEqual(secureStorage.getSessionId(serverUrl: serverA, username: "admin"), sessionA,
                       "the sibling A's stored session id must be untouched")

        // A's push registration is left alone — unregister was scoped to B only.
        XCTAssertFalse(
            LogoutURLProtocol.recordedURLs.contains("https://demo777-odoo.woowtech.io/web/dataset/call_kw"),
            "logging out B must NOT unregister the sibling A's push"
        )
    }

    // MARK: - AC9 — best-effort: unregister failure still completes honest logout

    /// The demo444 case: the account's host is dead, so `unregister_device` throws. Honest logout
    /// must STILL complete — the local row + credentials are removed regardless — so the dead tenant
    /// cannot linger and poison future reconciles.
    func test_honestLogout_whenUnregisterFails_stillRemovesRowAndClearsCredentials() async {
        LogoutURLProtocol.mode = .fail

        await repo.logout(accountId: nil) // B out — unregister will throw

        // The unregister was attempted (best-effort) even though it failed.
        XCTAssertTrue(
            LogoutURLProtocol.recordedURLs.contains("https://demo888-odoo.woowtech.io/web/dataset/call_kw"),
            "logout must attempt the unregister even when the host is unreachable"
        )

        // Despite the failure, the local row is removed and credentials cleared — logout is honest.
        XCTAssertNil(
            repo.getAllAccounts().first(where: { $0.database == "demo888" }),
            "a failed remote unregister must NOT block local row removal (best-effort)"
        )
        XCTAssertNil(secureStorage.getPassword(serverUrl: serverB, username: "admin"),
                     "credentials must be cleared even when unregister fails")

        // And the app stays authenticated on the surviving sibling.
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo777",
                       "logout still promotes the remaining account after a failed unregister")
    }

    // Note: last-account draining (all rows removed → no active account → login screen) plus the
    // shared-FCM-token clear-on-empty branch are already covered by MultiAccountLogoutTests and
    // ConfigViewModelLogoutTests, so they are intentionally NOT duplicated here.
}
