import Foundation

// MARK: - Session-expiry detection (WI-3 parity)

/// Detects an expired Odoo session from an authenticated JSON-RPC response.
///
/// Odoo `type='json', auth='user'` routes (`register_device` / `unregister_device`) signal an
/// expired session as **HTTP 200 with a JSON-RPC error envelope**, NOT HTTP 401:
/// ```
/// {"jsonrpc":"2.0","id":1,"error":{"code":100,"message":"Odoo Session Expired",
///   "data":{"name":"odoo.http.SessionExpiredException", ...}}}
/// ```
/// Because the transport code is 200, status-code-only detection (an OkHttp `Authenticator`, or a
/// URLSession 401 handler) never fires. This helper inspects the **response body**, so it detects
/// both the real-world 200-error-body case and a genuine transport-level 401. This is the exact
/// contract Android's `SessionReauthInterceptor.isSessionExpired` handles, kept byte-for-byte in
/// sync so the iOS and Android self-heal share ONE parity matrix.
enum SessionExpiry {

    /// Odoo's exception class name for an expired session, carried in `error.data.name`.
    static let exceptionName = "odoo.http.SessionExpiredException"

    /// Odoo JSON-RPC error code accompanying a session-expired envelope.
    static let expiredCode = 100

    /// Substring identifying a session-expired message on the `code == 100` fallback path.
    static let messageHint = "session expired"

    /// True when EITHER the transport `httpCode` is 401 OR the parsed JSON-RPC `body` carries an
    /// `error` object identifying a session expiry (`data.name == exceptionName`, or the
    /// `code == 100` session-expired fallback). Tolerant: a nil / non-JSON / success body simply
    /// yields false, never a throw.
    static func isSessionExpired(httpCode: Int, body: Data?) -> Bool {
        if httpCode == 401 { return true }
        guard let body, !body.isEmpty else { return false }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return false
        }

        // Preferred signal: the exact exception name in error.data.name.
        if let data = error["data"] as? [String: Any],
           let name = data["name"] as? String,
           name == exceptionName {
            return true
        }

        // Fallback: Odoo session-expired errors carry code == 100 with a session-expired message.
        if let code = error["code"] as? Int, code == expiredCode {
            let message = (error["message"] as? String) ?? ""
            if message.range(of: messageHint, options: .caseInsensitive) != nil {
                return true
            }
        }

        return false
    }
}

// MARK: - Seams (hermetic testing, no real DNS)

/// The single re-auth network capability the reauthenticator needs, factored into a protocol so
/// tests can script `AuthResult`s and refuse-to-connect states WITHOUT touching real DNS. In
/// production this is satisfied by `OdooAPIClient`, which enforces https-only at the transport level.
///
/// pi 0930 (P1): the re-auth transport neither sends nor stores shared-jar cookies. It returns the
/// new session in the result; `SessionReauthenticator` alone decides — on the main actor, against
/// the current accounts — whether that session may be published to the jar the retried request
/// and the WOOW WebView read, and removes a rejected account's session without touching a
/// same-host sibling's.
protocol SessionAuthenticating: Sendable {
    func authenticateIsolated(serverUrl: String, database: String, username: String, password: String) async -> AuthResult
    /// Best-effort server revoke of a healed session that will not be used (its account no longer
    /// owns the host's jar session). Default: nothing.
    func discardSession(serverUrl: String, sessionId: String) async
}

extension SessionAuthenticating {
    func discardSession(serverUrl: String, sessionId: String) async {}
}

extension OdooAPIClient: SessionAuthenticating {
    func authenticateIsolated(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        await authenticatePushSession(serverUrl: serverUrl, database: database, username: username, password: password)
    }

    func discardSession(serverUrl: String, sessionId: String) async {
        await destroySession(serverUrl: serverUrl, sessionId: sessionId)
    }
}

/// The shared `HTTPCookieStorage` the legacy registration requests and the WOOW WebView read. The
/// reauthenticator touches it only on the main actor, in the same step as the account check.
struct SharedCookieJar: @unchecked Sendable {
    let storage: HTTPCookieStorage
}

/// Surfaces a "this account must be re-logged-in manually" signal when self-heal is impossible
/// (stored password rejected server-side, or no stored credential). Kept as a seam so tests can
/// assert the signal (parity with Android's `ReloginSignal.request`) and so the UI layer can observe
/// it without the reauthenticator depending on any view type.
protocol ReloginSignaling: Sendable {
    func requestRelogin(accountId: String)
}

/// Default relogin signal: records the most recent request (testable) and broadcasts a
/// `NotificationCenter` notification the app layer can observe. Never carries a credential or cookie.
final class ReloginSignal: ReloginSignaling, @unchecked Sendable {

    static let shared = ReloginSignal()

    /// Notification posted when an account can no longer self-heal and needs a manual re-login.
    /// `userInfo["accountId"]` carries the opaque account id (never a credential).
    static let didRequestRelogin = Notification.Name("io.woowtech.odoo.didRequestRelogin")

    private let lock = NSLock()
    private var _lastRequestedAccountId: String?

    /// The most recently requested account id, for observation in tests.
    var lastRequestedAccountId: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestedAccountId
    }

    func requestRelogin(accountId: String) {
        lock.lock()
        _lastRequestedAccountId = accountId
        lock.unlock()
        NotificationCenter.default.post(
            name: Self.didRequestRelogin,
            object: nil,
            userInfo: ["accountId": accountId]
        )
    }
}

extension Notification.Name {
    /// Posted on the main actor when a self-heal committed a new session for an account.
    /// `userInfo["accountId"]`: the account; `userInfo["cookie"]`: its new `session_id` `HTTPCookie`.
    /// In-process only — never logged.
    static let accountSessionHealed = Notification.Name("io.woowtech.odoo.accountSessionHealed")
}

// MARK: - SessionReauthenticator

/// Guardrail'd re-authentication engine that transparently self-heals an expired Odoo **session
/// cookie** when an authenticated request (the FCM `register_device` / `unregister_device` calls) is
/// rejected for session expiry. iOS parity of Android's `SessionReauthenticator` (WI-3).
///
/// ## Detection lives in the caller, not here
/// Session-expiry detection lives in `SessionExpiry.isSessionExpired` / `OdooAPIClient.callKw`
/// (which throws `OdooAPIError.sessionExpired`). This engine exposes `reauthenticateForHost`, which
/// the healing layer calls once it has detected an expired session. Every guardrail below is
/// enforced here regardless of how expiry was detected.
///
/// ## Guardrails (AC7.c — the EXACT Android WI-3 checklist)
/// 1. **https-only + exact host.** Re-auth is attempted only against the account's own stored,
///    previously-validated `https` host that exactly matches the failing request's host. The
///    password is never sent to any other host or over a non-https scheme.
/// 2. **ONE retry (cap = 1).** This engine performs exactly one authenticate per attempt; the
///    healing layer replays the original request exactly once. No recursion, no loop.
/// 3. **Bad-credential STOP (no loop).** If re-auth reports invalid credentials (password changed
///    server-side) it STOPS, clears the account's stale session cookie (never a same-host sibling's),
///    opens the account's circuit so the known-bad password is never re-sent, and raises a re-login
///    signal.
/// 4. **Single-flight.** A per-host in-flight `Task` (this is an `actor`) collapses concurrent
///    session-expiry responses for the same host into exactly one authenticate network call.
/// 5. **NEVER log credentials/cookies.** Nothing here logs a password, cookie, or session token.
actor SessionReauthenticator {

    static let shared = SessionReauthenticator()

    private let accountRepository: AccountRepositoryProtocol
    private let secureStorage: SecureStorageProtocol
    private let authenticator: SessionAuthenticating
    private let reloginSignal: ReloginSignaling
    private let cookieJar: SharedCookieJar
    private let pushCredentials: PushCredentialStorage

    /// Per-host single-flight tasks so concurrent expiries on the same host cause exactly one re-auth.
    private var inFlight: [String: Task<Bool, Never>] = [:]

    /// Accounts whose stored password was rejected — auto re-auth disabled until a manual re-login,
    /// so the known-bad password is never re-sent (guardrail 3, "no loop").
    private var openCircuits: Set<String> = []

    init(
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        secureStorage: SecureStorageProtocol = SecureStorage.shared,
        authenticator: SessionAuthenticating = OdooAPIClient(),
        reloginSignal: ReloginSignaling = ReloginSignal.shared,
        cookieJar: HTTPCookieStorage = .shared,
        pushCredentials: PushCredentialStorage = SecureStorage.shared
    ) {
        self.accountRepository = accountRepository
        self.secureStorage = secureStorage
        self.authenticator = authenticator
        self.reloginSignal = reloginSignal
        self.cookieJar = SharedCookieJar(storage: cookieJar)
        self.pushCredentials = pushCredentials
    }

    /// Attempts to refresh the expired Odoo session for `requestHost`, applying every guardrail.
    ///
    /// Returns `true` when a fresh session cookie was established (the caller may retry the original
    /// request exactly once), or `false` when the caller must give up: no stored account exactly
    /// matches the host, the account is not https (guardrail 1), the account's circuit is open
    /// (guardrail 3), or the single re-auth failed.
    ///
    /// Safe to call concurrently: a per-host single-flight `Task` collapses simultaneous callers into
    /// one authenticate network call for that host (guardrail 4).
    ///
    /// `accountId` (F1, 0930) names the account whose session expired. Two accounts can share one
    /// server; without it the first stored account on the host would be re-authenticated. When given,
    /// only that account is considered — if it does not match the host, the re-auth declines.
    func reauthenticateForHost(_ requestHost: String, accountId: String? = nil) async -> Bool {
        // Guardrail 1: refuse anything that is not an exact stored https host.
        guard let account = await resolveAccountForHost(requestHost, accountId: accountId) else {
            AppLogger.auth.warning("Re-auth: no stored https account matches request host — declining")
            return false
        }

        // Guardrail 3: circuit open (known-bad password) — never re-send it.
        if openCircuits.contains(account.id) {
            AppLogger.auth.warning("Re-auth: circuit open for account \(account.id, privacy: .public) — declining until manual re-login")
            return false
        }

        // Guardrail 4: single-flight per host and account (two same-host accounts are two sessions).
        // Concurrent callers for the same account await the same task.
        let flightKey = "\(requestHost.lowercased())#\(account.id)"
        if let existing = inFlight[flightKey] {
            return await existing.value
        }
        let task = Task<Bool, Never> { await performReauth(account) }
        inFlight[flightKey] = task
        let result = await task.value
        inFlight[flightKey] = nil
        return result
    }

    /// Clears the circuit for `accountId` after a successful manual re-login, re-enabling auto re-auth.
    func onManualReloginSucceeded(accountId: String) {
        openCircuits.remove(accountId)
    }

    // MARK: - Private

    /// Resolves the single stored account whose validated https host exactly matches `requestHost`.
    ///
    /// Enforces guardrail 1: only accounts whose STORED url is `https` are considered, and the bare
    /// host must match exactly (case-insensitive). Returns nil when there is no such account.
    ///
    /// The account snapshot is taken on the main actor: `AccountRepository` reads the main-queue
    /// Core Data `viewContext`, and this actor's executor is not the main thread.
    private func resolveAccountForHost(_ requestHost: String, accountId: String?) async -> OdooAccount? {
        let accounts = await MainActor.run { accountRepository.getAllAccounts() }
            .filter { accountId == nil || $0.id == accountId }
        return accounts.first { account in
            // The account's STORED url must itself be https (not merely https after the
            // ensureHTTPS fallback) — an http-stored account is never a re-auth target.
            guard account.serverUrl.hasPrefix("https://") else { return false }
            guard let host = URL(string: account.fullServerUrl)?.host else { return false }
            return host.caseInsensitiveCompare(requestHost) == .orderedSame
        }
    }

    /// Performs the single re-authentication against the account's own https host with its stored
    /// credentials, and applies the guardrails to the result. Returns true only when a fresh session
    /// was established and the request should be retried.
    private func performReauth(_ account: OdooAccount) async -> Bool {
        guard let password = secureStorage.getPassword(serverUrl: account.fullServerUrl, username: account.username),
              !password.isEmpty else {
            // No stored secret to re-auth with — surface a re-login rather than silently failing.
            AppLogger.auth.warning("Re-auth: no stored credentials for account \(account.id, privacy: .public) — signalling re-login")
            openCircuit(account)
            return false
        }

        // Guardrail 1 (belt and suspenders — resolveAccountForHost already enforced https + exact host).
        let serverUrl = account.fullServerUrl
        guard serverUrl.hasPrefix("https://") else {
            AppLogger.auth.warning("Re-auth: account \(account.id, privacy: .public) server URL is not https — declining")
            return false
        }

        // The sessions this heal replaces (Keychain copy, push credential) — revoked once the heal
        // is committed (demo111 1001, defect 1: they used to be orphaned).
        let storage = secureStorage, push = pushCredentials
        let replaced = await MainActor.run { () -> ReplacedSession in
            ReplacedSession(keychainSessionId: storage.getSessionId(serverUrl: account.fullServerUrl, username: account.username),
                            credential: push.pushCredential(accountId: account.id))
        }

        let result = await authenticator.authenticateIsolated(
            serverUrl: serverUrl,
            database: account.database,
            username: account.username,
            password: password
        )

        switch result {
        case .success(let auth):
            return await commitHealedSession(account, auth: auth, replaced: replaced)
        case .error(_, let type):
            return await handleReauthError(account, type: type)
        }
    }

    /// What a heal replaces: the account's Keychain session copy and its push credential as they
    /// were before the re-auth started.
    private struct ReplacedSession: Sendable {
        let keychainSessionId: String?
        let credential: PushCredential?
        var sessionIds: Set<String> {
            Set([keychainSessionId, credential?.sessionId].compactMap { $0 }.filter { !$0.isEmpty })
        }
    }

    /// Publishes a healed session to the shared jar and the account's Keychain session copy — only
    /// while the account may own its host's jar session (`mayOwnHostSession`). pi 0930 (P1): a heal
    /// answering after the user switched to a same-host sibling, or after the account was removed,
    /// writes nothing and reports failure; its fresh session is revoked best-effort. The check and
    /// the write run in one main-actor step — the executor account switches and logouts run on — so
    /// no switch can land between them.
    ///
    /// demo111 1001 (defect 1): the healed session used to stop there — the page stayed blank and
    /// the next switch logged in again. In the same step it now also replaces the account's push
    /// credential session (unless a switch or login already replaced that credential) and tells the
    /// account's WebView (`accountSessionHealed`). Once committed, the sessions it replaced are
    /// revoked best-effort — never one another account still holds.
    private func commitHealedSession(_ account: OdooAccount, auth: AuthResult.AuthSuccess,
                                     replaced: ReplacedSession) async -> Bool {
        guard let cookie = auth.sessionCookie?.cookie() ?? Self.sessionCookie(auth.sessionId, for: account) else {
            AppLogger.auth.warning("Re-auth: no session returned for account \(account.id, privacy: .public)")
            return false
        }
        let repo = accountRepository, storage = secureStorage, jar = cookieJar, push = pushCredentials
        let revocable = await MainActor.run { () -> Set<String>? in
            guard Self.mayOwnHostSession(account, in: repo) else { return nil }
            jar.storage.setCookie(cookie)
            storage.saveSessionId(serverUrl: account.fullServerUrl, username: account.username, sessionId: cookie.value)
            if let current = push.pushCredential(accountId: account.id), current == replaced.credential,
               current.matches(account),
               let sessionCookie = auth.sessionCookie ?? Self.pushSessionCookie(cookie, for: account) {
                push.savePushCredential(PushCredential(account: account, password: current.password,
                    sessionId: cookie.value, generation: current.generation, sessionCookie: sessionCookie))
            }
            NotificationCenter.default.post(name: .accountSessionHealed, object: nil,
                                            userInfo: ["accountId": account.id, "cookie": cookie])
            return replaced.sessionIds.subtracting([cookie.value])
                .subtracting(Self.sessionIdsHeld(byOtherThan: account, repo: repo, storage: storage, push: push))
        }
        guard let revocable else {
            AppLogger.auth.warning("Re-auth: account \(account.id, privacy: .public) no longer owns its host session — result discarded")
            await authenticator.discardSession(serverUrl: account.fullServerUrl, sessionId: cookie.value)
            return false
        }
        AppLogger.auth.info("Re-auth: session refreshed for account \(account.id, privacy: .public)")
        for sessionId in revocable.sorted() {
            await authenticator.discardSession(serverUrl: account.fullServerUrl, sessionId: sessionId)
        }
        return true
    }

    /// Session ids other stored accounts hold (Keychain copies and push credentials) — never revoked
    /// on this account's behalf.
    @MainActor
    private static func sessionIdsHeld(byOtherThan account: OdooAccount, repo: AccountRepositoryProtocol,
                                       storage: SecureStorageProtocol, push: PushCredentialStorage) -> Set<String> {
        var held = Set<String>()
        for other in repo.getAllAccounts() where other.id != account.id {
            if let sid = storage.getSessionId(serverUrl: other.fullServerUrl, username: other.username) { held.insert(sid) }
            if let sid = push.pushCredential(accountId: other.id)?.sessionId { held.insert(sid) }
        }
        return held
    }

    /// The push-credential form of a healed cookie when the transport returned only the session id.
    private static func pushSessionCookie(_ cookie: HTTPCookie, for account: OdooAccount) -> PushSessionCookie? {
        guard let url = URL(string: "\(account.fullServerUrl)/web/session/authenticate") else { return nil }
        return PushSessionCookie(cookie: cookie, responseURL: url)
    }

    /// Whether `account` may hold its host's session in the shared jar right now: it is still
    /// stored, and no OTHER account on the same host is the active one (that account's session is
    /// the one the jar and the WebView must keep).
    @MainActor
    private static func mayOwnHostSession(_ account: OdooAccount, in repo: AccountRepositoryProtocol) -> Bool {
        guard repo.getAllAccounts().contains(where: { $0.id == account.id }) else { return false }
        if let active = repo.getActiveAccount(), active.id != account.id,
           active.serverHost.caseInsensitiveCompare(account.serverHost) == .orderedSame {
            return false
        }
        return true
    }

    /// A session cookie for `account`'s host when the transport returned only the session id.
    private static func sessionCookie(_ sessionId: String, for account: OdooAccount) -> HTTPCookie? {
        guard !sessionId.isEmpty else { return nil }
        return HTTPCookie(properties: [.name: "session_id", .value: sessionId, .domain: account.serverHost,
                                       .path: "/", .secure: "TRUE"])
    }

    /// pi 0930 (P1): removes a rejected account's session from the shared jar. While another stored
    /// account shares the host, only `session_id` cookies whose value is this account's known
    /// session are removed — the host's cookies are the sibling's too. The host's last account
    /// clears them all, as before.
    @MainActor
    private static func clearStaleSession(of account: OdooAccount, repo: AccountRepositoryProtocol,
                                          storage: SecureStorageProtocol, jar: SharedCookieJar) {
        guard let url = URL(string: account.fullServerUrl), let cookies = jar.storage.cookies(for: url) else { return }
        let sibling = repo.getAllAccounts().contains {
            $0.id != account.id && $0.serverHost.caseInsensitiveCompare(account.serverHost) == .orderedSame
        }
        if sibling {
            let known = Set([storage.getSessionId(serverUrl: account.fullServerUrl, username: account.username)]
                .compactMap { $0 }.filter { !$0.isEmpty })
            cookies.filter { $0.name == "session_id" && known.contains($0.value) }.forEach { jar.storage.deleteCookie($0) }
        } else {
            cookies.forEach { jar.storage.deleteCookie($0) }
        }
    }

    /// Applies guardrail 3 (bad-credential STOP) to a failed re-auth. Returns false in every case.
    private func handleReauthError(_ account: OdooAccount, type: AuthResult.ErrorType) async -> Bool {
        if type == .invalidCredentials {
            // Guardrail 3: the stored password is wrong (changed server-side). Stop immediately, clear
            // the stale session, open the circuit, and surface a re-login. Never re-send the bad password.
            AppLogger.auth.warning("Re-auth: stored credentials rejected for account \(account.id, privacy: .public) — clearing session, signalling re-login")
            let repo = accountRepository, storage = secureStorage, jar = cookieJar
            await MainActor.run { Self.clearStaleSession(of: account, repo: repo, storage: storage, jar: jar) }
            openCircuit(account)
            return false
        }
        // Transient failure (network / server / timeout): decline this attempt; a later trigger retries.
        AppLogger.auth.warning("Re-auth: transient failure for account \(account.id, privacy: .public) (\(String(describing: type), privacy: .public))")
        return false
    }

    /// Opens the circuit for `account` and emits a re-login signal.
    private func openCircuit(_ account: OdooAccount) {
        openCircuits.insert(account.id)
        reloginSignal.requestRelogin(accountId: account.id)
    }
}
