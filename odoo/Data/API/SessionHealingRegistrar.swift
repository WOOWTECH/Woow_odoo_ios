import Foundation

/// The body-inspecting self-heal layer for the authenticated registration JSON-RPC path (iOS parity
/// of Android's WI-3 `SessionReauthInterceptor`).
///
/// It issues the authenticated `callKw`, and on a detected expired session — surfaced as
/// `OdooAPIError.sessionExpired`, which `OdooAPIClient.callKw` throws for both the HTTP-200
/// `SessionExpiredException` envelope and a genuine 401 — it re-authenticates **once** against the
/// account's own https host (via the guardrail'd `SessionReauthenticator`), refreshes the cookie, and
/// replays the request **exactly once**.
///
/// ## One-retry cap (guardrail 2)
/// The retry cap is structural: only the *first* `.sessionExpired` is caught here, and it triggers
/// exactly one re-auth and one replay. If the replay itself still returns `.sessionExpired`, that
/// error propagates unchanged — there is no second re-auth and no loop. All of the host-safety,
/// bad-credential-stop, single-flight, and no-credential-logging guardrails live in
/// `SessionReauthenticator`; this type owns only the detect → heal → replay-once orchestration.
struct SessionHealingRegistrar {

    private let apiClient: OdooAPIClient
    private let reauthenticator: SessionReauthenticator

    init(
        apiClient: OdooAPIClient = OdooAPIClient(),
        reauthenticator: SessionReauthenticator = SessionReauthenticator.shared
    ) {
        self.apiClient = apiClient
        self.reauthenticator = reauthenticator
    }

    /// Calls a `woow.fcm.device` model method for `account` with one-shot session self-heal.
    ///
    /// On a session-expired response it re-authenticates once against the account's exact stored
    /// https host and retries the call once. Throws `OdooAPIError.sessionExpired` when self-heal is
    /// impossible (unsafe/mismatched host, no/invalid stored credentials) or when the single replay
    /// still reports an expired session — so the caller can treat it as a rejected registration and
    /// surface a re-login. Any other error from the underlying call propagates unchanged.
    func callKwHealing(
        account: OdooAccount,
        model: String,
        method: String,
        args: [Any] = [],
        kwargs: [String: Any] = [:]
    ) async throws -> Any? {
        do {
            return try await apiClient.callKw(
                serverUrl: account.fullServerUrl,
                model: model,
                method: method,
                args: args,
                kwargs: kwargs
            )
        } catch OdooAPIError.sessionExpired {
            // ONE retry (guardrail 2): a single re-auth against the account's exact https host.
            let healed = await reauthenticator.reauthenticateForHost(account.serverHost)
            guard healed else { throw OdooAPIError.sessionExpired }

            // Replay EXACTLY once. A second `.sessionExpired` from this call propagates — never a
            // second re-auth, never a loop.
            return try await apiClient.callKw(
                serverUrl: account.fullServerUrl,
                model: model,
                method: method,
                args: args,
                kwargs: kwargs
            )
        }
    }
}
