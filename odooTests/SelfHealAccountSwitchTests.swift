//
//  SelfHealAccountSwitchTests.swift
//  odooTests
//
//  F1 (0930, account isolation): the WebView's session-expiry self-heal is asynchronous. Two gaps
//  let it act on the wrong account once a second account exists:
//  - a heal started for account A that finished AFTER the user switched to B still drove the root
//    state — a failed A heal bounced a perfectly healthy B to the login screen;
//  - the heal resolved its account by host only, so with two accounts on the same server
//    (demo111) the active account B's expiry re-authenticated whichever account was stored first.
//

import XCTest
@testable import odoo

private final class SwitchableAccountRepo: AccountRepositoryProtocol, @unchecked Sendable {
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

/// Holds each re-auth until the test releases it, and records whose credentials were sent.
private final class GatedAuthenticator: SessionAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var usernames: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var result: AuthResult = .error("rejected", .networkError)

    var sentUsernames: [String] { lock.lock(); defer { lock.unlock() }; return usernames }

    func authenticateIsolated(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        lock.lock(); usernames.append(username); let open = released; lock.unlock()
        if !open {
            await withCheckedContinuation { cont in
                lock.lock()
                if released { lock.unlock(); cont.resume() } else { waiters.append(cont); lock.unlock() }
            }
        }
        return result
    }

    func release() {
        lock.lock(); released = true; let pending = waiters; waiters = []; lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private struct NoRelogin: ReloginSignaling {
    func requestRelogin(accountId: String) {}
}

@MainActor
final class SelfHealAccountSwitchTests: XCTestCase {

    private let server = "https://same.example.com"

    override func tearDown() {
        // A healed session is published to the real shared jar (pi 0930): leave it clean.
        HTTPCookieStorage.shared.cookies(for: URL(string: server)!)?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        super.tearDown()
    }

    private func account(_ username: String) -> OdooAccount {
        OdooAccount(serverUrl: server, database: "db", username: username, displayName: username)
    }

    private func storage(for accounts: [OdooAccount]) -> MockSecureStorage {
        let storage = MockSecureStorage()
        for a in accounts { storage.savePassword(serverUrl: a.fullServerUrl, username: a.username, password: "pw-\(a.username)") }
        return storage
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A heal for A that fails after the user switched to B must leave B signed in.
    func test_selfHeal_failingAfterSwitch_doesNotBounceNewAccountToLogin() async {
        let a = account("tester"), b = account("mate")
        let repo = SwitchableAccountRepo()
        repo.accounts = [a, b]
        repo.activeId = a.id
        let auth = GatedAuthenticator()
        let reauth = SessionReauthenticator(accountRepository: repo, secureStorage: storage(for: [a, b]),
                                            authenticator: auth, reloginSignal: NoRelogin())
        let sut = AppRootViewModel(accountRepository: repo, reauthenticator: reauth)
        sut.checkSession()
        XCTAssertEqual(sut.launchState, .authenticated)

        let heal = Task { await sut.attemptSelfHealOrLogin() }
        await waitUntil(!auth.sentUsernames.isEmpty)
        repo.activeId = b.id          // the user switches to B while A's heal is in flight
        auth.release()                // A's heal then fails
        _ = await heal.value

        XCTAssertEqual(sut.launchState, .authenticated,
                       "a stale heal for A must not send the (healthy) active account B to login")
    }

    /// Two accounts on the same server: the active account's expiry re-authenticates THAT account.
    func test_selfHeal_sameHostAccounts_reauthenticatesTheActiveAccount() async {
        let a = account("tester"), b = account("mate")
        let repo = SwitchableAccountRepo()
        repo.accounts = [a, b]          // A is stored first
        repo.activeId = b.id            // B is the active account whose session expired
        let auth = GatedAuthenticator()
        auth.release()
        auth.result = .success(.init(userId: 2, sessionId: "s", username: "mate", displayName: "mate"))
        let reauth = SessionReauthenticator(accountRepository: repo, secureStorage: storage(for: [a, b]),
                                            authenticator: auth, reloginSignal: NoRelogin())
        let sut = AppRootViewModel(accountRepository: repo, reauthenticator: reauth)
        sut.checkSession()

        let state = await sut.attemptSelfHealOrLogin()

        XCTAssertEqual(state, .authenticated)
        XCTAssertEqual(auth.sentUsernames, ["mate"], "only the active account's credentials may be sent")
    }
}
