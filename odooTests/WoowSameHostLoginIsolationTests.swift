//
//  WoowSameHostLoginIsolationTests.swift
//  odooTests
//
//  demo111 live run 2026-09-30 (verify-ios-0930b, defect 2): with the WOOW brand, adding a second
//  account on the SAME server logged the first one out on the server. The WOOW login and switch
//  authenticated over the shared cookie jar, so the request carried the first account's
//  `session_id`; Odoo re-authenticated THAT session as the second user and rotated it, deleting
//  the first account's session. Reproduced twice (A valid → add B → A `SessionExpiredException`).
//
//  A WOOW login or switch must authenticate without sending any existing session, keep every
//  other account's stored session, and make the new session the one the WebView and the jar use.
//

import XCTest
@testable import odoo

/// `/web/session/authenticate` → success, `session_id=<replySessionId>`; records each request's
/// Cookie header and whether URLSession handled cookies. `/web/session/destroy` → recorded.
private final class WoowLoginURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _reply = "sid-new"
    private static var _auth: [(cookie: String?, handlesCookies: Bool)] = []
    private static var _destroyed: [String] = []

    static func reset(reply: String) { lock.lock(); _reply = reply; _auth = []; _destroyed = []; lock.unlock() }
    static var authRequests: [(cookie: String?, handlesCookies: Bool)] { lock.lock(); defer { lock.unlock() }; return _auth }
    static var destroyed: [String] { lock.lock(); defer { lock.unlock() }; return _destroyed }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var headers = ["Content-Type": "application/json"]
        let body: String
        if url.path == "/web/session/destroy" {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            Self.lock.lock(); Self._destroyed.append(cookie.replacingOccurrences(of: "session_id=", with: "")); Self.lock.unlock()
            body = #"{"jsonrpc":"2.0","id":1,"result":true}"#
        } else {
            Self.lock.lock()
            Self._auth.append((request.value(forHTTPHeaderField: "Cookie"), request.httpShouldHandleCookies))
            let sid = Self._reply
            Self.lock.unlock()
            let params = (Self.json(request))?["params"] as? [String: Any]
            let login = params?["login"] as? String ?? "", db = params?["db"] as? String ?? ""
            headers["Set-Cookie"] = "session_id=\(sid); Path=/; Secure; HttpOnly"
            body = #"{"jsonrpc":"2.0","id":1,"result":{"uid":9,"db":"\#(db)","username":"\#(login)","name":"Mate"}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
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
private final class WoowNoopWebDataCleaner: AccountWebDataCleaning {
    func sessionIds(forAccountId id: String, host: String) async -> [String] { [] }
    func removeWebData(forAccountId id: String, host: String, sessionIds: Set<String>,
                       otherAccountHosts: [String]) async {}
    func pruneOrphanStores(keeping accountIds: Set<String>) async {}
}

private actor WoowRevokeRecorder {
    private(set) var sessionIds: [String] = []
    func record(_ sessionId: String) { sessionIds.append(sessionId) }
}

@MainActor
final class WoowSameHostLoginIsolationTests: XCTestCase {

    private var host = ""
    private var server: String { "https://\(host)" }
    private let jar = HTTPCookieStorage.shared
    private let keychain = SecureStorage.shared
    private var persistence: PersistenceController!
    private var repo: AccountRepository!
    private var revoker: WoowRevokeRecorder!

    override func setUp() async throws {
        try await super.setUp()
        host = "woow-\(UUID().uuidString.prefix(8).lowercased()).example.com"
        persistence = PersistenceController(inMemory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WoowLoginURLProtocol.self]
        config.httpCookieStorage = jar
        revoker = WoowRevokeRecorder()
        let recorder = revoker!
        repo = AccountRepository(persistence: persistence, secureStorage: keychain,
                                 apiClient: OdooAPIClient(session: URLSession(configuration: config)),
                                 brand: .woowtech, webDataCleaner: WoowNoopWebDataCleaner(),
                                 revokeSession: { _, sid in await recorder.record(sid) })
    }

    override func tearDown() async throws {
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

    /// Adding B on A's server must not send A's session (Odoo would rotate it as B's and drop A's).
    func test_addSecondAccountSameHost_sendsNoSession_keepsFirstAccountsSession() async throws {
        repo.replaceAccountsForTesting([SeededAccount(serverURL: server, database: "db", username: "tester",
                                                      sessionCookie: "sid-a", isActive: true)])
        XCTAssertEqual(jarSessionIds, ["sid-a"], "precondition: A's session is the host's jar session")
        WoowLoginURLProtocol.reset(reply: "sid-b")

        let result = await repo.authenticate(serverUrl: server, database: "db", username: "mate", password: "pw-b")

        guard case .success = result else { return XCTFail("login failed: \(result)") }
        XCTAssertEqual(WoowLoginURLProtocol.authRequests.count, 1)
        XCTAssertNil(WoowLoginURLProtocol.authRequests.first?.cookie ?? nil,
                     "logging in B must not carry A's session_id")
        XCTAssertEqual(WoowLoginURLProtocol.authRequests.first?.handlesCookies, false,
                       "the login request must not pick up or store shared-jar cookies automatically")
        XCTAssertEqual(keychain.getSessionId(serverUrl: server, username: "tester"), "sid-a",
                       "A keeps its own session")
        XCTAssertEqual(keychain.getSessionId(serverUrl: server, username: "mate"), "sid-b")
        XCTAssertEqual(jarSessionIds, ["sid-b"], "the new active account's session is published to the jar")
        XCTAssertEqual(repo.getActiveAccount()?.username, "mate")
    }

    /// Switching back to A must not send B's session either; A's new session is published and
    /// A's own replaced session is revoked.
    func test_switchSameHost_sendsNoSession_publishesTargetsNewSession() async throws {
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: server, database: "db", username: "tester", sessionCookie: "sid-a-old", isActive: false),
            SeededAccount(serverURL: server, database: "db", username: "mate", sessionCookie: "sid-b", isActive: true),
        ])
        let a = try XCTUnwrap(repo.getAllAccounts().first { $0.username == "tester" })
        keychain.savePassword(serverUrl: server, username: "tester", password: "pw-a")
        putJarSession("sid-b")
        WoowLoginURLProtocol.reset(reply: "sid-a-new")

        let switched = await repo.switchAccount(id: a.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(WoowLoginURLProtocol.authRequests.count, 1)
        XCTAssertNil(WoowLoginURLProtocol.authRequests.first?.cookie ?? nil, "switching to A must not carry B's session_id")
        XCTAssertEqual(WoowLoginURLProtocol.authRequests.first?.handlesCookies, false)
        XCTAssertEqual(keychain.getSessionId(serverUrl: server, username: "mate"), "sid-b", "B keeps its own session")
        XCTAssertEqual(keychain.getSessionId(serverUrl: server, username: "tester"), "sid-a-new")
        XCTAssertEqual(jarSessionIds, ["sid-a-new"])
        XCTAssertEqual(repo.getActiveAccount()?.id, a.id)
        var revoked: [String] = []
        for _ in 0..<100 {
            revoked = await revoker.sessionIds
            if !revoked.isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(revoked, ["sid-a-old"], "only A's own replaced session is revoked")
    }
}
