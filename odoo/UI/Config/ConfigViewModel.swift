import Foundation

/// Config screen ViewModel — account management.
/// Ported from Android: ConfigViewModel.kt
@MainActor
final class ConfigViewModel: ObservableObject {

    @Published var accounts: [OdooAccount] = []
    @Published var activeAccount: OdooAccount?
    /// pi 1001e: set when a switch was refused because the target must sign in again (no password
    /// and no valid stored session). The view offers to open that account's sign-in.
    @Published var signInRequiredAccount: OdooAccount?

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
        let requested = ReloginRequestRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: ReloginSignal.didRequestRelogin, object: nil, queue: nil
        ) { note in requested.record(note.userInfo?["accountId"] as? String) }
        let result = await accountRepository.switchAccount(id: id)
        NotificationCenter.default.removeObserver(observer)
        if !result, requested.contains(id) {
            signInRequiredAccount = accounts.first { $0.id == id }
        }
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

/// Collects relogin requests posted while one switch runs (thread-safe; the notification may be
/// delivered off the main thread).
private final class ReloginRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    func record(_ id: String?) { guard let id else { return }; lock.lock(); ids.insert(id); lock.unlock() }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
}
