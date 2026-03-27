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

    func logout() async {
        await accountRepository.logout(accountId: nil)
        loadAccounts()
    }

    func removeAccount(id: String) async {
        await accountRepository.removeAccount(id: id)
        loadAccounts()
    }
}
