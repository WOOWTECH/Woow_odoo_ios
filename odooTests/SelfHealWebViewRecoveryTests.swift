//
//  SelfHealWebViewRecoveryTests.swift
//  odooTests
//
//  demo111 live run 2026-09-30 (verify-ios-0930b, defect 1): after a session expired on the server
//  the WebView was redirected to `/web/login`, the coordinator cancelled that navigation and ran
//  the self-heal — which succeeded — but the page then stayed blank for 60 s+. The healed session
//  was written only to the shared jar and the Keychain: nothing put it into the account's own
//  WebKit store, nothing reloaded the WebView, and (Apporo) the account's push credential kept
//  the dead session, so switching away and back logged in AGAIN and the healed session was never
//  used nor revoked.
//
//  A heal for the current account must hand its session to that account's WebView (and push
//  credential), reload a page it had to cancel for the expiry, and revoke the session it replaced.
//  A heal whose account is no longer the host's session owner changes nothing.
//

import XCTest
import WebKit
import SwiftUI
@testable import odoo

private final class HealRepo: AccountRepositoryProtocol, @unchecked Sendable {
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

private struct QuietRelogin: ReloginSignaling {
    func requestRelogin(accountId: String) {}
}

private final class MemoryPushCredentials: PushCredentialStorage, @unchecked Sendable {
    var credentials: [String: PushCredential] = [:]
    @MainActor func pushCredential(accountId: String) -> PushCredential? { credentials[accountId] }
    @MainActor func savePushCredential(_ credential: PushCredential) { credentials[credential.accountId] = credential }
    @MainActor func deletePushCredential(accountId: String) { credentials[accountId] = nil }
}

/// `/web/session/authenticate` → success with `session_id=<replySessionId>` (optionally held until
/// released); `/web/session/destroy` → recorded.
private final class RecoveryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _replySessionId = "sid-new"
    private static var _destroyed: [String] = []
    private static var _authenticates = 0
    private static var _held = false
    private static let gate = DispatchSemaphore(value: 0)

    static func reset(replySessionId: String, hold: Bool = false) {
        lock.lock(); _replySessionId = replySessionId; _destroyed = []; _authenticates = 0; _held = hold; lock.unlock()
    }
    static var destroyed: [String] { lock.lock(); defer { lock.unlock() }; return _destroyed }
    static var authenticates: Int { lock.lock(); defer { lock.unlock() }; return _authenticates }
    static func release() { gate.signal() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        if url.path == "/web/session/destroy" {
            let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
            Self.lock.lock(); Self._destroyed.append(cookie.replacingOccurrences(of: "session_id=", with: "")); Self.lock.unlock()
            finish(url: url, headers: [:], body: #"{"jsonrpc":"2.0","id":1,"result":true}"#)
            return
        }
        Self.lock.lock(); Self._authenticates += 1
        let sid = Self._replySessionId, held = Self._held
        Self.lock.unlock()
        let params = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? Self.streamJSON(request))?["params"] as? [String: Any]
        let login = params?["login"] as? String ?? "", db = params?["db"] as? String ?? ""
        let reply = { [weak self] in
            self?.finish(url: url, headers: ["Set-Cookie": "session_id=\(sid); Path=/; Secure; HttpOnly"],
                         body: #"{"jsonrpc":"2.0","id":1,"result":{"uid":8,"db":"\#(db)","username":"\#(login)","name":"User"}}"#)
        }
        if held { DispatchQueue.global().async { Self.gate.wait(); reply() } } else { reply() }
    }

    private func finish(url: URL, headers: [String: String], body: String) {
        var all = headers; all["Content-Type"] = "application/json"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: all)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func streamJSON(_ request: URLRequest) -> [String: Any]? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Records `.accountSessionHealed` posts.
private final class HealedObserver {
    private(set) var posts: [(accountId: String, cookie: String)] = []
    private var token: NSObjectProtocol?
    init() {
        token = NotificationCenter.default.addObserver(forName: .accountSessionHealed, object: nil, queue: nil) { [weak self] note in
            let id = note.userInfo?["accountId"] as? String ?? ""
            let cookie = (note.userInfo?["cookie"] as? HTTPCookie)?.value ?? ""
            self?.posts.append((id, cookie))
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

final class SelfHealWebViewRecoveryTests: XCTestCase {

    private var host = ""
    private var server: String { "https://\(host)" }

    override func setUp() {
        super.setUp()
        host = "recover-\(UUID().uuidString.prefix(8).lowercased()).example.com"
    }

    override func tearDown() {
        HTTPCookieStorage.shared.cookies(for: URL(string: server)!)?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        super.tearDown()
    }

    private func account(_ username: String) -> OdooAccount {
        OdooAccount(serverUrl: server, database: "db", username: username, displayName: username)
    }

    private func apiClient() -> OdooAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryURLProtocol.self]
        return OdooAPIClient(session: URLSession(configuration: config))
    }

    private func keychain(_ accounts: [OdooAccount], sessions: [String: String]) -> MockSecureStorage {
        let storage = MockSecureStorage()
        for a in accounts {
            storage.savePassword(accountId: a.id, password: "pw-\(a.username)")
            if let sid = sessions[a.username] { storage.saveSessionId(accountId: a.id, sessionId: sid) }
        }
        return storage
    }

    private func pushCookie(_ value: String) throws -> PushSessionCookie {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session_id", .value: value, .domain: host,
                                                           .path: "/", .secure: "TRUE"]))
        return try XCTUnwrap(PushSessionCookie(cookie: cookie, responseURL: URL(string: "\(server)/web/session/authenticate")!))
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// Apporo: the healed session replaces the dead one in the account's push credential (the
    /// WebView's and the switch's source), the WebView is told, and the replaced session is revoked.
    func test_heal_apporoCurrentAccount_updatesPushCredential_notifiesWebView_revokesReplaced() async throws {
        let b = account("mate")
        let repo = HealRepo(); repo.accounts = [b]; repo.activeId = b.id
        let credentials = MemoryPushCredentials()
        let old = PushCredential(account: b, password: "pw-mate", sessionId: "sid-old", sessionCookie: try pushCookie("sid-old"))
        await MainActor.run { credentials.savePushCredential(old) }
        RecoveryURLProtocol.reset(replySessionId: "sid-new")
        let observer = HealedObserver()
        let reauth = SessionReauthenticator(accountRepository: repo,
                                            secureStorage: keychain([b], sessions: ["mate": "sid-old"]),
                                            authenticator: apiClient(), reloginSignal: QuietRelogin(),
                                            pushCredentials: credentials)

        let healed = await reauth.reauthenticateForHost(host, accountId: b.id)

        XCTAssertTrue(healed)
        let saved = await MainActor.run { credentials.pushCredential(accountId: b.id) }
        XCTAssertEqual(saved?.sessionId, "sid-new", "the push credential must carry the healed session")
        XCTAssertEqual(saved?.sessionCookie?.cookie()?.value, "sid-new",
                       "the cookie the WebView and a later switch reuse must be the healed one")
        XCTAssertEqual(saved?.generation, old.generation, "a heal keeps the login generation (still registered)")
        XCTAssertEqual(saved?.password, "pw-mate")
        XCTAssertEqual(observer.posts.map(\.accountId), [b.id])
        XCTAssertEqual(observer.posts.map(\.cookie), ["sid-new"])
        await waitUntil(RecoveryURLProtocol.destroyed.contains("sid-old"))
        XCTAssertEqual(RecoveryURLProtocol.destroyed, ["sid-old"], "the replaced session is revoked, the healed one is kept")
    }

    /// WOOW (no push credential): the WebView is told about the healed session.
    func test_heal_woowCurrentAccount_notifiesWebViewWithHealedCookie() async {
        let a = account("tester")
        let repo = HealRepo(); repo.accounts = [a]; repo.activeId = a.id
        RecoveryURLProtocol.reset(replySessionId: "sid-a-new")
        let observer = HealedObserver()
        let reauth = SessionReauthenticator(accountRepository: repo,
                                            secureStorage: keychain([a], sessions: ["tester": "sid-a-old"]),
                                            authenticator: apiClient(), reloginSignal: QuietRelogin(),
                                            pushCredentials: MemoryPushCredentials())

        let healed = await reauth.reauthenticateForHost(host, accountId: a.id)

        XCTAssertTrue(healed)
        XCTAssertEqual(observer.posts.map(\.accountId), [a.id])
        XCTAssertEqual(observer.posts.map(\.cookie), ["sid-a-new"])
        await waitUntil(RecoveryURLProtocol.destroyed.contains("sid-a-old"))
        XCTAssertEqual(RecoveryURLProtocol.destroyed, ["sid-a-old"])
    }

    /// demo111 1001 live run: on a cold start the push registrar's own heal refreshed B's push
    /// credential (same login generation) while the WebView's heal was in flight. The WebView must
    /// then use THAT session — the one a later switch reuses — and the heal's own extra session is
    /// revoked, not left valid and unused.
    func test_heal_apporo_credentialRefreshedConcurrently_adoptsItsSession_revokesOwn() async throws {
        let b = account("mate")
        let repo = HealRepo(); repo.accounts = [b]; repo.activeId = b.id
        let credentials = MemoryPushCredentials()
        let old = PushCredential(account: b, password: "pw-mate", sessionId: "sid-old", sessionCookie: try pushCookie("sid-old"))
        await MainActor.run { credentials.savePushCredential(old) }
        RecoveryURLProtocol.reset(replySessionId: "sid-webheal", hold: true)
        let observer = HealedObserver()
        let keychain = keychain([b], sessions: ["mate": "sid-old"])
        let reauth = SessionReauthenticator(accountRepository: repo, secureStorage: keychain,
                                            authenticator: apiClient(), reloginSignal: QuietRelogin(),
                                            pushCredentials: credentials)

        let heal = Task { await reauth.reauthenticateForHost(host, accountId: b.id) }
        await waitUntil(RecoveryURLProtocol.authenticates == 1)
        let pushHealed = PushCredential(account: b, password: "pw-mate", sessionId: "sid-pushheal",
                                        generation: old.generation, sessionCookie: try pushCookie("sid-pushheal"))
        await MainActor.run { credentials.savePushCredential(pushHealed) }   // the push registrar healed meanwhile
        RecoveryURLProtocol.release()
        let healed = await heal.value

        XCTAssertTrue(healed, "the account has a working session")
        let saved = await MainActor.run { credentials.pushCredential(accountId: b.id) }
        XCTAssertEqual(saved, pushHealed, "the concurrently refreshed credential is kept")
        XCTAssertEqual(observer.posts.map(\.cookie), ["sid-pushheal"],
                       "the WebView gets the credential's session, the one a switch reuses")
        XCTAssertEqual(keychain.getSessionId(accountId: b.id), "sid-pushheal")
        await waitUntil(RecoveryURLProtocol.destroyed.count == 2)
        XCTAssertEqual(Set(RecoveryURLProtocol.destroyed), ["sid-old", "sid-webheal"],
                       "the dead session and the heal's own unused session are revoked; the credential's is kept")
    }

    /// A heal answering after the user switched to a same-host sibling changes nothing: no WebView
    /// notification, the push credential keeps its session.
    func test_heal_lateAfterSwitchToSameHostSibling_notifiesNothing_keepsCredential() async throws {
        let a = account("tester"), b = account("mate")
        let repo = HealRepo(); repo.accounts = [a, b]; repo.activeId = a.id
        let credentials = MemoryPushCredentials()
        let old = PushCredential(account: a, password: "pw-tester", sessionId: "sid-a-old", sessionCookie: try pushCookie("sid-a-old"))
        await MainActor.run { credentials.savePushCredential(old) }
        RecoveryURLProtocol.reset(replySessionId: "sid-a-new", hold: true)
        let observer = HealedObserver()
        let reauth = SessionReauthenticator(accountRepository: repo,
                                            secureStorage: keychain([a, b], sessions: ["tester": "sid-a-old"]),
                                            authenticator: apiClient(), reloginSignal: QuietRelogin(),
                                            pushCredentials: credentials)

        let heal = Task { await reauth.reauthenticateForHost(host, accountId: a.id) }
        await waitUntil(RecoveryURLProtocol.authenticates == 1)
        repo.activeId = b.id
        RecoveryURLProtocol.release()
        let healed = await heal.value

        XCTAssertFalse(healed)
        XCTAssertTrue(observer.posts.isEmpty, "a stale heal must not touch any WebView: \(observer.posts)")
        let saved = await MainActor.run { credentials.pushCredential(accountId: a.id) }
        XCTAssertEqual(saved, old)
        await waitUntil(RecoveryURLProtocol.destroyed.contains("sid-a-new"))
        XCTAssertEqual(RecoveryURLProtocol.destroyed, ["sid-a-new"], "only the unused healed session is revoked")
    }
}

// MARK: - Coordinator side

private final class LoadFlag { var value = false }

/// Minimal navigation action for a policy check.
private final class RecoveryNavigationActionStub: WKNavigationAction {
    private let stubRequest: URLRequest
    init(url: URL) { stubRequest = URLRequest(url: url); super.init() }
    override var request: URLRequest { stubRequest }
}

@MainActor
final class SelfHealWebViewReloadTests: XCTestCase {

    private let serverUrl = "https://reload.example.com"
    private var baseLoads = 0
    private var stores: [String: WKWebsiteDataStore] = [:]
    private let loading = LoadFlag()

    private func makeCoordinator() -> OdooWebViewCoordinator {
        let flag = loading
        return OdooWebViewCoordinator(
            serverUrl: serverUrl,
            onSessionExpired: {},
            isLoading: Binding(get: { flag.value }, set: { flag.value = $0 }),
            openExternalURL: { _ in XCTFail("No Safari") },
            brand: .woowtech,
            websiteDataStore: { [weak self] id in
                if let store = self?.stores[id] { return store }
                let store = WKWebsiteDataStore.nonPersistent()
                self?.stores[id] = store
                return store
            },
            loadBaseRequest: { [weak self] _, _ in self?.baseLoads += 1 },
            loadDeepLinkRequest: { _, _ in }
        )
    }

    private func healed(_ accountId: String, _ value: String) {
        let cookie = HTTPCookie(properties: [.name: "session_id", .value: value, .domain: "reload.example.com",
                                             .path: "/", .secure: "TRUE"])!
        NotificationCenter.default.post(name: .accountSessionHealed, object: nil,
                                        userInfo: ["accountId": accountId, "cookie": cookie])
    }

    private func sessionIds(in store: WKWebsiteDataStore) async -> [String] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter { $0.name == "session_id" }.map(\.value))
            }
        }
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// The page was cancelled for the expiry: the healed cookie lands in the account's store and the
    /// WebView reloads (it was left blank before).
    func test_healedAfterExpiryCancel_writesCookieIntoAccountStore_andReloads() async throws {
        let sut = makeCoordinator()
        let a = UUID().uuidString
        sut.apply(serverUrl: serverUrl, database: "db", accountId: a, sessionId: nil, deepLink: nil)
        XCTAssertEqual(baseLoads, 1)
        let live = try XCTUnwrap(sut.webView)
        var policy: WKNavigationActionPolicy?
        sut.webView(live, decidePolicyFor: RecoveryNavigationActionStub(url: URL(string: "\(serverUrl)/web/login")!)) { policy = $0 }
        XCTAssertEqual(policy, .cancel, "precondition: the expiry redirect is cancelled")

        healed(a, "sid-healed")

        await waitUntil(baseLoads == 2)
        XCTAssertEqual(baseLoads, 2, "the cancelled page must be reloaded once the session is healed")
        let ids = await sessionIds(in: try XCTUnwrap(stores[a]))
        XCTAssertEqual(ids, ["sid-healed"], "the healed session must be in the account's own WebKit store")
    }

    /// A heal while the page is fine (e.g. triggered by a push registration): refresh the cookie,
    /// don't interrupt the page.
    func test_healedWithoutExpiryCancel_writesCookie_doesNotReload() async throws {
        let sut = makeCoordinator()
        let a = UUID().uuidString
        sut.apply(serverUrl: serverUrl, database: "db", accountId: a, sessionId: nil, deepLink: nil)

        healed(a, "sid-healed")

        await waitUntil(false, timeout: 0.5)
        XCTAssertEqual(baseLoads, 1, "no reload without a cancelled expiry")
        let ids = await sessionIds(in: try XCTUnwrap(stores[a]))
        XCTAssertEqual(ids, ["sid-healed"])
    }

    /// A heal for another account never reaches the WebView on screen.
    func test_healedForOtherAccount_isIgnored() async throws {
        let sut = makeCoordinator()
        let a = UUID().uuidString
        sut.apply(serverUrl: serverUrl, database: "db", accountId: a, sessionId: nil, deepLink: nil)
        let live = try XCTUnwrap(sut.webView)
        sut.webView(live, decidePolicyFor: RecoveryNavigationActionStub(url: URL(string: "\(serverUrl)/web/login")!)) { _ in }

        healed(UUID().uuidString, "sid-other")

        await waitUntil(false, timeout: 0.5)
        XCTAssertEqual(baseLoads, 1)
        let ids = await sessionIds(in: try XCTUnwrap(stores[a]))
        XCTAssertEqual(ids, [])
    }
}
