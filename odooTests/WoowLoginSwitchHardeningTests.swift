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
    private static var scripts: [String: Script] = [:]
    private static var _authLogins: [String] = []
    private static var _destroyed: [String] = []
    private static var heldDeliveries: [() -> Void] = []

    static func reset(_ scripts: [String: Script]) {
        lock.lock(); self.scripts = scripts; _authLogins = []; _destroyed = []; heldDeliveries = []; lock.unlock()
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
        let script = Self.scripts[login] ?? Script(sid: "sid-\(login)")
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
            keychain.deleteSessionId(serverUrl: account.fullServerUrl, username: account.username)
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
        XCTAssertNil(keychain.getSessionId(serverUrl: server, username: "mate"))
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
        XCTAssertEqual(keychain.getSessionId(serverUrl: server, username: "mate"), "sid-b-old",
                       "B's stored session is untouched")
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
        XCTAssertEqual(keychain.getSessionId(serverUrl: server, username: "mate"), "sid-b-old",
                       "B's stored session is untouched")
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
        XCTAssertEqual(keychain.getSessionId(serverUrl: server, username: "tester"), "sid-a-old", "precondition")
        WoowHardeningURLProtocol.reset(["tester": .init(sid: "sid-a-new")])

        let result = await repo.authenticate(serverUrl: server, database: "db", username: "tester", password: "pw-a")

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(keychain.getSessionId(serverUrl: server, username: "tester"), "sid-a-new")
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
}
