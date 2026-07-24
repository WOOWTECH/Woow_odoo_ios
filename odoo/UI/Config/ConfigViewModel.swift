import Foundation

/// Config screen ViewModel — account management.
/// Ported from Android: ConfigViewModel.kt
@MainActor
final class ConfigViewModel: ObservableObject {

    @Published var accounts: [OdooAccount] = []
    @Published var activeAccount: OdooAccount?

    private let accountRepository: AccountRepositoryProtocol

    init(accountRepository: AccountRepositoryProtocol = AccountRepository()) {
        self.accountRepository = accountRepository
        loadAccounts()
    }

    func loadAccounts() {
        accounts = accountRepository.getAllAccounts()
        activeAccount = accountRepository.getActiveAccount()
    }

    func switchAccount(id: String) async -> Bool {
        let result = await accountRepository.switchAccount(id: id)
        if result { loadAccounts() }
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
