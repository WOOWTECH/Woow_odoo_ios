//
//  LogoutRevokesAccountWebDataTests.swift
//  odooTests
//
//  demo111 live run 2026-09-29 (D1, privacy): logging out the last account left
//  `WebsiteDataStore/<accountId>/Cookies.binarycookies` holding the same `session_id` the account
//  used while signed in (it survived an app restart), and the server session was never revoked —
//  `removeApporoAccount` only cleared HTTPCookieStorage, Keychain and Core Data.
//
//  Removing or logging out an account must:
//  - best-effort revoke its server session (`POST /web/session/destroy` carrying ONLY that
//    account's session cookie, https only, never touching the shared cookie jar), without letting a
//    dead server hold up local cleanup;
//  - remove THAT account's WebKit data store (cookies, storage, caches) — never a sibling's, even a
//    sibling signed in to the same host;
//  - drop a pending deep link bound to the removed account.
//  Stores left behind by earlier builds (or still in use at logout time) are pruned at launch.
//

import XCTest
import WebKit
@testable import odoo

// MARK: - Test doubles

@MainActor
private final class RecordingWebDataCleaner: AccountWebDataCleaning {
    var storeSessionIds: [String: [String]] = [:]
    private(set) var removed: [(accountId: String, host: String, sessionIds: Set<String>)] = []
    private(set) var pruned: [Set<String>] = []

    func sessionIds(forAccountId id: String, host: String) async -> [String] { storeSessionIds[id] ?? [] }

    func removeWebData(forAccountId id: String, host: String, sessionIds: Set<String>) async {
        removed.append((id, host, sessionIds))
    }

    func pruneOrphanStores(keeping accountIds: Set<String>) async { pruned.append(accountIds) }
}

private actor RevokeRecorder {
    private(set) var calls: [(serverUrl: String, sessionId: String)] = []
    func record(_ serverUrl: String, _ sessionId: String) { calls.append((serverUrl, sessionId)) }
}

/// Captures every request the API client sends and answers with a transport failure, so a
/// "server unreachable" revoke is exercised by default.
private final class DestroyCaptureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var succeed = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if Self.succeed {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"jsonrpc":"2.0","id":1,"result":null}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    override func stopLoading() {}
}

@MainActor
final class LogoutRevokesAccountWebDataTests: XCTestCase {

    private let host = "same-host.example.com"
    private var persistence: PersistenceController!

    override func setUp() async throws {
        try await super.setUp()
        persistence = PersistenceController(inMemory: true)
        DestroyCaptureURLProtocol.requests = []
        DestroyCaptureURLProtocol.succeed = false
    }

    private func makeClient() -> OdooAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DestroyCaptureURLProtocol.self]
        return OdooAPIClient(session: URLSession(configuration: config))
    }

    /// Two accounts on the SAME host (the demo111 shape): A active, B inactive.
    private func makeRepo(brand: AppBrand.Code, cleaner: RecordingWebDataCleaner,
                          revoker: RevokeRecorder) -> AccountRepository {
        let repo = AccountRepository(persistence: persistence, apiClient: makeClient(), brand: brand,
                                     webDataCleaner: cleaner,
                                     revokeSession: { url, sid in await revoker.record(url, sid) })
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: "https://\(host)", database: "db1", username: "tester",
                          sessionCookie: "sess-a", isActive: true),
            SeededAccount(serverURL: "https://\(host)", database: "db1", username: "mate",
                          sessionCookie: "sess-b", isActive: false),
        ])
        return repo
    }

    private func account(_ repo: AccountRepository, _ username: String) throws -> OdooAccount {
        try XCTUnwrap(repo.getAllAccounts().first { $0.username == username })
    }

    private func waitForRevokes(_ revoker: RevokeRecorder, count: Int) async {
        for _ in 0..<300 {
            if await revoker.calls.count >= count { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_logoutActive_revokesAndRemovesOnlyThatAccountsWebData() async throws {
        for brand in [AppBrand.Code.woowtech, .apporo] {
            let cleaner = RecordingWebDataCleaner()
            let revoker = RevokeRecorder()
            let repo = makeRepo(brand: brand, cleaner: cleaner, revoker: revoker)
            let a = try account(repo, "tester")
            let b = try account(repo, "mate")
            cleaner.storeSessionIds = [a.id: ["sess-a-rotated"], b.id: ["sess-b"]]

            await repo.logout(accountId: nil)
            await waitForRevokes(revoker, count: 2)

            XCTAssertEqual(cleaner.removed.map(\.accountId), [a.id], "\(brand): only A's store is removed")
            XCTAssertEqual(cleaner.removed.first?.host, host)
            XCTAssertEqual(cleaner.removed.first?.sessionIds, ["sess-a", "sess-a-rotated"], "\(brand)")
            let revoked = await revoker.calls
            XCTAssertEqual(Set(revoked.map(\.sessionId)), ["sess-a", "sess-a-rotated"],
                           "\(brand): revoke A's Keychain session and the one its WebView rotated to")
            XCTAssertTrue(revoked.allSatisfy { $0.serverUrl == "https://\(host)" }, "\(brand)")
            XCTAssertFalse(revoked.contains { $0.sessionId == "sess-b" }, "\(brand): never revoke sibling B")
            XCTAssertEqual(repo.getAllAccounts().map(\.username), ["mate"], "\(brand)")
        }
    }

    func test_removeInactiveAccount_revokesAndRemovesOnlyThatAccountsWebData() async throws {
        for brand in [AppBrand.Code.woowtech, .apporo] {
            let cleaner = RecordingWebDataCleaner()
            let revoker = RevokeRecorder()
            let repo = makeRepo(brand: brand, cleaner: cleaner, revoker: revoker)
            let b = try account(repo, "mate")

            await repo.removeAccount(id: b.id)
            await waitForRevokes(revoker, count: 1)

            XCTAssertEqual(cleaner.removed.map(\.accountId), [b.id], "\(brand)")
            let revoked = await revoker.calls
            XCTAssertEqual(revoked.map(\.sessionId), ["sess-b"], "\(brand)")
            XCTAssertEqual(repo.getActiveAccount()?.username, "tester", "\(brand): A stays signed in")
        }
    }

    func test_logout_dropsPendingDeepLinkBoundToRemovedAccountOnly() async throws {
        let cleaner = RecordingWebDataCleaner()
        let repo = makeRepo(brand: .apporo, cleaner: cleaner, revoker: RevokeRecorder())
        let a = try account(repo, "tester")
        DeepLinkManager.shared.setPending("/web#action=a", accountId: a.id)

        await repo.logout(accountId: a.id)

        XCTAssertNil(DeepLinkManager.shared.pending, "a link bound to the removed account must not linger")

        let b = try account(repo, "mate")
        DeepLinkManager.shared.setPending("/web#action=b", accountId: b.id)
        DeepLinkManager.shared.drop(boundTo: UUID().uuidString)
        XCTAssertEqual(DeepLinkManager.shared.pending?.url, "/web#action=b", "a sibling's link is kept")
        _ = DeepLinkManager.shared.consume()
    }

    // MARK: - Server revoke (OdooAPIClient)

    func test_destroySession_postsOnlyThatSessionCookie_withoutTouchingSharedJar() async throws {
        DestroyCaptureURLProtocol.succeed = true
        let jarBefore = HTTPCookieStorage.shared.cookies?.count ?? 0

        await makeClient().destroySession(serverUrl: "https://\(host)", sessionId: "sess-a")

        let request = try XCTUnwrap(DestroyCaptureURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://\(host)/web/session/destroy")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session_id=sess-a")
        XCTAssertFalse(request.httpShouldHandleCookies, "must not read or write the shared cookie jar")
        XCTAssertEqual(HTTPCookieStorage.shared.cookies?.count ?? 0, jarBefore)
    }

    func test_destroySession_unreachableServer_returnsWithoutThrowing() async {
        DestroyCaptureURLProtocol.succeed = false
        await makeClient().destroySession(serverUrl: "https://\(host)", sessionId: "sess-a")
        XCTAssertEqual(DestroyCaptureURLProtocol.requests.count, 1)
    }

    func test_destroySession_refusesHttpAndHeaderInjection() async {
        await makeClient().destroySession(serverUrl: "http://\(host)", sessionId: "sess-a")
        await makeClient().destroySession(serverUrl: "https://\(host)", sessionId: "a;b=c")
        await makeClient().destroySession(serverUrl: "https://\(host)", sessionId: "a\r\nX: y")
        await makeClient().destroySession(serverUrl: "https://\(host)", sessionId: "")
        XCTAssertTrue(DestroyCaptureURLProtocol.requests.isEmpty)
    }

    // MARK: - Real WebKit stores (iOS 17+ per-account identifiers)

    /// Like Odoo's real `session_id`: persistent (has an expiry), so it is what lands in
    /// `Cookies.binarycookies` — the residue the live run found.
    private func cookie(_ value: String, host: String, path: String = "/") -> HTTPCookie {
        HTTPCookie(properties: [.name: "session_id", .value: value, .domain: host, .path: path, .secure: "TRUE",
                                .expires: Date().addingTimeInterval(7 * 24 * 3600)])!
    }

    private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { cont in store.httpCookieStore.getAllCookies { cont.resume(returning: $0) } }
    }

    private func setCookie(_ c: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { cont in store.httpCookieStore.setCookie(c) { cont.resume() } }
    }

    func test_realCleaner_removesTargetStoreOnly_andReadsItsSessionIds() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("per-account stores need iOS 17") }
        let a = UUID(), b = UUID()
        // Held for the whole test, as the live WebViews hold their accounts' stores.
        let storeA = WKWebsiteDataStore(forIdentifier: a), storeB = WKWebsiteDataStore(forIdentifier: b)
        defer { withExtendedLifetime((storeA, storeB)) {} }
        await setCookie(cookie("sess-a", host: host), in: storeA)
        await setCookie(cookie("sess-b", host: host), in: storeB)
        let cleaner = AccountWebDataCleaner()

        let ids = await cleaner.sessionIds(forAccountId: a.uuidString, host: host)
        XCTAssertEqual(ids, ["sess-a"])

        await cleaner.removeWebData(forAccountId: a.uuidString, host: host, sessionIds: ["sess-a"])

        let aAfter = await cookies(in: storeA)
        let bAfter = await cookies(in: storeB)
        XCTAssertTrue(aAfter.isEmpty, "A's session cookie must be gone")
        XCTAssertEqual(bAfter.map(\.value), ["sess-b"], "same-host sibling B must be untouched")
        await cleaner.removeWebData(forAccountId: b.uuidString, host: host, sessionIds: ["sess-b"])
    }

    func test_realCleaner_prunesOrphanStoresButKeepsAccountStores() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("per-account stores need iOS 17") }
        let orphan = UUID(), kept = UUID()
        do {
            // The orphan's store is written and then released (its account is gone, no WebView).
            let orphanStore = WKWebsiteDataStore(forIdentifier: orphan)
            await setCookie(cookie("sess-orphan", host: host), in: orphanStore)
        }
        let keptStore = WKWebsiteDataStore(forIdentifier: kept)
        defer { withExtendedLifetime(keptStore) {} }
        await setCookie(cookie("sess-kept", host: host), in: keptStore)
        let cleaner = AccountWebDataCleaner()

        await cleaner.pruneOrphanStores(keeping: [kept.uuidString])

        if #available(iOS 17.0, *) {
            // Deleting the orphan's directory is best-effort (WebKit refuses while a store object
            // is still alive — here the one this test just released); its data is removed either
            // way (asserted below), and an account's store must never be deleted.
            let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
            XCTAssertTrue(remaining.contains(kept), "an account's store must survive pruning")
        }
        let orphanAfter = await cookies(in: WKWebsiteDataStore(forIdentifier: orphan))
        let keptAfter = await cookies(in: keptStore)
        XCTAssertTrue(orphanAfter.isEmpty, "an orphan store (no account) must be emptied/removed")
        XCTAssertEqual(keptAfter.map(\.value), ["sess-kept"])
        await cleaner.removeWebData(forAccountId: kept.uuidString, host: host, sessionIds: [])
    }

    /// Below iOS 17 / non-UUID ids every account shares `.default()`: only the removed account's
    /// own session cookie may be deleted there, never a same-host sibling's.
    func test_realCleaner_sharedDefaultStore_deletesOnlyGivenSessionCookies() async {
        let store = WKWebsiteDataStore.default()
        // Distinct paths so both cookies really coexist (same name+domain+path would overwrite).
        await setCookie(cookie("legacy-a", host: host, path: "/"), in: store)
        await setCookie(cookie("legacy-b", host: host, path: "/web"), in: store)
        let seeded = await cookies(in: store).filter { $0.domain.contains(host) }.map(\.value)
        XCTAssertEqual(Set(seeded), ["legacy-a", "legacy-b"], "precondition: both cookies present")
        let cleaner = AccountWebDataCleaner()

        await cleaner.removeWebData(forAccountId: "not-a-uuid", host: host, sessionIds: ["legacy-a"])

        let values = await cookies(in: store).filter { $0.domain.contains(host) }.map(\.value)
        XCTAssertFalse(values.contains("legacy-a"))
        XCTAssertTrue(values.contains("legacy-b"))
        await cleaner.removeWebData(forAccountId: "not-a-uuid", host: host, sessionIds: ["legacy-b"])
    }

    func test_rootLaunch_prunesOrphanStoresKeepingEveryAccount() async throws {
        let cleaner = RecordingWebDataCleaner()
        let repo = makeRepo(brand: .apporo, cleaner: cleaner, revoker: RevokeRecorder())

        await repo.pruneOrphanWebData()

        XCTAssertEqual(cleaner.pruned, [Set(repo.getAllAccounts().map(\.id))])
    }
}
