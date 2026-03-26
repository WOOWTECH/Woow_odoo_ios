import Foundation

/// Main screen ViewModel — manages active account and deep link consumption.
/// Ported from Android: MainViewModel.kt
@MainActor
final class MainViewModel: ObservableObject {

    @Published var activeAccount: OdooAccount?
    @Published var sessionId: String?

    private let accountRepository: AccountRepositoryProtocol
    private let deepLinkManager: DeepLinkManager

    init(
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        deepLinkManager: DeepLinkManager = .shared
    ) {
        self.accountRepository = accountRepository
        self.deepLinkManager = deepLinkManager
        loadActiveAccount()
    }

    func loadActiveAccount() {
        activeAccount = accountRepository.getActiveAccount()
        if let account = activeAccount {
            sessionId = accountRepository.getSessionId(for: account.fullServerUrl)
        }
    }

    /// Consumes and returns a pending deep link URL from a notification tap.
    func consumePendingDeepLink() -> String? {
        deepLinkManager.consume()
    }

    func refresh() {
        loadActiveAccount()
    }
}
