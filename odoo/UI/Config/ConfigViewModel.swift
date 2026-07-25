import Foundation

/// Config screen ViewModel — account management.
/// Ported from Android: ConfigViewModel.kt
@MainActor
final class ConfigViewModel: ObservableObject {

    @Published var accounts: [OdooAccount] = []
    @Published var activeAccount: OdooAccount?

    private let accountRepository: AccountRepositoryProtocol
    private let pushTokenRepository: PushTokenRepositoryProtocol

    init(
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        pushTokenRepository: PushTokenRepositoryProtocol = PushTokenRepository()
    ) {
        self.accountRepository = accountRepository
        self.pushTokenRepository = pushTokenRepository
        loadAccounts()
    }

    func loadAccounts() {
        accounts = accountRepository.getAllAccounts()
        activeAccount = accountRepository.getActiveAccount()
    }

    func switchAccount(id: String) async -> Bool {
        let result = await accountRepository.switchAccount(id: id)
        if result {
            loadAccounts()
            // Account-switch is an "account-available" event (AC8.b): upsert the current
            // token for all accounts so the newly-active account is covered. Redundant for
            // already-registered accounts thanks to the server upsert early-return.
            if let token = pushTokenRepository.getToken() {
                await pushTokenRepository.registerTokenWithAllAccounts(token)
            }
        }
        return result
    }

    /// Logs out the CURRENT (active) account. Returns whether the app should STAY authenticated:
    /// `true` when another account was promoted (multi-account fallback), `false` when no accounts
    /// remain and the caller should return to the login screen.
    @discardableResult
    func logout() async -> Bool {
        await accountRepository.logout(accountId: nil)
        loadAccounts()
        return accountRepository.getActiveAccount() != nil
    }

    func removeAccount(id: String) async {
        await accountRepository.removeAccount(id: id)
        loadAccounts()
    }
}
