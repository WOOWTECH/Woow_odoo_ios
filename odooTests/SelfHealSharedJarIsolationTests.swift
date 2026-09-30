//
//  SelfHealSharedJarIsolationTests.swift
//  odooTests
//
//  pi 0930 (PI-REVIEW-0930-IOS-F1F4, P1): the session-expiry self-heal re-authenticated over the
//  SHARED cookie jar and, when the stored password was rejected, cleared EVERY cookie of the host.
//  With two accounts on one server (demo111) that let:
//  - B's failed heal delete sibling A's session cookie;
//  - A's heal finishing after the user switched to B hand A's fresh session to the jar that now
//    belongs to B (and report success for an account that is no longer on screen).
//
//  These tests run the REAL `OdooAPIClient` re-auth transport (an injected URLProtocol serves the
//  authenticate reply — no DNS) against the REAL `HTTPCookieStorage.shared`, on a host unique to
//  each test. No password or cookie value from a real account is used or logged.
//

import XCTest
@testable import odoo

private final class JarAccountRepo: AccountRepositoryProtocol, @unchecked Sendable {
    var accounts: [OdooAccount] = []
    var activeId: String?

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult { .error("stub", .unknown) }
    func getActiveAccount() -> OdooAccount? { accounts.first { $0.id == activeId } }
    func getAllAccounts() -> [OdooAccount] { accounts }
    func getAccount(byTenantId tenantId: String) -> OdooAccount? { nil }
    func switchAccount(id: String) async -> Bool { activeId = id; return true }
    func activateAccount(id: String) -> Bool { activeId = id; return true }
    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) {}
    func setTenantId(_ tenantId: String, forAccountId accountId: String) {}
    func logout(accountId: String?) async {}
    func removeAccount(id: String) async {}
    func getSessionId(for serverUrl: String) -> String? { nil }
}

private struct SilentRelogin: ReloginSignaling {
    func requestRelogin(accountId: String) {}
}

/// Serves `/web/session/authenticate`: either an Odoo 18 wrong-password envelope, or a success that
/// echoes the requested login/database and sets `session_id=<replySessionId>`. Records whether the
/// request let URLSession handle cookies, and can hold its reply until the test releases it.
/// `/web/session/destroy` is answered at once and the session it carried is recorded.
private final class HealJarURLProtocol: URLProtocol {
    enum Mode { case success, accessDenied }

    private static let lock = NSLock()
    private static var _mode: Mode = .success
    private static var _replySessionId = "healed-sid"
    private static var _handlesCookies: [Bool] = []
    private static var _destroyed: [String] = []
    private static var _held = false
    private static let gate = DispatchSemaphore(value: 0)

    static func reset(mode: Mode, replySessionId: String = "healed-sid", hold: Bool = false) {
        lock.lock(); _mode = mode; _replySessionId = replySessionId; _handlesCookies = []; _destroyed = []; _held = hold; lock.unlock()
    }
    static var handlesCookies: [Bool] { lock.lock(); defer { lock.unlock() }; return _handlesCookies }
    static var destroyedSessions: [String] { lock.lock(); defer { lock.unlock() }; return _destroyed }
    static func release() { gate.signal() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if request.url?.path == "/web/session/destroy" {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            Self.lock.lock(); Self._destroyed.append(cookie.replacingOccurrences(of: "session_id=", with: "")); Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":true}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        Self.lock.lock()
        Self._handlesCookies.append(request.httpShouldHandleCookies)
        let mode = Self._mode, sid = Self._replySessionId, held = Self._held
        Self.lock.unlock()

        let params = (Self.bodyData(of: request)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["params"] as? [String: Any]
        let login = params?["login"] as? String ?? ""
        let db = params?["db"] as? String ?? ""
        let url = request.url!
        let reply: () -> Void = { [weak self] in
            guard let self else { return }
            var headers = ["Content-Type": "application/json"]
            let body: String
            switch mode {
            case .success:
                headers["Set-Cookie"] = "session_id=\(sid); Path=/; Secure; HttpOnly"
                body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"uid\":8,\"db\":\"\(db)\",\"username\":\"\(login)\",\"name\":\"User\"}}"
            case .accessDenied:
                body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":200,\"message\":\"Odoo Server Error\","
                    + "\"data\":{\"name\":\"odoo.exceptions.AccessDenied\",\"message\":\"Access Denied\"}}}"
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if held {
            DispatchQueue.global().async { Self.gate.wait(); reply() }
        } else {
            reply()
        }
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class SelfHealSharedJarIsolationTests: XCTestCase {

    private var host = ""
    private var server: String { "https://\(host)" }
    private let jar = HTTPCookieStorage.shared

    override func setUp() {
        super.setUp()
        host = "heal-\(UUID().uuidString.prefix(8).lowercased()).example.com"
    }

    override func tearDown() {
        jar.cookies(for: URL(string: server)!)?.forEach { jar.deleteCookie($0) }
        super.tearDown()
    }

    private func account(_ username: String) -> OdooAccount {
        OdooAccount(serverUrl: server, database: "db", username: username, displayName: username)
    }

    private func makeAPIClient() -> OdooAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HealJarURLProtocol.self]
        return OdooAPIClient(session: URLSession(configuration: config))
    }

    private func putJarSession(_ value: String) {
        jar.setCookie(HTTPCookie(properties: [.name: "session_id", .value: value, .domain: host,
                                              .path: "/", .secure: "TRUE"])!)
    }

    private var jarSessionIds: [String] {
        (jar.cookies(for: URL(string: server)!) ?? []).filter { $0.name == "session_id" }.map(\.value)
    }

    private func storage(_ accounts: [OdooAccount], sessions: [String: String]) -> MockSecureStorage {
        let storage = MockSecureStorage()
        for a in accounts {
            storage.savePassword(serverUrl: a.fullServerUrl, username: a.username, password: "pw-\(a.username)")
            if let sid = sessions[a.username] {
                storage.saveSessionId(serverUrl: a.fullServerUrl, username: a.username, sessionId: sid)
            }
        }
        return storage
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// B's stored password is rejected: its heal must not delete sibling A's session cookie.
    func test_selfHeal_wrongPasswordForB_keepsSameHostSiblingASessionInSharedJar() async {
        let a = account("tester"), b = account("mate")
        let repo = JarAccountRepo(); repo.accounts = [a, b]; repo.activeId = a.id
        putJarSession("sid-a")
        HealJarURLProtocol.reset(mode: .accessDenied)
        let reauth = SessionReauthenticator(accountRepository: repo,
                                            secureStorage: storage([a, b], sessions: ["tester": "sid-a", "mate": "sid-b-old"]),
                                            authenticator: makeAPIClient(), reloginSignal: SilentRelogin())

        let healed = await reauth.reauthenticateForHost(host, accountId: b.id)

        XCTAssertFalse(healed)
        XCTAssertEqual(jarSessionIds, ["sid-a"], "B's failed heal must leave A's session cookie in the shared jar")
    }

    /// The only account on the host: its rejected heal still clears its stale session (unchanged).
    func test_selfHeal_wrongPasswordForOnlyAccountOnHost_clearsItsStaleSession() async {
        let a = account("tester")
        let repo = JarAccountRepo(); repo.accounts = [a]; repo.activeId = a.id
        putJarSession("sid-a-stale")
        HealJarURLProtocol.reset(mode: .accessDenied)
        let reauth = SessionReauthenticator(accountRepository: repo,
                                            secureStorage: storage([a], sessions: ["tester": "sid-a-stale"]),
                                            authenticator: makeAPIClient(), reloginSignal: SilentRelogin())

        let healed = await reauth.reauthenticateForHost(host, accountId: a.id)

        XCTAssertFalse(healed)
        XCTAssertEqual(jarSessionIds, [], "stale session cleared")
    }

    /// The heal's authenticate must neither send nor store shared-jar cookies.
    func test_selfHeal_authenticateTransport_doesNotHandleSharedJarCookies() async {
        let a = account("tester")
        let repo = JarAccountRepo(); repo.accounts = [a]; repo.activeId = a.id
        HealJarURLProtocol.reset(mode: .success)
        let reauth = SessionReauthenticator(accountRepository: repo, secureStorage: storage([a], sessions: [:]),
                                            authenticator: makeAPIClient(), reloginSignal: SilentRelogin())

        _ = await reauth.reauthenticateForHost(host, accountId: a.id)

        XCTAssertEqual(HealJarURLProtocol.handlesCookies, [false],
                       "the re-auth request must run with automatic cookie handling off")
    }

    /// Still the target: the healed session is committed to the jar and becomes the account's session.
    func test_selfHeal_successWhileStillTarget_commitsHealedSessionToJarAndKeychain() async {
        let a = account("tester")
        let repo = JarAccountRepo(); repo.accounts = [a]; repo.activeId = a.id
        putJarSession("sid-a-old")
        HealJarURLProtocol.reset(mode: .success, replySessionId: "sid-a-new")
        let store = storage([a], sessions: ["tester": "sid-a-old"])
        let reauth = SessionReauthenticator(accountRepository: repo, secureStorage: store,
                                            authenticator: makeAPIClient(), reloginSignal: SilentRelogin())

        let healed = await reauth.reauthenticateForHost(host, accountId: a.id)

        XCTAssertTrue(healed)
        XCTAssertEqual(jarSessionIds, ["sid-a-new"])
        XCTAssertEqual(store.getSessionId(serverUrl: a.fullServerUrl, username: a.username), "sid-a-new")
    }

    /// A's heal answers only after the user switched to same-host B: B's jar session stays, and the
    /// late heal does not claim success for an account that no longer owns the host's session.
    func test_selfHeal_lateSuccessForA_afterSwitchToSameHostB_leavesBsJarSession() async {
        let a = account("tester"), b = account("mate")
        let repo = JarAccountRepo(); repo.accounts = [a, b]; repo.activeId = a.id
        putJarSession("sid-a-old")
        HealJarURLProtocol.reset(mode: .success, replySessionId: "sid-a-new", hold: true)
        let store = storage([a, b], sessions: ["tester": "sid-a-old", "mate": "sid-b"])
        let reauth = SessionReauthenticator(accountRepository: repo, secureStorage: store,
                                            authenticator: makeAPIClient(), reloginSignal: SilentRelogin())

        let heal = Task { await reauth.reauthenticateForHost(host, accountId: a.id) }
        await waitUntil(!HealJarURLProtocol.handlesCookies.isEmpty)
        repo.activeId = b.id            // the user switches to B while A's heal is in flight
        putJarSession("sid-b")          // B's switch publishes its session to the jar
        HealJarURLProtocol.release()
        let healed = await heal.value

        XCTAssertFalse(healed, "a heal whose account no longer owns the host's session must not report success")
        XCTAssertEqual(jarSessionIds, ["sid-b"], "A's late heal must not overwrite B's session in the shared jar")
        XCTAssertEqual(store.getSessionId(serverUrl: a.fullServerUrl, username: a.username), "sid-a-old")
        XCTAssertEqual(HealJarURLProtocol.destroyedSessions, ["sid-a-new"], "the unused healed session is revoked")
    }

    /// An account removed while its heal was in flight gets nothing written for it.
    func test_selfHeal_lateSuccessForRemovedAccount_writesNothing() async {
        let a = account("tester")
        let repo = JarAccountRepo(); repo.accounts = [a]; repo.activeId = a.id
        HealJarURLProtocol.reset(mode: .success, replySessionId: "sid-a-new", hold: true)
        let reauth = SessionReauthenticator(accountRepository: repo, secureStorage: storage([a], sessions: [:]),
                                            authenticator: makeAPIClient(), reloginSignal: SilentRelogin())

        let heal = Task { await reauth.reauthenticateForHost(host, accountId: a.id) }
        await waitUntil(!HealJarURLProtocol.handlesCookies.isEmpty)
        repo.accounts = []; repo.activeId = nil   // logged out meanwhile
        HealJarURLProtocol.release()
        let healed = await heal.value

        XCTAssertFalse(healed)
        XCTAssertEqual(jarSessionIds, [], "no session may be published for a removed account")
        XCTAssertEqual(HealJarURLProtocol.destroyedSessions, ["sid-a-new"], "the unused healed session is revoked")
    }
}
