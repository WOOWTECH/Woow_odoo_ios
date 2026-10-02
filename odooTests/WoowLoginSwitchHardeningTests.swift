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
    private static var _authRequests: [(login: String, db: String, password: String)] = []
    private static var _destroyed: [String] = []
    private static var heldDeliveries: [() -> Void] = []
    /// `/web/session/get_session_info` answers: session id → (uid, db). Unknown ids are rejected.
    private static var _sessionInfo: [String: (uid: Int, db: String)] = [:]
    private static var _sessionChecks: [String] = []
    static func setSessionInfo(_ info: [String: (uid: Int, db: String)]) { lock.lock(); _sessionInfo = info; lock.unlock() }
    static var sessionChecks: [String] { lock.lock(); defer { lock.unlock() }; return _sessionChecks }

    static func reset(_ scripts: [String: Script]) { reset(sequences: scripts.mapValues { [$0] }) }
    /// One script per authenticate request for that login, in order; the last one repeats.
    static func reset(sequences: [String: [Script]]) {
        lock.lock(); self.scripts = sequences; _authLogins = []; _authRequests = []; _destroyed = []; heldDeliveries = []
        _sessionInfo = [:]; _sessionChecks = []; lock.unlock()
    }
    static var authLogins: [String] { lock.lock(); defer { lock.unlock() }; return _authLogins }
    static var authRequests: [(login: String, db: String, password: String)] {
        lock.lock(); defer { lock.unlock() }; return _authRequests
    }
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
        if url.path == "/web/session/get_session_info" {
            let sid = (request.value(forHTTPHeaderField: "Cookie") ?? "").replacingOccurrences(of: "session_id=", with: "")
            Self.lock.lock(); Self._sessionChecks.append(sid); let info = Self._sessionInfo[sid]; Self.lock.unlock()
            if let info {
                return deliver(headers: [:], body: #"{"jsonrpc":"2.0","id":1,"result":{"uid":\#(info.uid),"db":"\#(info.db)"}}"#)
            }
            return deliver(headers: [:], body: #"{"jsonrpc":"2.0","id":1,"error":{"code":100,"message":"Odoo Session Expired"}}"#)
        }
        let params = (Self.json(request))?["params"] as? [String: Any]
        let login = params?["login"] as? String ?? "", db = params?["db"] as? String ?? ""
        Self.lock.lock()
        Self._authLogins.append(login)
        Self._authRequests.append((login, db, params?["password"] as? String ?? ""))
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

/// No-op WebKit cleaner that can hold the next removal's cleanup step (pi 1001d: lets a test order
/// a login against a logout that is still in progress).
@MainActor
private final class HardeningNoopWebDataCleaner: AccountWebDataCleaning {
    var holdNext = false
    var onHeld: (() -> Void)?
    private var waiter: CheckedContinuation<Void, Never>?
    func release() { waiter?.resume(); waiter = nil }
    func sessionIds(forAccountId id: String, host: String) async -> [String] {
        if holdNext {
            holdNext = false
            onHeld?()
            await withCheckedContinuation { waiter = $0 }
        }
        return []
    }
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
    private var cleaner: HardeningNoopWebDataCleaner!

    override func setUp() async throws {
        try await super.setUp()
        host = "woowh-\(UUID().uuidString.prefix(8).lowercased()).example.com"
        persistence = PersistenceController(inMemory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WoowHardeningURLProtocol.self]
        config.httpCookieStorage = jar
        revoker = HardeningRevokeRecorder()
        let recorder = revoker!
        cleaner = HardeningNoopWebDataCleaner()
        repo = AccountRepository(persistence: persistence, secureStorage: keychain,
                                 apiClient: OdooAPIClient(session: URLSession(configuration: config)),
                                 brand: .woowtech, webDataCleaner: cleaner,
                                 revokeSession: { _, sid in await recorder.record(sid) })
    }

    override func tearDown() async throws {
        WoowHardeningURLProtocol.releaseHeld()
        cleaner?.release()
        for account in repo.getAllAccounts() {
            keychain.deleteSessionId(accountId: account.id)
            keychain.deletePassword(accountId: account.id)
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
        keychain.savePassword(accountId: try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" }).id, password: "pw-b")
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
        keychain.savePassword(accountId: try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" }).id, password: "pw-b")
        keychain.savePassword(accountId: try XCTUnwrap(repo.getAllAccounts().first { $0.username == "third" }).id, password: "pw-c")
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
        keychain.savePassword(accountId: try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" }).id, password: "pw-b")
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

    // MARK: - pi 1001d

    /// P1 (reverse order): the logout of B is in progress when B's login starts; the logout finishes;
    /// then the login's response arrives. B must stay removed; a session the login obtained is revoked.
    func test_logoutInProgress_loginStartsThenAnswersAfterLogout_doesNotResurrect() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a", isActive: true),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b-old", isActive: false),
        ])
        let b = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" })
        let removalHeld = expectation(description: "logout of B is mid-removal")
        cleaner.holdNext = true
        cleaner.onHeld = { removalHeld.fulfill() }
        let logout = Task { await repo.logout(accountId: b.id) }
        await fulfillment(of: [removalHeld], timeout: 5)

        WoowHardeningURLProtocol.reset(["mate": .init(sid: "sid-b-new", hold: true)])
        let login = Task { await repo.authenticate(serverUrl: server, database: "db", username: "mate", password: "pw-b") }
        await waitForAuthRequests(1)          // a fixed login may refuse before any request
        cleaner.release()
        await logout.value
        WoowHardeningURLProtocol.releaseHeld()
        let result = await login.value

        XCTAssertFalse(result.isSuccess, "a login started during B's removal must not commit")
        XCTAssertFalse(repo.getAllAccounts().contains { $0.username == "mate" }, "the removed account stays removed")
        XCTAssertEqual(repo.getActiveAccount()?.username, "tester")
        XCTAssertFalse(jarSessionIds.contains("sid-b-new"))
        if WoowHardeningURLProtocol.authLogins.contains("mate") {
            let ids = await revoked(containing: "sid-b-new")
            XCTAssertTrue(ids.contains("sid-b-new"), "a session obtained by the refused login is revoked")
        }
    }

    /// P2: two databases on one host, same username, different passwords. Switching back to the first
    /// must authenticate with ITS password, not the one saved last for the other database.
    func test_sameHostSameUsername_twoDatabasesDifferentPasswords_switchUsesOwnPassword() async throws {
        WoowHardeningURLProtocol.reset(sequences: ["tester": [.init(sid: "sid-1"), .init(sid: "sid-2"), .init(sid: "sid-1b")]])
        let first = await repo.authenticate(serverUrl: server, database: "db1", username: "tester", password: "pw-1")
        let second = await repo.authenticate(serverUrl: server, database: "db2", username: "tester", password: "pw-2")
        XCTAssertTrue(first.isSuccess); XCTAssertTrue(second.isSuccess)
        let db1 = try XCTUnwrap(repo.getAllAccounts().first { $0.database == "db1" })

        let switched = await repo.switchAccount(id: db1.id)

        XCTAssertTrue(switched)
        let last = try XCTUnwrap(WoowHardeningURLProtocol.authRequests.last)
        XCTAssertEqual(last.db, "db1")
        XCTAssertEqual(last.password, "pw-1", "db1's own password, not db2's")
        XCTAssertEqual(repo.getActiveAccount()?.database, "db1")
    }

    // MARK: - pi 1001e

    /// P1, end to end through the real Keychain: two databases on one host with the same username
    /// had colliding legacy keys; the upgrade drops them (owner unknown). Switching to the other
    /// database then has neither a password nor a session: it must fail closed — the current account
    /// and its jar stay, and the target is routed to sign in again.
    func test_upgrade_ambiguousLegacyKeysDropped_switchFailsClosedAndAsksTargetToSignIn() async throws {
        let store = SecureStorage(service: "odoo.tests.1001e.\(UUID().uuidString)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WoowHardeningURLProtocol.self]
        config.httpCookieStorage = jar
        let api = OdooAPIClient(session: URLSession(configuration: config))
        let recorder = revoker!
        let seeding = AccountRepository(persistence: persistence, secureStorage: store, apiClient: api, brand: .woowtech,
                                        webDataCleaner: cleaner, revokeSession: { _, sid in await recorder.record(sid) })
        seeding.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db1", username: "tester", sessionCookie: "sid-1", isActive: true),
            SeededAccount(serverURL: server, database: "db2", username: "tester", sessionCookie: "sid-2", isActive: false),
        ])
        // Before 1001c/1001d: one colliding legacy password and session for both accounts, no id keys.
        for account in seeding.getAllAccounts() {
            store.deleteSessionId(accountId: account.id); store.deletePassword(accountId: account.id)
        }
        store.saveLegacyCredentialForTesting(serverUrl: server, username: "tester", password: "pw-shared", sessionId: "sid-shared")
        putJarSession("sid-1")
        defer {
            store.deleteLegacyCredentialForTesting(serverUrl: server, username: "tester")
            for account in seeding.getAllAccounts() {
                store.deleteSessionId(accountId: account.id); store.deletePassword(accountId: account.id)
            }
        }

        // Upgrade: a new repository runs the key migrations.
        let upgraded = AccountRepository(persistence: persistence, secureStorage: store, apiClient: api, brand: .woowtech,
                                         webDataCleaner: cleaner, revokeSession: { _, sid in await recorder.record(sid) })
        let legacy = store.legacyCredentialForTesting(serverUrl: server, username: "tester")
        XCTAssertNil(legacy.password, "an ambiguous legacy password is not guessed onto either account")
        XCTAssertNil(legacy.sessionId)
        let db2 = try XCTUnwrap(upgraded.getAllAccounts().first { $0.database == "db2" })
        XCTAssertNil(store.getPassword(accountId: db2.id)); XCTAssertNil(store.getSessionId(accountId: db2.id))
        WoowHardeningURLProtocol.reset([:])

        let switched = await upgraded.switchAccount(id: db2.id)

        XCTAssertFalse(switched, "no session can be obtained for db2 — fail closed")
        XCTAssertEqual(upgraded.getActiveAccount()?.database, "db1", "the current account stays active")
        XCTAssertEqual(jarSessionIds, ["sid-1"], "db2 never borrows db1's jar session")
        XCTAssertEqual(ReloginSignal.shared.lastRequestedAccountId, db2.id, "db2 is routed to sign in again")
        XCTAssertTrue(WoowHardeningURLProtocol.authLogins.isEmpty, "nothing to authenticate with")
    }

    /// P1: a stored session id alone is not an identity — without a password, the server must confirm
    /// it is still this account's (same user and database) before the switch uses it.
    func test_switchWithoutPassword_storedSessionRejected_failsClosed() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a", isActive: true),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b-stale", isActive: false),
        ])
        let b = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" })
        putJarSession("sid-a")
        WoowHardeningURLProtocol.reset([:])          // get_session_info rejects every session

        let switched = await repo.switchAccount(id: b.id)

        XCTAssertFalse(switched)
        XCTAssertEqual(WoowHardeningURLProtocol.sessionChecks, ["sid-b-stale"])
        XCTAssertEqual(repo.getActiveAccount()?.username, "tester")
        XCTAssertEqual(jarSessionIds, ["sid-a"])
        XCTAssertEqual(ReloginSignal.shared.lastRequestedAccountId, b.id)
    }

    func test_switchWithoutPassword_storedSessionConfirmed_switches() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a", isActive: true),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b", isActive: false),
        ])
        let b = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "mate" })
        putJarSession("sid-a")
        WoowHardeningURLProtocol.reset([:])
        WoowHardeningURLProtocol.setSessionInfo(["sid-b": (uid: 1, db: "db")])   // seeded accounts have uid 1

        let switched = await repo.switchAccount(id: b.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(repo.getActiveAccount()?.username, "mate")
        XCTAssertEqual(jarSessionIds, ["sid-b"])
    }

    // MARK: - pi 1001f

    /// A repository over its own real-Keychain service (nothing shared with other tests), seeded with
    /// the active `tester` and the inactive `mate`; `mate`'s row has no recorded user id when
    /// `mateUserIdKnown` is false (a historical row: `userId <= 0` reads as nil).
    private func isolatedRepo(mateUserIdKnown: Bool) throws -> (AccountRepository, SecureStorage, OdooAccount) {
        let store = SecureStorage(service: "odoo.tests.1001f.\(UUID().uuidString)")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WoowHardeningURLProtocol.self]
        config.httpCookieStorage = jar
        let recorder = revoker!
        let isolated = AccountRepository(persistence: persistence, secureStorage: store,
                                         apiClient: OdooAPIClient(session: URLSession(configuration: config)),
                                         brand: .woowtech, webDataCleaner: cleaner,
                                         revokeSession: { _, sid in await recorder.record(sid) })
        isolated.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a", isActive: true),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b-old", isActive: false),
        ])
        let context = persistence.container.viewContext
        let mateEntity = try XCTUnwrap(try context.fetch(OdooAccountEntity.fetchAllRequest()).first { $0.username == "mate" })
        if !mateUserIdKnown { mateEntity.userId = 0 }
        try context.save()
        let mate = try XCTUnwrap(isolated.getAllAccounts().first { $0.username == "mate" })
        XCTAssertEqual(mate.userId, mateUserIdKnown ? 1 : nil, "precondition")
        let ids = isolated.getAllAccounts().map(\.id)
        addTeardownBlock {
            for id in ids { store.deleteSessionId(accountId: id); store.deletePassword(accountId: id) }
        }
        putJarSession("sid-a")
        return (isolated, store, mate)
    }

    /// P1 counterexample: mate's user id is unknown and mate's own Keychain key holds the session of
    /// ANOTHER user (C, uid 7) of the same database. A database match is no proof of identity — the
    /// session must not be adopted; tester and the jar stay, and mate is asked to sign in again.
    func test_switchWithoutPassword_userIdUnknown_otherUsersSessionSameDatabase_notAdopted() async throws {
        let (isolated, store, mate) = try isolatedRepo(mateUserIdKnown: false)
        XCTAssertTrue(store.saveSessionId(accountId: mate.id, sessionId: "sid-c"))
        XCTAssertNil(store.getPassword(accountId: mate.id))
        WoowHardeningURLProtocol.reset([:])
        WoowHardeningURLProtocol.setSessionInfo(["sid-c": (uid: 7, db: "db")])   // user C, same database

        let switched = await isolated.switchAccount(id: mate.id)

        XCTAssertFalse(switched, "an unproven session must not activate the account")
        XCTAssertEqual(isolated.getActiveAccount()?.username, "tester")
        XCTAssertEqual(jarSessionIds, ["sid-a"], "C's session is never published")
        XCTAssertEqual(ReloginSignal.shared.lastRequestedAccountId, mate.id)
        XCTAssertTrue(WoowHardeningURLProtocol.authLogins.isEmpty)
    }

    /// P1: a known user id that differs from the session's user is rejected the same way.
    func test_switchWithoutPassword_knownUserIdDiffersFromSessionUser_notAdopted() async throws {
        let (isolated, store, mate) = try isolatedRepo(mateUserIdKnown: true)
        XCTAssertTrue(store.saveSessionId(accountId: mate.id, sessionId: "sid-c"))
        WoowHardeningURLProtocol.reset([:])
        WoowHardeningURLProtocol.setSessionInfo(["sid-c": (uid: 7, db: "db")])   // mate is uid 1

        let switched = await isolated.switchAccount(id: mate.id)

        XCTAssertFalse(switched)
        XCTAssertEqual(isolated.getActiveAccount()?.username, "tester")
        XCTAssertEqual(jarSessionIds, ["sid-a"])
        XCTAssertEqual(ReloginSignal.shared.lastRequestedAccountId, mate.id)
    }

    /// P1: a sign-in with credentials proves the identity — a switch that authenticates with the
    /// stored password records the server's user id, so mate's own session can be proven later.
    func test_switchWithPassword_userIdUnknown_recordsTheServerUserId() async throws {
        let (isolated, store, mate) = try isolatedRepo(mateUserIdKnown: false)
        XCTAssertTrue(store.savePassword(accountId: mate.id, password: "pw-b"))
        WoowHardeningURLProtocol.reset(["mate": .init(sid: "sid-b-new")])   // authenticate answers uid 9

        let switched = await isolated.switchAccount(id: mate.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(isolated.getActiveAccount()?.username, "mate")
        XCTAssertEqual(isolated.getActiveAccount()?.userId, 9, "the proven user id is persisted")
        XCTAssertEqual(jarSessionIds, ["sid-b-new"])
    }
}

/// Thread-safe call counter for the login-commit test seam.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
