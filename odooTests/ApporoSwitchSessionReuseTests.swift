//
//  ApporoSwitchSessionReuseTests.swift
//  odooTests
//
//  demo111 live run 2026-09-29 run3 (D5): every Apporo account switch re-authenticated with the
//  stored password — a new server session, a new res.users.log row and an orphaned old session on
//  EVERY switch (~15 s each), because `switchApporoAccount` called `authenticatePushSession`
//  whenever a password was stored, without first trying the session it already had.
//
//  A switch must reuse the target account's session when the server still accepts it for the same
//  user and database (one `/web/session/get_session_info` call, sent with ONLY that session cookie);
//  it re-authenticates only when that session is rejected or cannot be used, and then revokes the
//  session it replaced. Push bookkeeping stays tied to the credential generation: reusing keeps the
//  generation (still registered); a new session gets a new generation (re-register), as before.
//

import XCTest
@testable import odoo

private actor SwitchRevokeRecorder {
    private(set) var sessionIds: [String] = []
    func record(_ sessionId: String) { sessionIds.append(sessionId) }
}

@MainActor
final class ApporoSwitchSessionReuseTests: XCTestCase {

    /// Answers `/web/session/get_session_info` per `infoMode` and `/web/session/authenticate` with
    /// a fresh `session_id=sess-new`. Records path + Cookie header of every request.
    private final class SwitchURLProtocol: URLProtocol {
        enum InfoMode { case valid(uid: Int, db: String), validWithoutDatabase(uid: Int), expired }
        nonisolated(unsafe) static var infoMode: InfoMode = .valid(uid: 1, db: "demo888")
        nonisolated(unsafe) static var requests: [(path: String, cookie: String?)] = []
        /// Runs on the loading thread while the switch's re-login is in flight.
        nonisolated(unsafe) static var onAuthenticate: (() -> Void)?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let path = request.url?.path ?? ""
            Self.requests.append((path, request.value(forHTTPHeaderField: "Cookie")))
            var headers = ["Content-Type": "application/json"]
            let body: String
            switch path {
            case "/web/session/get_session_info":
                switch Self.infoMode {
                case .valid(let uid, let db):
                    body = #"{"jsonrpc":"2.0","id":"1","result":{"uid":\#(uid),"db":"\#(db)","username":"admin"}}"#
                case .validWithoutDatabase(let uid):
                    body = #"{"jsonrpc":"2.0","id":"1","result":{"uid":\#(uid),"username":"admin"}}"#
                case .expired:
                    body = #"{"jsonrpc":"2.0","id":"1","error":{"code":100,"message":"Odoo Session Expired","data":{"name":"odoo.http.SessionExpiredException","message":"Session expired"}}}"#
                }
            case "/web/session/authenticate":
                Self.onAuthenticate?()
                headers["Set-Cookie"] = "session_id=sess-new; Path=/; Secure; HttpOnly"
                body = #"{"jsonrpc":"2.0","id":"1","result":{"uid":1,"name":"Administrator","username":"admin","db":"demo888"}}"#
            default:
                body = #"{"jsonrpc":"2.0","id":"1","result":null}"#
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private let serverB = "https://demo888-odoo.woowtech.io"
    private var persistence: PersistenceController!
    private var secureStorage: SecureStorage!
    private var repo: AccountRepository!
    private var revoker: SwitchRevokeRecorder!
    private var accountB: OdooAccount!

    override func setUp() async throws {
        try await super.setUp()
        SwitchURLProtocol.requests = []
        SwitchURLProtocol.infoMode = .valid(uid: 1, db: "demo888")
        SwitchURLProtocol.onAuthenticate = nil
        persistence = PersistenceController(inMemory: true)
        secureStorage = SecureStorage.shared
        revoker = SwitchRevokeRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SwitchURLProtocol.self]
        let recorder = revoker!
        repo = AccountRepository(persistence: persistence, secureStorage: secureStorage,
                                 apiClient: OdooAPIClient(session: URLSession(configuration: config)),
                                 brand: .apporo, webDataCleaner: NoopWebDataCleaner(),
                                 revokeSession: { _, sid in await recorder.record(sid) })
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: "https://demo777-odoo.woowtech.io", database: "demo777",
                          username: "admin", sessionCookie: "sess-a", isActive: true),
            SeededAccount(serverURL: serverB, database: "demo888",
                          username: "admin", sessionCookie: "sess-b", isActive: false),
        ])
        accountB = try XCTUnwrap(repo.getAllAccounts().first { $0.database == "demo888" })
    }

    override func tearDown() async throws {
        for account in repo.getAllAccounts() {
            secureStorage.deletePushCredential(accountId: account.id)
            secureStorage.deleteSessionId(accountId: account.id)
        }
        repo = nil
        try await super.tearDown()
    }

    private func sessionCookie(_ value: String) throws -> PushSessionCookie {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session_id", .value: value,
            .domain: "demo888-odoo.woowtech.io", .path: "/", .secure: "TRUE"]))
        return try XCTUnwrap(PushSessionCookie(cookie: cookie,
            responseURL: URL(string: "\(serverB)/web/session/authenticate")!))
    }

    private func storeCredential(withCookie: Bool) throws -> PushCredential {
        let credential = PushCredential(account: accountB, password: "password-b", sessionId: "sess-b",
                                        sessionCookie: withCookie ? try sessionCookie("sess-b") : nil)
        secureStorage.savePushCredential(credential)
        return credential
    }

    private func revokedIds() async -> [String] {
        for _ in 0..<100 {
            let ids = await revoker.sessionIds
            if !ids.isEmpty { return ids }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await revoker.sessionIds
    }

    func test_switch_givenStillValidSession_reusesItWithoutReauthenticating() async throws {
        let stored = try storeCredential(withCookie: true)

        let switched = await repo.switchAccount(id: accountB.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(repo.getActiveAccount()?.id, accountB.id)
        XCTAssertEqual(SwitchURLProtocol.requests.map(\.path), ["/web/session/get_session_info"],
                       "a valid session must not trigger a new login")
        XCTAssertEqual(SwitchURLProtocol.requests.first?.cookie, "session_id=sess-b",
                       "the check carries only the target account's own session")
        let after = try XCTUnwrap(secureStorage.pushCredential(accountId: accountB.id))
        XCTAssertEqual(after.sessionId, "sess-b")
        XCTAssertEqual(after.generation, stored.generation, "reuse keeps the push generation")
        try await Task.sleep(nanoseconds: 100_000_000)
        let revoked = await revoker.sessionIds
        XCTAssertTrue(revoked.isEmpty, "nothing to revoke when the session is reused")
    }

    /// demo111 0930b defect 1: B's session expired, the self-heal logged B in again — and the next
    /// switch to B then logged in ONCE MORE, because B's push credential still held the dead
    /// session. After a heal, switching to B must reuse the healed session (no new login).
    func test_switch_afterSelfHealOfTarget_reusesHealedSessionWithoutReauthenticating() async throws {
        let stored = try storeCredential(withCookie: true)
        secureStorage.savePassword(accountId: accountB.id, password: "password-b")
        defer { secureStorage.deletePassword(accountId: accountB.id) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SwitchURLProtocol.self]
        let reauth = SessionReauthenticator(accountRepository: repo, secureStorage: secureStorage,
                                            authenticator: OdooAPIClient(session: URLSession(configuration: config)),
                                            reloginSignal: ReloginSignal(), cookieJar: HTTPCookieStorage(),
                                            pushCredentials: secureStorage)
        let healed = await reauth.reauthenticateForHost(accountB.serverHost, accountId: accountB.id)
        XCTAssertTrue(healed, "precondition: the heal logged B in (sess-new)")
        SwitchURLProtocol.requests = []

        let switched = await repo.switchAccount(id: accountB.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(SwitchURLProtocol.requests.map(\.path), ["/web/session/get_session_info"],
                       "the healed session must be reused, not replaced by another login")
        XCTAssertEqual(SwitchURLProtocol.requests.first?.cookie, "session_id=sess-new")
        let after = try XCTUnwrap(secureStorage.pushCredential(accountId: accountB.id))
        XCTAssertEqual(after.sessionId, "sess-new")
        XCTAssertEqual(after.generation, stored.generation)
    }

    func test_switch_givenExpiredSession_reauthenticatesAndRevokesTheOldOne() async throws {
        let stored = try storeCredential(withCookie: true)
        SwitchURLProtocol.infoMode = .expired

        let switched = await repo.switchAccount(id: accountB.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(SwitchURLProtocol.requests.map(\.path),
                       ["/web/session/get_session_info", "/web/session/authenticate"])
        let after = try XCTUnwrap(secureStorage.pushCredential(accountId: accountB.id))
        XCTAssertEqual(after.sessionId, "sess-new")
        XCTAssertNotEqual(after.generation, stored.generation, "a new session re-registers push")
        let revoked = await revokedIds()
        XCTAssertEqual(revoked, ["sess-b"], "the replaced session is revoked best-effort")
    }

    func test_switch_givenSessionOfAnotherUser_reauthenticates() async throws {
        _ = try storeCredential(withCookie: true)
        SwitchURLProtocol.infoMode = .valid(uid: 99, db: "demo888")

        let switched = await repo.switchAccount(id: accountB.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(SwitchURLProtocol.requests.map(\.path).last, "/web/session/authenticate")
        XCTAssertEqual(secureStorage.pushCredential(accountId: accountB.id)?.sessionId, "sess-new")
    }

    func test_switch_givenSessionOfAnotherDatabase_reauthenticates() async throws {
        _ = try storeCredential(withCookie: true)
        SwitchURLProtocol.infoMode = .valid(uid: 1, db: "other-db")

        _ = await repo.switchAccount(id: accountB.id)

        XCTAssertEqual(SwitchURLProtocol.requests.map(\.path).last, "/web/session/authenticate")
    }

    /// pi 0930 P1: a session the server accepts without naming its database is not proven to belong
    /// to the target database (two databases on one host can share a uid) — fail closed and log in.
    func test_switch_givenSessionInfoWithoutDatabase_reauthenticates() async throws {
        _ = try storeCredential(withCookie: true)
        SwitchURLProtocol.infoMode = .validWithoutDatabase(uid: 1)

        _ = await repo.switchAccount(id: accountB.id)

        XCTAssertEqual(SwitchURLProtocol.requests.map(\.path).last, "/web/session/authenticate",
                       "a session without database evidence must not be reused")
        XCTAssertNotEqual(secureStorage.pushCredential(accountId: accountB.id)?.sessionId, "sess-b")
    }

    /// pi 0930 P1: a switch superseded by a newer selection while its re-login is in flight commits
    /// nothing — so it must not revoke the target's stored session either (it stays B's only session).
    func test_switch_supersededDuringReauth_keepsAndDoesNotRevokeStoredSession() async throws {
        _ = try storeCredential(withCookie: true)
        SwitchURLProtocol.infoMode = .expired
        SwitchURLProtocol.onAuthenticate = {
            // The user picks another account while B is re-authenticating.
            DispatchQueue.main.sync { MainActor.assumeIsolated { _ = PushManualLoginOrder.begin() } }
        }

        let switched = await repo.switchAccount(id: accountB.id)

        XCTAssertFalse(switched, "a superseded switch commits nothing")
        try await Task.sleep(nanoseconds: 300_000_000)
        let revoked = await revoker.sessionIds
        XCTAssertTrue(revoked.isEmpty, "B's stored session must not be revoked by an uncommitted switch: \(revoked)")
        XCTAssertEqual(secureStorage.pushCredential(accountId: accountB.id)?.sessionId, "sess-b")
    }

    /// A credential saved by an older build carries no reusable cookie: behave as before
    /// (re-authenticate) and revoke the session it replaces.
    func test_switch_givenCredentialWithoutCookie_reauthenticatesAsBefore() async throws {
        _ = try storeCredential(withCookie: false)

        let switched = await repo.switchAccount(id: accountB.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(SwitchURLProtocol.requests.map(\.path), ["/web/session/authenticate"])
        let revoked = await revokedIds()
        XCTAssertEqual(revoked, ["sess-b"])
    }
}

@MainActor
private final class NoopWebDataCleaner: AccountWebDataCleaning {
    func sessionIds(forAccountId id: String, host: String) async -> [String] { [] }
    func removeWebData(forAccountId id: String, host: String, sessionIds: Set<String>,
                       otherAccountHosts: [String]) async {}
    func pruneOrphanStores(keeping accountIds: Set<String>) async {}
}
