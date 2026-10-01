//
//  WoowLoginSwitchHardeningTests.swift
//  odooTests
//
//  pi 1001b review of the WOOW isolated login/switch (PI-REVIEW-0930B-IOS.md):
//  - P1: a WOOW login or switch that succeeded but whose response cookie is no longer usable at
//    commit time (a short-lived cookie that expired while waiting) still activated the account;
//    the jar kept the previous same-host account's session, which the new account's WebView then
//    borrowed. It must keep the previous account unchanged and fail, like Apporo.
//  - P1: WOOW switches had no ordering fence: B's late answer after the user chose C activated B
//    and published B's cookie over C's. A superseded result must change nothing and revoke the
//    session it created but never published.
//  - P2: re-logging into the same WOOW account replaced its stored session without revoking the
//    old one (left valid on the server, untracked). Revoke it after the commit unless another
//    account holds it.
//

import XCTest
@testable import odoo

/// `/web/session/authenticate` replies per login: a session id, an optional `Max-Age`, and an
/// optional hold (released by the test). `/web/session/destroy` is recorded.
private final class WoowHardeningURLProtocol: URLProtocol {
    struct Script { var sid: String; var maxAge: Int? = nil; var hold = false }
    private static let lock = NSLock()
    private static var scripts: [String: [Script]] = [:]
    private static var _authLogins: [String] = []
    private static var _destroyed: [String] = []
    private static var heldDeliveries: [() -> Void] = []

    static func reset(_ scripts: [String: Script]) { reset(sequences: scripts.mapValues { [$0] }) }
    /// One script per authenticate request for that login, in order; the last one repeats.
    static func reset(sequences: [String: [Script]]) {
        lock.lock(); self.scripts = sequences; _authLogins = []; _destroyed = []; heldDeliveries = []; lock.unlock()
    }
    static var authLogins: [String] { lock.lock(); defer { lock.unlock() }; return _authLogins }
    static var destroyed: [String] { lock.lock(); defer { lock.unlock() }; return _destroyed }
    static func releaseHeld() {
        lock.lock(); let pending = heldDeliveries; heldDeliveries = []; lock.unlock()
        pending.forEach { $0() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        if url.path == "/web/session/destroy" {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            Self.lock.lock(); Self._destroyed.append(cookie.replacingOccurrences(of: "session_id=", with: "")); Self.lock.unlock()
            return deliver(headers: [:], body: #"{"jsonrpc":"2.0","id":1,"result":true}"#)
        }
        let params = (Self.json(request))?["params"] as? [String: Any]
        let login = params?["login"] as? String ?? "", db = params?["db"] as? String ?? ""
        Self.lock.lock()
        Self._authLogins.append(login)
        var queue = Self.scripts[login] ?? []
        let script = queue.first ?? Script(sid: "sid-\(login)")
        if queue.count > 1 { queue.removeFirst(); Self.scripts[login] = queue }
        Self.lock.unlock()
        var cookie = "session_id=\(script.sid); Path=/; Secure; HttpOnly"
        if let maxAge = script.maxAge { cookie += "; Max-Age=\(maxAge)" }
        let body = #"{"jsonrpc":"2.0","id":1,"result":{"uid":9,"db":"\#(db)","username":"\#(login)","name":"User"}}"#
        let send = { [self] in self.deliver(headers: ["Set-Cookie": cookie], body: body) }
        if script.hold {
            Self.lock.lock(); Self.heldDeliveries.append(send); Self.lock.unlock()
        } else {
            send()
        }
    }

    private func deliver(headers: [String: String], body: String) {
        var all = headers; all["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: all)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func json(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096); var read = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                read.append(buffer, count: n)
            }
            data = read
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

@MainActor
private final class HardeningNoopWebDataCleaner: AccountWebDataCleaning {
    func sessionIds(forAccountId id: String, host: String) async -> [String] { [] }
    func removeWebData(forAccountId id: String, host: String, sessionIds: Set<String>,
                       otherAccountHosts: [String]) async {}
    func pruneOrphanStores(keeping accountIds: Set<String>) async {}
}

private actor HardeningRevokeRecorder {
    private(set) var sessionIds: [String] = []
    func record(_ sessionId: String) { sessionIds.append(sessionId) }
}

@MainActor
final class WoowLoginSwitchHardeningTests: XCTestCase {

    private var host = ""
    private var server: String { "https://\(host)" }
    private let jar = HTTPCookieStorage.shared
    private let keychain = SecureStorage.shared
    private var persistence: PersistenceController!
    private var repo: AccountRepository!
    private var revoker: HardeningRevokeRecorder!

    override func setUp() async throws {
        try await super.setUp()
        host = "woowh-\(UUID().uuidString.prefix(8).lowercased()).example.com"
        persistence = PersistenceController(inMemory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WoowHardeningURLProtocol.self]
        config.httpCookieStorage = jar
        revoker = HardeningRevokeRecorder()
        let recorder = revoker!
        repo = AccountRepository(persistence: persistence, secureStorage: keychain,
                                 apiClient: OdooAPIClient(session: URLSession(configuration: config)),
                                 brand: .woowtech, webDataCleaner: HardeningNoopWebDataCleaner(),
                                 revokeSession: { _, sid in await recorder.record(sid) })
    }

    override func tearDown() async throws {
        WoowHardeningURLProtocol.releaseHeld()
        for account in repo.getAllAccounts() {
            keychain.deleteSessionId(accountId: account.id)
            keychain.deletePassword(serverUrl: account.fullServerUrl, username: account.username)
        }
        jar.cookies(for: URL(string: server)!)?.forEach { jar.deleteCookie($0) }
        repo = nil
        try await super.tearDown()
    }

    private func putJarSession(_ value: String) {
        jar.setCookie(HTTPCookie(properties: [.name: "session_id", .value: value, .domain: host,
                                              .path: "/", .secure: "TRUE"])!)
    }

    /// The Keychain session copy of the saved account with this username.
    private func storedSession(_ username: String) -> String? {
        repo.getAllAccounts().first { $0.username == username }.flatMap { keychain.getSessionId(accountId: $0.id) }
    }

    private var jarSessionIds: [String] {
        (jar.cookies(for: URL(string: server)!) ?? []).filter { $0.name == "session_id" }.map(\.value)
    }

    private func revoked(waitingFor expected: Int) async -> [String] {
        var ids: [String] = []
        for _ in 0..<150 {
            ids = await revoker.sessionIds
            if ids.count >= expected { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return ids
    }

    /// Yields the main actor until the fake has seen `count` authenticate requests.
    private func waitForAuthRequests(_ count: Int) async {
        for _ in 0..<300 where WoowHardeningURLProtocol.authLogins.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Delivers the held 1-second response cookie, then blocks the main actor — where the commit
    /// runs — until that cookie has expired: the response is parsed while the cookie is valid, and
    /// the commit can only run after it is no longer usable.
    private func releaseAndOutlastShortLivedCookie() {
        WoowHardeningURLProtocol.releaseHeld()
        Thread.sleep(forTimeInterval: 1.6)
    }

    // MARK: - P1: no usable response cookie → previous account unchanged

    func test_login_responseCookieExpiredBeforeCommit_keepsPreviousAccountAndFails() async throws {
        repo.replaceAccountsForTesting([SeededAccount(serverURL: server, database: "db", username: "tester",
                                                      sessionCookie: "sid-a", isActive: true)])
        putJarSession("sid-a")
        WoowHardeningURLProtocol.reset(["mate": .init(sid: "sid-b", maxAge: 1, hold: true)])

        let login = Task { await repo.authenticate(serverUrl: server, database: "db", username: "mate", password: "pw-b") }
        await waitForAuthRequests(1)
        releaseAndOutlastShortLivedCookie()
        let result = await login.value

        XCTAssertFalse(result.isSuccess, "a login whose session can no longer be published must fail")
        XCTAssertEqual(repo.getActiveAccount()?.username, "tester", "the previous account stays active")
        XCTAssertEqual(jarSessionIds, ["sid-a"], "the jar keeps the previous account's session")
        XCTAssertNil(repo.getAllAccounts().first { $0.username == "mate" }, "B was never added")
        let ids = await revoked(waitingFor: 1)
        XCTAssertEqual(ids, ["sid-b"], "the created-but-unpublished session is revoked")
    }

    func test_switch_responseCookieExpiredBeforeCommit_keepsPreviousAccountAndFails() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a", isActive: true),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b-old", isActive: false),
        ])
        let b = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" })
        keychain.savePassword(serverUrl: server, username: "mate", password: "pw-b")
        putJarSession("sid-a")
        WoowHardeningURLProtocol.reset(["mate": .init(sid: "sid-b-new", maxAge: 1, hold: true)])

        let switching = Task { await repo.switchAccount(id: b.id) }
        await waitForAuthRequests(1)
        releaseAndOutlastShortLivedCookie()
        let switched = await switching.value

        XCTAssertFalse(switched)
        XCTAssertEqual(repo.getActiveAccount()?.username, "tester", "the previous account stays active")
        XCTAssertEqual(jarSessionIds, ["sid-a"], "B never borrows A's session through the jar")
        XCTAssertEqual(storedSession("mate"), "sid-b-old", "B's stored session is untouched")
        let ids = await revoked(waitingFor: 1)
        XCTAssertEqual(ids, ["sid-b-new"], "only the unpublished new session is revoked")
    }

    // MARK: - P1: ordering fence for rapid switches

    func test_switch_lateResultAfterNewerSelection_changesNothingAndRevokesItsSession() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a", isActive: true),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b-old", isActive: false),
            SeededAccount(serverURL: server, database: "db", username: "third", sessionCookie: "sid-c-old", isActive: false),
        ])
        let b = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" })
        let c = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "third" })
        keychain.savePassword(serverUrl: server, username: "mate", password: "pw-b")
        keychain.savePassword(serverUrl: server, username: "third", password: "pw-c")
        putJarSession("sid-a")
        WoowHardeningURLProtocol.reset(["mate": .init(sid: "sid-b-new", hold: true),
                                        "third": .init(sid: "sid-c-new")])

        let toB = Task { await repo.switchAccount(id: b.id) }
        await waitForAuthRequests(1)
        let toC = await repo.switchAccount(id: c.id)
        XCTAssertTrue(toC, "the newer selection completes first")
        WoowHardeningURLProtocol.releaseHeld()
        let lateB = await toB.value

        XCTAssertFalse(lateB, "B's late answer must not win over the newer selection")
        XCTAssertEqual(repo.getActiveAccount()?.id, c.id, "C stays active")
        XCTAssertEqual(jarSessionIds, ["sid-c-new"], "C's session stays in the jar")
        XCTAssertEqual(storedSession("mate"), "sid-b-old", "B's stored session is untouched")
        let ids = Set(await revoked(waitingFor: 2))
        XCTAssertTrue(ids.contains("sid-b-new"), "B's unpublished session is revoked")
        XCTAssertTrue(ids.contains("sid-c-old"), "C's replaced session is revoked")
        XCTAssertFalse(ids.contains("sid-b-old"), "B's stored session is never revoked")
        XCTAssertFalse(ids.contains("sid-c-new"))
    }

    // MARK: - P2: same-account re-login revokes the replaced session

    func test_relogin_sameAccount_revokesReplacedSession() async throws {
        repo.replaceAccountsForTesting([SeededAccount(serverURL: server, database: "db", username: "tester",
                                                      sessionCookie: "sid-a-old", isActive: true)])
        XCTAssertEqual(storedSession("tester"), "sid-a-old", "precondition")
        WoowHardeningURLProtocol.reset(["tester": .init(sid: "sid-a-new")])

        let result = await repo.authenticate(serverUrl: server, database: "db", username: "tester", password: "pw-a")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(storedSession("tester"), "sid-a-new")
        XCTAssertEqual(jarSessionIds, ["sid-a-new"])
        let ids = await revoked(waitingFor: 1)
        XCTAssertEqual(ids, ["sid-a-old"], "the replaced session is revoked after the commit")
    }

    func test_relogin_replacedSessionHeldByAnotherAccount_isNotRevoked() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-shared", isActive: true),
            SeededAccount(serverURL: server, database: "db2", username: "other", sessionCookie: "sid-shared", isActive: false),
        ])
        WoowHardeningURLProtocol.reset(["tester": .init(sid: "sid-a-new")])

        let result = await repo.authenticate(serverUrl: server, database: "db", username: "tester", password: "pw-a")

        XCTAssertTrue(result.isSuccess)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let ids = await revoker.sessionIds
        XCTAssertFalse(ids.contains("sid-shared"), "a session another account holds is never revoked")
    }

    // MARK: - pi 1001c

    private func revoked(containing sessionId: String) async -> [String] {
        var ids: [String] = []
        for _ in 0..<200 {
            ids = await revoker.sessionIds
            if ids.contains(sessionId) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return ids
    }

    /// P1: login 1 has committed the account and the jar but not yet its Keychain copy; login 2 to
    /// the same account commits fully; then login 1 resumes. The Keychain copy must still be the live
    /// (jar) session — observed through logout, which revokes the Keychain copy.
    func test_twoSameAccountLogins_keychainCopyFollowsTheLiveSession() async throws {
        repo.replaceAccountsForTesting([SeededAccount(serverURL: server, database: "db", username: "tester",
                                                      sessionCookie: "sid-a0", isActive: true)])
        WoowHardeningURLProtocol.reset(sequences: ["tester": [.init(sid: "sid-a1"), .init(sid: "sid-a2")]])
        let committed = expectation(description: "login 1 committed")
        let gate = DispatchSemaphore(value: 0)
        let calls = CallCounter()
        repo.afterLoginCommitForTesting = {
            guard calls.next() == 1 else { return }
            committed.fulfill()
            if !Thread.isMainThread { _ = gate.wait(timeout: .now() + 10) }
        }

        let login1 = Task { await repo.authenticate(serverUrl: server, database: "db", username: "tester", password: "pw") }
        await fulfillment(of: [committed], timeout: 10)
        let login2 = await repo.authenticate(serverUrl: server, database: "db", username: "tester", password: "pw")
        XCTAssertTrue(login2.isSuccess)
        gate.signal()
        _ = await login1.value
        repo.afterLoginCommitForTesting = nil

        XCTAssertEqual(jarSessionIds, ["sid-a2"], "the later login's session is the live one")
        let account = try XCTUnwrap(repo.getActiveAccount())
        await repo.logout(accountId: account.id)
        let ids = await revoked(containing: "sid-a2")
        XCTAssertTrue(ids.contains("sid-a2"),
                      "logout revokes the live session — the Keychain copy must not be the earlier login's")
    }

    /// P1: a notification tap activating C is a newer selection than a pending switch to B.
    func test_switchHeld_notificationActivatesOther_lateSwitchChangesNothing() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a", isActive: true),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b-old", isActive: false),
            SeededAccount(serverURL: server, database: "db", username: "third", sessionCookie: "sid-c", isActive: false),
        ])
        let b = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" })
        let c = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "third" })
        keychain.savePassword(serverUrl: server, username: "mate", password: "pw-b")
        WoowHardeningURLProtocol.reset(["mate": .init(sid: "sid-b-new", hold: true)])

        let toB = Task { await repo.switchAccount(id: b.id) }
        await waitForAuthRequests(1)
        XCTAssertTrue(repo.activateAccount(id: c.id), "the notification selects C")
        WoowHardeningURLProtocol.releaseHeld()
        let lateB = await toB.value

        XCTAssertFalse(lateB, "B's late answer must not override the notification's selection")
        XCTAssertEqual(repo.getActiveAccount()?.id, c.id)
        XCTAssertFalse(jarSessionIds.contains("sid-b-new"), "B's new session is never published")
        let ids = await revoked(containing: "sid-b-new")
        XCTAssertTrue(ids.contains("sid-b-new"), "B's unpublished session is revoked")
    }

    /// P1: logging B out while B's re-login is in flight — the late login must not bring B back.
    func test_loginHeld_logoutSameAccount_lateLoginDoesNotResurrect() async throws {
        try await assertLateLoginDoesNotResurrect { repo, id in await repo.logout(accountId: id) }
    }

    /// P1: the same for removing B.
    func test_loginHeld_removeSameAccount_lateLoginDoesNotResurrect() async throws {
        try await assertLateLoginDoesNotResurrect { repo, id in await repo.removeAccount(id: id) }
    }

    private func assertLateLoginDoesNotResurrect(
        _ remove: (AccountRepository, String) async -> Void
    ) async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a", isActive: true),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b-old", isActive: false),
        ])
        let b = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" })
        WoowHardeningURLProtocol.reset(["mate": .init(sid: "sid-b-new", hold: true)])

        let login = Task { await repo.authenticate(serverUrl: server, database: "db", username: "mate", password: "pw-b") }
        await waitForAuthRequests(1)
        await remove(repo, b.id)
        WoowHardeningURLProtocol.releaseHeld()
        let result = await login.value

        XCTAssertFalse(result.isSuccess, "a login superseded by removing its account must not commit")
        XCTAssertFalse(repo.getAllAccounts().contains { $0.username == "mate" }, "the removed account stays removed")
        XCTAssertEqual(repo.getActiveAccount()?.username, "tester")
        XCTAssertFalse(jarSessionIds.contains("sid-b-new"))
        let ids = await revoked(containing: "sid-b-new")
        XCTAssertTrue(ids.contains("sid-b-new"), "the unpublished session is revoked")
    }

    /// P1: two databases on one host with the same username are two accounts. Re-logging into one
    /// must neither revoke nor overwrite the other's stored session.
    func test_sameHostSameUsernameOtherDatabase_sessionsStaySeparate() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db1", username: "tester", sessionCookie: "sid-1", isActive: true),
            SeededAccount(serverURL: server, database: "db2", username: "tester", sessionCookie: "sid-2", isActive: false),
        ])
        let other = try XCTUnwrap(repo.getAllAccounts().first { $0.database == "db2" })
        WoowHardeningURLProtocol.reset(["tester": .init(sid: "sid-1n")])

        let result = await repo.authenticate(serverUrl: server, database: "db1", username: "tester", password: "pw-1")
        XCTAssertTrue(result.isSuccess)
        let afterLogin = await revoked(containing: "sid-1")
        XCTAssertTrue(afterLogin.contains("sid-1"), "db1's own replaced session is revoked")
        XCTAssertFalse(afterLogin.contains("sid-2"), "db2's session belongs to another account")

        await repo.logout(accountId: other.id)
        let afterLogout = await revoked(containing: "sid-2")
        XCTAssertTrue(afterLogout.contains("sid-2"), "logging db2 out revokes db2's own session")
        XCTAssertFalse(afterLogout.contains("sid-1n"), "db1's live session is never revoked by db2's logout")
        XCTAssertEqual(repo.getActiveAccount()?.database, "db1")
    }
}

/// Thread-safe call counter for the login-commit test seam.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
