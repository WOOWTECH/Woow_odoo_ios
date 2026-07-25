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
/// production this is satisfied by `OdooAPIClient`, which enforces https-only at the transport level
/// and shares the `HTTPCookieStorage` the registration calls use (so a refreshed cookie is picked up
/// by the retried request).
protocol SessionAuthenticating: Sendable {
    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult
    func clearCookies(for serverUrl: String) async
}

extension OdooAPIClient: SessionAuthenticating {}

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
///    server-side) it STOPS, clears the stale session cookie, opens the account's circuit so the
///    known-bad password is never re-sent, and raises a re-login signal.
/// 4. **Single-flight.** A per-host in-flight `Task` (this is an `actor`) collapses concurrent
///    session-expiry responses for the same host into exactly one authenticate network call.
/// 5. **NEVER log credentials/cookies.** Nothing here logs a password, cookie, or session token.
actor SessionReauthenticator {

    static let shared = SessionReauthenticator()

    private let accountRepository: AccountRepositoryProtocol
    private let secureStorage: SecureStorageProtocol
    private let authenticator: SessionAuthenticating
    private let reloginSignal: ReloginSignaling

    /// Per-host single-flight tasks so concurrent expiries on the same host cause exactly one re-auth.
    private var inFlight: [String: Task<Bool, Never>] = [:]

    /// Accounts whose stored password was rejected — auto re-auth disabled until a manual re-login,
    /// so the known-bad password is never re-sent (guardrail 3, "no loop").
    private var openCircuits: Set<String> = []

    init(
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        secureStorage: SecureStorageProtocol = SecureStorage.shared,
        authenticator: SessionAuthenticating = OdooAPIClient(),
        reloginSignal: ReloginSignaling = ReloginSignal.shared
    ) {
        self.accountRepository = accountRepository
        self.secureStorage = secureStorage
        self.authenticator = authenticator
        self.reloginSignal = reloginSignal
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
    func reauthenticateForHost(_ requestHost: String) async -> Bool {
        // Guardrail 1: refuse anything that is not an exact stored https host.
        guard let account = resolveAccountForHost(requestHost) else {
            AppLogger.auth.warning("Re-auth: no stored https account matches request host — declining")
            return false
        }

        // Guardrail 3: circuit open (known-bad password) — never re-send it.
        if openCircuits.contains(account.id) {
            AppLogger.auth.warning("Re-auth: circuit open for account \(account.id, privacy: .public) — declining until manual re-login")
            return false
        }

        // Guardrail 4: single-flight per host. Concurrent callers await the same task.
        if let existing = inFlight[requestHost] {
            return await existing.value
        }
        let task = Task<Bool, Never> { await performReauth(account) }
        inFlight[requestHost] = task
        let result = await task.value
        inFlight[requestHost] = nil
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
    private func resolveAccountForHost(_ requestHost: String) -> OdooAccount? {
        accountRepository.getAllAccounts().first { account in
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

        let result = await authenticator.authenticate(
            serverUrl: serverUrl,
            database: account.database,
            username: account.username,
            password: password
        )

        switch result {
        case .success:
            AppLogger.auth.info("Re-auth: session refreshed for account \(account.id, privacy: .public)")
            return true
        case .error(_, let type):
            return await handleReauthError(account, type: type)
        }
    }

    /// Applies guardrail 3 (bad-credential STOP) to a failed re-auth. Returns false in every case.
    private func handleReauthError(_ account: OdooAccount, type: AuthResult.ErrorType) async -> Bool {
        if type == .invalidCredentials {
            // Guardrail 3: the stored password is wrong (changed server-side). Stop immediately, clear
            // the stale session, open the circuit, and surface a re-login. Never re-send the bad password.
            AppLogger.auth.warning("Re-auth: stored credentials rejected for account \(account.id, privacy: .public) — clearing session, signalling re-login")
            await authenticator.clearCookies(for: account.fullServerUrl)
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
