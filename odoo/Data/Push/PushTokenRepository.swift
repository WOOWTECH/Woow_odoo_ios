import Foundation
import UIKit

/// Manages FCM token registration with Odoo servers.
/// Ported from Android: FcmTokenRepository.kt
protocol PushTokenRepositoryProtocol {
    func saveToken(_ token: String)
    func getToken() -> String?
    func registerTokenWithAllAccounts(_ token: String) async
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

    /// Registers FCM token with all active Odoo accounts.
    /// Posts to /woow_fcm_push/register with platform: "ios".
    func registerTokenWithAllAccounts(_ token: String) async {
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
                #if DEBUG
                print("[PushTokenRepository] Failed to register token with \(account.serverUrl): \(error)")
                #endif
            }
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
