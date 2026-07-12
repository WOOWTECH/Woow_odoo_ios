import Combine
import Foundation

/// Main screen ViewModel — manages the active account and account-bound deep link.
/// Ported from Android: MainViewModel.kt
///
/// Observes `DeepLinkManager`: when a notification tap switches the active account and
/// stores a bound deep link, this reloads the (now switched) active account and surfaces the
/// deep link **only if it is bound to that account** — never to a different tenant. The link
/// is consumed later by the WebView after a load-gated apply, not here.
@MainActor
final class MainViewModel: ObservableObject {

    @Published var activeAccount: OdooAccount?
    @Published var sessionId: String?
    /// The pending deep link for the active account, or nil. Passed to `OdooWebView`, which
    /// applies it once the target page finishes loading.
    @Published var pendingDeepLink: String?

    private let accountRepository: AccountRepositoryProtocol
    private let deepLinkManager: DeepLinkManager
    private var cancellables = Set<AnyCancellable>()

    init(
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        deepLinkManager: DeepLinkManager = .shared
    ) {
        self.accountRepository = accountRepository
        self.deepLinkManager = deepLinkManager
        loadActiveAccount()

        // A notification tap flips the active account (in AppDelegate) and then sets the
        // pending link. Reacting here reloads the switched account and re-derives the bound
        // link so the WebView re-renders onto the correct tenant.
        deepLinkManager.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.loadActiveAccount() }
            .store(in: &cancellables)
    }

    func loadActiveAccount() {
        activeAccount = accountRepository.getActiveAccount()
        if let account = activeAccount {
            sessionId = accountRepository.getSessionId(for: account.fullServerUrl)
        } else {
            sessionId = nil
        }
        updatePendingDeepLink()
    }

    /// Recomputes the exposed deep link so it only ever targets the active account.
    private func updatePendingDeepLink() {
        guard let account = activeAccount, let pending = deepLinkManager.pending else {
            pendingDeepLink = nil
            return
        }
        // Unbound (legacy single-account) links may apply to whoever is active.
        if pending.accountId.isEmpty || pending.accountId == account.id {
            pendingDeepLink = pending.url
        } else {
            pendingDeepLink = nil
        }
    }

    /// Consumes and returns a pending deep link URL from a notification tap.
    /// Retained for the legacy/back-compat path and existing tests.
    func consumePendingDeepLink() -> String? {
        deepLinkManager.consume()
    }

    func refresh() {
        loadActiveAccount()
    }
}
