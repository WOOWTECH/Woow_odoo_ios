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
    private let registrar: PushDeviceRegistrar

    init(
        secureStorage: SecureStorage = .shared,
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        apiClient: OdooAPIClient = OdooAPIClient(),
        reauthenticator: SessionReauthenticator = SessionReauthenticator.shared,
        brand: AppBrand.Code = AppBrand.current.code,
        pushCredentials: PushCredentialStorage = SecureStorage.shared
    ) {
        self.secureStorage = secureStorage
        self.accountRepository = accountRepository
        self.registrar = PushDeviceRegistrar(brand: brand, api: apiClient, accounts: accountRepository,
            credentials: pushCredentials, legacyReauthenticator: reauthenticator)
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
                // Registrar atomically validates identity/generation and commits status + tenant.
                _ = try await registrar.register(account: account, token: token, deviceName: deviceName())
            } catch {
                AppLogger.push.error("Push registration failed: \(PushDeviceRegistrar.status(for: error).rawValue, privacy: .public)")
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
                try await registrar.unregister(account: account, token: oldToken)
            } catch {
                AppLogger.push.error("Rotated push token cleanup failed: \(PushDeviceRegistrar.status(for: error).rawValue, privacy: .public)")
            }
        }
    }

    /// Unregisters the FCM token from the Odoo server for the given account.
    /// Called during logout to stop push notifications for the logged-out account.
    /// Best-effort: errors are logged but never block logout. (G9)
    func unregisterToken(for serverUrl: String) async {
        guard let token = getToken() else { return }

        if registrar.brand == .woowtech {
            do { try await registrar.unregisterLegacyURL(serverUrl, token: token) }
            catch { AppLogger.push.error("Legacy push cleanup failed") }
            return
        }
        // A URL-only caller cannot select an arbitrary same-host database/account.
        let matches = accountRepository.getAllAccounts().filter { $0.fullServerUrl == serverUrl.ensureHTTPS }
        guard matches.count == 1, let account = matches.first else {
            AppLogger.push.warning("Push unregister refused: ambiguous or missing account")
            return
        }
        do {
            try await registrar.unregister(account: account, token: token)
        } catch {
            AppLogger.push.error("Push cleanup failed: \(PushDeviceRegistrar.status(for: error).rawValue, privacy: .public)")
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
