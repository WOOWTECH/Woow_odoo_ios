//
//  SessionReauthenticatorTests.swift
//  odooTests
//
//  Story S3 (FCM token lifecycle) — iOS session self-heal parity, AC7.a/b/c.
//
//  This suite is the iOS half of ONE parity matrix shared with Android's
//  SessionReauthInterceptorTest (WI-3). Each test mirrors a row of that matrix so iOS parity is
//  enforced, not assumed:
//    - 200 SessionExpired envelope -> exactly one silent re-auth -> replay -> success  (AC7.a)
//    - persistent SessionExpired   -> exactly one retry, then give up (retry cap = 1)  (AC7.c #2)
//    - bad credentials             -> STOP, clear session, signal re-login, no retry   (AC7.c #3)
//    - host/scheme safety          -> non-matching / non-https host declines, no POST  (AC7.c #1)
//    - single-flight               -> concurrent expiries collapse to ONE re-auth      (AC7.c #4)
//    - genuine 401                 -> one re-auth -> replay -> success                 (AC7.a)
//    - non-expiry 200              -> pass straight through, no re-auth
//    - onSessionExpired self-heal  -> stays .authenticated on heal, .login otherwise   (AC7.b)
//
//  Every network interaction is hermetic: the register/retry pipeline runs a real OdooAPIClient
//  against an injected URLProtocol seam (no real DNS), and the single re-auth is scripted through a
//  fake SessionAuthenticating (no real DNS). No credential or cookie value is ever logged or
//  asserted-by-value (AC7.c #5).
//

import XCTest
@testable import odoo

// MARK: - Test doubles

/// Configurable account source for the reauthenticator's exact-host resolution.
private final class StubAccountRepo: AccountRepositoryProtocol, @unchecked Sendable {
    var accounts: [OdooAccount] = []
    var active: OdooAccount?

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult { .error("stub", .unknown) }
    func getActiveAccount() -> OdooAccount? { active }
    func getAllAccounts() -> [OdooAccount] { accounts }
    func getAccount(byTenantId tenantId: String) -> OdooAccount? { nil }

    /// Story 10-1: fakes default to "not ambiguous" — these suites predate the ambiguity
    /// concept and assert routing outcomes, not drop-reason discrimination. The tests that
    /// DO exercise ambiguity supply their own closure.
    func isTenantIdAmbiguous(_ tenantId: String) -> Bool { false }

        /// P2-9: this fake resolves no device-scoped key, so the router falls through to
        /// the tenant path these suites were written for. Suites exercising the
        /// account-scoped key use the real repository.
        func getAccount(byDeviceId deviceId: String) -> OdooAccount? { nil }

        func setDeviceId(_ deviceId: String, forAccountId accountId: String) {}

        func isDeviceIdAmbiguous(_ deviceId: String) -> Bool { false }

        func anyAccountHasDeviceId() -> Bool { false }
        /// This fake resolves no tenant at all, so neither ambiguity nor candidacy is
        /// reachable here (story 10-1). Suites that exercise the ambiguous path use the real
        /// repository — see `AmbiguousTenantCoreDataTests`.
        func isAccount(_ accountId: String, candidateForTenantId tenantId: String) -> Bool { false }

    func switchAccount(id: String) async -> Bool { false }
    func activateAccount(id: String) -> Bool { false }
    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) {}
    func logout(accountId: String?) async {}
    func removeAccount(id: String) async {}
    func getSessionId(for serverUrl: String) -> String? { nil }
}

/// Scripts the single re-auth network call and records how many times it ran / whether calls
/// overlapped — the hermetic seam standing in for a real authenticate round-trip (no DNS).
private final class FakeSessionAuthenticator: SessionAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var _authCount = 0
    private var _inFlight = 0
    private var _maxConcurrent = 0
    private var _clearCookiesCount = 0

    /// The result every `authenticate` returns.
    var result: AuthResult = .success(.init(userId: 1, sessionId: "s", username: "admin", displayName: "Admin"))
    /// Artificial delay to widen the concurrency window for the single-flight test.
    var delay: Duration = .zero

    var authCount: Int { lock.lock(); defer { lock.unlock() }; return _authCount }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return _maxConcurrent }
    var clearCookiesCount: Int { lock.lock(); defer { lock.unlock() }; return _clearCookiesCount }

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        lock.lock()
        _authCount += 1
        _inFlight += 1
        _maxConcurrent = max(_maxConcurrent, _inFlight)
        let d = delay
        lock.unlock()

        if d != .zero { try? await Task.sleep(for: d) }

        lock.lock()
        _inFlight -= 1
        lock.unlock()
        return result
    }

    func clearCookies(for serverUrl: String) async {
        lock.lock(); _clearCookiesCount += 1; lock.unlock()
    }
}

/// Records the most recent re-login request (parity with Android's `reloginSignal.request` verify).
private final class RecordingReloginSignal: ReloginSignaling, @unchecked Sendable {
    private let lock = NSLock()
    private var _accountIds: [String] = []
    var requestedAccountIds: [String] { lock.lock(); defer { lock.unlock() }; return _accountIds }

    func requestRelogin(accountId: String) {
        lock.lock(); _accountIds.append(accountId); lock.unlock()
    }
}

/// A URLProtocol seam that serves a scripted queue of `(statusCode, body)` responses and counts
/// requests — the iOS analogue of Android's `MockWebServer` (enqueue + `requestCount`).
private final class SequencedURLProtocol: URLProtocol {
    struct Reply { let status: Int; let body: String }

    private static let lock = NSLock()
    private static var queue: [Reply] = []
    private static var _count = 0

    static func reset() { lock.lock(); queue = []; _count = 0; lock.unlock() }
    static func enqueue(status: Int, body: String) { lock.lock(); queue.append(Reply(status: status, body: body)); lock.unlock() }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self._count += 1
        let reply = Self.queue.isEmpty ? Reply(status: 200, body: "{\"result\":{}}") : Self.queue.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://localhost")!,
            statusCode: reply.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Tests

final class SessionReauthenticatorTests: XCTestCase {

    private let host = "test.example.com"

    private func account(id: String = "acc1", scheme: String = "https://") -> OdooAccount {
        OdooAccount(
            id: id,
            serverUrl: "\(scheme)\(host)",
            database: "db",
            username: "admin",
            displayName: "Admin"
        )
    }

    /// The exact HTTP-200 JSON-RPC session-expired envelope Odoo returns for `type='json'` routes.
    private let expiredEnvelope = """
    {"jsonrpc":"2.0","id":1,"error":{"code":100,"message":"Odoo Session Expired",\
    "data":{"name":"odoo.http.SessionExpiredException","message":"Session expired",\
    "debug":"","arguments":[],"exception_type":"session_expired"}}}
    """

    private func makeAPIClient() -> OdooAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SequencedURLProtocol.self]
        return OdooAPIClient(session: URLSession(configuration: config))
    }

    private func makeReauth(
        accounts: [OdooAccount],
        password: String? = "stored-pass",
        authenticator: FakeSessionAuthenticator,
        relogin: RecordingReloginSignal
    ) -> SessionReauthenticator {
        let repo = StubAccountRepo(); repo.accounts = accounts
        let storage = MockSecureStorage()
        if let password, let acc = accounts.first {
            storage.savePassword(serverUrl: acc.fullServerUrl, username: acc.username, password: password)
        }
        return SessionReauthenticator(
            accountRepository: repo,
            secureStorage: storage,
            authenticator: authenticator,
            reloginSignal: relogin
        )
    }

    override func setUp() { super.setUp(); SequencedURLProtocol.reset() }
    override func tearDown() { SequencedURLProtocol.reset(); super.tearDown() }

    // AC7.a — 200 session-expired body -> re-auth once -> retry succeeds

    func test_200SessionExpired_thenSuccess_reAuthsOnce_andRetrySucceeds() async throws {
        let acc = account()
        let fakeAuth = FakeSessionAuthenticator()
        let relogin = RecordingReloginSignal()
        let reauth = makeReauth(accounts: [acc], authenticator: fakeAuth, relogin: relogin)
        let registrar = SessionHealingRegistrar(apiClient: makeAPIClient(), reauthenticator: reauth)

        SequencedURLProtocol.enqueue(status: 200, body: expiredEnvelope)
        SequencedURLProtocol.enqueue(status: 200, body: "{\"result\":{}}")

        let result = try await registrar.callKwHealing(
            account: acc, model: "woow.fcm.device", method: "register_device",
            kwargs: ["fcm_token": "t", "platform": "ios"]
        )

        XCTAssertNotNil(result, "the retried register must return the success result")
        XCTAssertEqual(SequencedURLProtocol.requestCount, 2, "original + exactly one retry")
        XCTAssertEqual(fakeAuth.authCount, 1, "exactly one re-auth")
        XCTAssertEqual(relogin.requestedAccountIds, [], "a self-healed expiry must not surface re-login")
    }

    // AC7.c #2 — persistent session-expired body stops at the cap (retry cap = 1), no loop

    func test_persistentSessionExpired_onlyOneRetry_thenGivesUp() async {
        let acc = account()
        let fakeAuth = FakeSessionAuthenticator()
        let relogin = RecordingReloginSignal()
        let reauth = makeReauth(accounts: [acc], authenticator: fakeAuth, relogin: relogin)
        let registrar = SessionHealingRegistrar(apiClient: makeAPIClient(), reauthenticator: reauth)

        // Server never recovers — always the session-expired envelope.
        SequencedURLProtocol.enqueue(status: 200, body: expiredEnvelope)
        SequencedURLProtocol.enqueue(status: 200, body: expiredEnvelope)
        SequencedURLProtocol.enqueue(status: 200, body: expiredEnvelope)

        do {
            _ = try await registrar.callKwHealing(
                account: acc, model: "woow.fcm.device", method: "register_device", kwargs: ["fcm_token": "t"]
            )
            XCTFail("a persistently expired session must surface an error, not succeed")
        } catch {
            XCTAssertEqual(error as? OdooAPIError, .sessionExpired, "the surfaced error stays sessionExpired")
        }

        XCTAssertEqual(SequencedURLProtocol.requestCount, 2, "original + exactly one retry, then give up — no loop")
        XCTAssertEqual(fakeAuth.authCount, 1, "re-auth attempted exactly once (the retry is not re-authed)")
    }

    // AC7.c #3 — bad credentials STOP: clear session, emit re-login, no retry, no password re-send loop

    func test_invalidStoredCredentials_clearsSession_signalsReLogin_doesNotRetry() async {
        let acc = account()
        let fakeAuth = FakeSessionAuthenticator()
        fakeAuth.result = .error("bad creds", .invalidCredentials)
        let relogin = RecordingReloginSignal()
        let reauth = makeReauth(accounts: [acc], authenticator: fakeAuth, relogin: relogin)
        let registrar = SessionHealingRegistrar(apiClient: makeAPIClient(), reauthenticator: reauth)

        SequencedURLProtocol.enqueue(status: 200, body: expiredEnvelope)

        do {
            _ = try await registrar.callKwHealing(
                account: acc, model: "woow.fcm.device", method: "register_device", kwargs: ["fcm_token": "t"]
            )
            XCTFail("bad credentials must not silently succeed")
        } catch {
            XCTAssertEqual(error as? OdooAPIError, .sessionExpired)
        }

        XCTAssertEqual(SequencedURLProtocol.requestCount, 1, "no retry: only the original request reached the server")
        XCTAssertEqual(fakeAuth.authCount, 1, "the known-bad password is authenticated once, never hammered")
        XCTAssertEqual(fakeAuth.clearCookiesCount, 1, "stale session cleared")
        XCTAssertEqual(relogin.requestedAccountIds, [acc.id], "re-login signalled for the account")

        // No loop across triggers: a subsequent expiry for the same host is declined WITHOUT another auth.
        let healedAgain = await reauth.reauthenticateForHost(host)
        XCTAssertFalse(healedAgain, "circuit stays open — known-bad password never re-sent")
        XCTAssertEqual(fakeAuth.authCount, 1, "still exactly one auth call after the circuit opened")
    }

    // AC7.c #1 — host/scheme safety: non-matching host declines, no password POST

    func test_noAccountMatchesHost_declines_withoutAuth() async {
        let fakeAuth = FakeSessionAuthenticator()
        let relogin = RecordingReloginSignal()
        let reauth = makeReauth(
            accounts: [account(id: "other").with(serverUrl: "https://different.example.com")],
            authenticator: fakeAuth, relogin: relogin
        )

        let healed = await reauth.reauthenticateForHost("notmatching.example.com")

        XCTAssertFalse(healed)
        XCTAssertEqual(fakeAuth.authCount, 0, "no password is ever sent when no https host matches")
    }

    func test_accountStoredAsHttp_declines_withoutAuth() async {
        let fakeAuth = FakeSessionAuthenticator()
        let relogin = RecordingReloginSignal()
        // Account resolves by host but its STORED url is http -> re-auth refused (guardrail 1).
        let reauth = makeReauth(
            accounts: [account(scheme: "http://")], password: nil,
            authenticator: fakeAuth, relogin: relogin
        )

        let healed = await reauth.reauthenticateForHost(host)

        XCTAssertFalse(healed)
        XCTAssertEqual(fakeAuth.authCount, 0, "a non-https stored account is never a re-auth target")
    }

    // AC7.c #4 — single-flight: concurrent expiries on the same host collapse to ONE re-auth

    func test_concurrentExpiries_sameHost_collapseToOneReAuth() async {
        let acc = account()
        let fakeAuth = FakeSessionAuthenticator()
        fakeAuth.delay = .milliseconds(80) // widen the window so an unguarded impl would overlap
        let relogin = RecordingReloginSignal()
        let reauth = makeReauth(accounts: [acc], authenticator: fakeAuth, relogin: relogin)

        async let a = reauth.reauthenticateForHost(host)
        async let b = reauth.reauthenticateForHost(host)
        let results = await [a, b]

        XCTAssertEqual(results, [true, true], "both concurrent callers observe a refreshed session")
        XCTAssertEqual(fakeAuth.authCount, 1, "single-flight: exactly one re-auth for concurrent same-host expiries")
        XCTAssertEqual(fakeAuth.maxConcurrent, 1, "re-auth calls never overlapped")
    }

    // AC7.a — a genuine transport-level 401 is still honoured (belt-and-suspenders)

    func test_genuine401_thenSuccess_reAuthsOnce_andRetrySucceeds() async throws {
        let acc = account()
        let fakeAuth = FakeSessionAuthenticator()
        let relogin = RecordingReloginSignal()
        let reauth = makeReauth(accounts: [acc], authenticator: fakeAuth, relogin: relogin)
        let registrar = SessionHealingRegistrar(apiClient: makeAPIClient(), reauthenticator: reauth)

        SequencedURLProtocol.enqueue(status: 401, body: "")
        SequencedURLProtocol.enqueue(status: 200, body: "{\"result\":{}}")

        _ = try await registrar.callKwHealing(
            account: acc, model: "woow.fcm.device", method: "register_device", kwargs: ["fcm_token": "t"]
        )

        XCTAssertEqual(SequencedURLProtocol.requestCount, 2, "original + one retry")
        XCTAssertEqual(fakeAuth.authCount, 1, "exactly one re-auth")
    }

    // Non-expiry success bodies pass straight through with no re-auth.

    func test_successBody_passesThrough_noReAuth() async throws {
        let acc = account()
        let fakeAuth = FakeSessionAuthenticator()
        let relogin = RecordingReloginSignal()
        let reauth = makeReauth(accounts: [acc], authenticator: fakeAuth, relogin: relogin)
        let registrar = SessionHealingRegistrar(apiClient: makeAPIClient(), reauthenticator: reauth)

        SequencedURLProtocol.enqueue(status: 200, body: "{\"result\":{\"tenant_id\":\"t1\"}}")

        _ = try await registrar.callKwHealing(
            account: acc, model: "woow.fcm.device", method: "register_device", kwargs: ["fcm_token": "t"]
        )

        XCTAssertEqual(SequencedURLProtocol.requestCount, 1, "no retry on a healthy response")
        XCTAssertEqual(fakeAuth.authCount, 0, "no re-auth on a healthy response")
    }

    // AC7.b — onSessionExpired self-heals first; stays .authenticated when heal succeeds.

    @MainActor
    func test_onSessionExpired_selfHealSucceeds_staysAuthenticated() async {
        let acc = account()
        let repo = MockAccountRepository(); repo.stubbedActiveAccount = acc
        let fakeAuth = FakeSessionAuthenticator()
        let reauth = makeReauth(accounts: [acc], authenticator: fakeAuth, relogin: RecordingReloginSignal())
        let sut = AppRootViewModel(accountRepository: repo, reauthenticator: reauth)

        let state = await sut.attemptSelfHealOrLogin()

        XCTAssertEqual(state, .authenticated, "a self-healable expiry must NOT bounce to login (AC7.b)")
        XCTAssertEqual(sut.launchState, .authenticated)
        XCTAssertEqual(fakeAuth.authCount, 1)
    }

    // AC7.b/c — onSessionExpired falls back to .login when re-auth is impossible.

    @MainActor
    func test_onSessionExpired_selfHealFails_bouncesToLogin() async {
        let acc = account()
        let repo = MockAccountRepository(); repo.stubbedActiveAccount = acc
        let fakeAuth = FakeSessionAuthenticator()
        fakeAuth.result = .error("bad creds", .invalidCredentials)
        let reauth = makeReauth(accounts: [acc], authenticator: fakeAuth, relogin: RecordingReloginSignal())
        let sut = AppRootViewModel(accountRepository: repo, reauthenticator: reauth)

        let state = await sut.attemptSelfHealOrLogin()

        XCTAssertEqual(state, .login, "re-auth impossible -> surface login")
        XCTAssertEqual(sut.launchState, .login)
    }

    @MainActor
    func test_onSessionExpired_noActiveAccount_bouncesToLogin() async {
        let repo = MockAccountRepository(); repo.stubbedActiveAccount = nil
        let fakeAuth = FakeSessionAuthenticator()
        let reauth = makeReauth(accounts: [], password: nil, authenticator: fakeAuth, relogin: RecordingReloginSignal())
        let sut = AppRootViewModel(accountRepository: repo, reauthenticator: reauth)

        let state = await sut.attemptSelfHealOrLogin()

        XCTAssertEqual(state, .login)
        XCTAssertEqual(fakeAuth.authCount, 0, "no active account -> no credential ever sent")
    }
}

// MARK: - Test helper

private extension OdooAccount {
    /// Returns a copy with a different `serverUrl` (the struct's `let` fields make a full re-init).
    func with(serverUrl: String) -> OdooAccount {
        OdooAccount(
            id: id, serverUrl: serverUrl, database: database, username: username,
            displayName: displayName, userId: userId, avatarBase64: avatarBase64,
            lastLogin: lastLogin, isActive: isActive, tenantId: tenantId
        )
    }
}
