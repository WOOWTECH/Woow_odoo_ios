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

    init(
        secureStorage: SecureStorage = .shared,
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        apiClient: OdooAPIClient = OdooAPIClient()
    ) {
        self.secureStorage = secureStorage
        self.accountRepository = accountRepository
        self.apiClient = apiClient
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
                _ = try await apiClient.callKw(
                    serverUrl: account.fullServerUrl,
                    model: "woow.fcm.device",
                    method: "register_device",
                    args: [],
                    kwargs: [
                        "fcm_token": token,
                        "device_name": deviceName(),
                        "platform": "ios"
                    ]
                )
            } catch {
                AppLogger.push.error("Failed to register token with \(account.serverUrl): \(error.localizedDescription, privacy: .public)")
            }
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
