import Foundation
import UIKit

/// Serializes token-registration passes and drops a redundant pass when an
/// identical token is already being registered. Both `didReceiveRegistrationToken`
/// and `onLoginSuccess` can fire for the SAME token within milliseconds at launch;
/// without this guard they race the same N `register_device` calls twice (MA-1).
actor TokenRegistrationGate {
    static let shared = TokenRegistrationGate()

    private var inFlightToken: String?

    /// Runs `body` unless an identical `token` pass is already in flight.
    /// Returns `false` (work skipped) when deduplicated, `true` when it ran.
    @discardableResult
    func run(token: String, _ body: @Sendable () async -> Void) async -> Bool {
        if inFlightToken == token { return false }
        inFlightToken = token
        defer { inFlightToken = nil }
        await body()
        return true
    }
}

/// Manages FCM token registration with Odoo servers.
/// Ported from Android: FcmTokenRepository.kt
protocol PushTokenRepositoryProtocol {
    func saveToken(_ token: String)
    func getToken() -> String?
    func registerTokenWithAllAccounts(_ token: String) async
    func unregisterToken(for serverUrl: String) async
}

final class PushTokenRepository: PushTokenRepositoryProtocol {

    private let secureStorage: SecureStorage
    private let accountRepository: AccountRepositoryProtocol
    private let apiClient: OdooAPIClient
    private let healingRegistrar: SessionHealingRegistrar

    init(
        secureStorage: SecureStorage = .shared,
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        apiClient: OdooAPIClient = OdooAPIClient(),
        reauthenticator: SessionReauthenticator = SessionReauthenticator.shared
    ) {
        self.secureStorage = secureStorage
        self.accountRepository = accountRepository
        self.apiClient = apiClient
        // The register call self-heals an expired session (WI-3 parity): re-auth once against the
        // account's own https host and retry once, so an expired session never silently stops token
        // updates. Shares the same api client so the refreshed cookie applies to the retry.
        self.healingRegistrar = SessionHealingRegistrar(
            apiClient: apiClient,
            reauthenticator: reauthenticator
        )
    }

    func saveToken(_ token: String) {
        secureStorage.saveFcmToken(token)
    }

    func getToken() -> String? {
        secureStorage.getFcmToken()
    }

    /// Registers the FCM token with all active Odoo accounts (register_device, platform: "ios").
    ///
    /// If a DIFFERENT token was previously stored (Firebase rotated it), the OLD token is
    /// first unregistered from every account's server so no "ghost" device row can keep an
    /// old company able to push across the N Odoo DBs (MA-1 / FR-MA-4).
    ///
    /// Deduplicated via `TokenRegistrationGate`: concurrent calls for the same token
    /// (login + Firebase callback at launch) run the network work once.
    func registerTokenWithAllAccounts(_ token: String) async {
        await TokenRegistrationGate.shared.run(token: token) { [self] in
            await performRegistration(token)
        }
    }

    private func performRegistration(_ token: String) async {
        let oldToken = getToken()
        if let oldToken, oldToken != token {
            await unregisterOldTokenFromAllAccounts(oldToken)
        }

        saveToken(token)

        let accounts = accountRepository.getAllAccounts()
        for account in accounts {
            do {
                // Routed through the self-heal registrar (WI-3 parity): a session-expired response
                // triggers exactly one re-auth against the account's own https host + one retry.
                let response = try await healingRegistrar.callKwHealing(
                    account: account,
                    model: "woow.fcm.device",
                    method: "register_device",
                    args: [],
                    kwargs: [
                        "fcm_token": token,
                        "device_name": deviceName(),
                        "platform": "ios"
                    ]
                )
                // Persist the server-issued tenant id so future push notifications for
                // this server can be routed to this account. Backward-compatible: an
                // older plugin that returns no tenant id leaves the field untouched.
                if let tenantId = Self.parseTenantId(from: response) {
                    accountRepository.setTenantId(tenantId, forServerUrl: account.serverUrl)
                }
            } catch {
                AppLogger.push.error("Failed to register token with \(account.serverUrl): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Extracts the opaque tenant id from a `register_device` response.
    ///
    /// Accepts the value under either `tenant_id` or `odoo_tenant_id`, coercing numeric
    /// ids to their string form. Returns `nil` for any other shape (older plugin, boolean
    /// `true`, etc.) so registration stays backward-compatible.
    static func parseTenantId(from response: Any?) -> String? {
        guard let dict = response as? [String: Any] else { return nil }
        let raw = dict["tenant_id"] ?? dict["odoo_tenant_id"]
        switch raw {
        case let value as String where !value.isEmpty:
            return value
        case let value as Int:
            return String(value)
        case let value as Int64:
            return String(value)
        default:
            return nil
        }
    }

    /// Unregisters a specific (old) FCM token from every account's server on rotation.
    /// Best-effort per account — a failure is logged and never blocks the new token's
    /// registration. Uses `fullServerUrl` to match the register call form (MA-1).
    private func unregisterOldTokenFromAllAccounts(_ oldToken: String) async {
        for account in accountRepository.getAllAccounts() {
            do {
                _ = try await apiClient.callKw(
                    serverUrl: account.fullServerUrl,
                    model: "woow.fcm.device",
                    method: "unregister_device",
                    args: [],
                    kwargs: ["fcm_token": oldToken]
                )
            } catch {
                AppLogger.push.error("Failed to unregister rotated token from \(account.serverUrl): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Unregisters the FCM token from the Odoo server for the given account.
    /// Called during logout to stop push notifications for the logged-out account.
    /// Best-effort: errors are logged but never block logout. (G9)
    func unregisterToken(for serverUrl: String) async {
        guard let token = getToken() else { return }

        do {
            _ = try await apiClient.callKw(
                serverUrl: serverUrl,
                model: "woow.fcm.device",
                method: "unregister_device",
                args: [],
                kwargs: ["fcm_token": token]
            )
            AppLogger.push.info("Token unregistered from \(serverUrl)")
        } catch {
            AppLogger.push.error("Failed to unregister token from \(serverUrl): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deviceName() -> String {
        #if targetEnvironment(simulator)
        return "iOS Simulator"
        #else
        return UIDevice.current.name
        #endif
    }
}
