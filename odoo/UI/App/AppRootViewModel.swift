import Foundation

/// Represents the app's launch state as determined by checking for an active account.
/// Used by `AppRootView` to decide which screen to show on startup.
enum LaunchState {
    /// Checking Core Data for an active account.
    case loading
    /// No active account found -- show the login screen.
    case login
    /// Active account found -- proceed to auth gate and main screen.
    case authenticated
}

/// Manages the root navigation state of the app by checking whether a saved
/// account exists in Core Data. This replaces the previous `@State isLoggedIn: Bool`
/// approach, enabling unit-testable launch state transitions without a SwiftUI View.
@MainActor
final class AppRootViewModel: ObservableObject {

    @Published private(set) var launchState: LaunchState = .loading

    private let accountRepository: AccountRepositoryProtocol

    private let pushTokenRepository: PushTokenRepositoryProtocol

    /// Creates the root ViewModel.
    /// - Parameters:
    ///   - accountRepository: Repository to query for the active account.
    ///   - pushTokenRepository: Repository used to (re-)register the FCM token after login.
    init(
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        pushTokenRepository: PushTokenRepositoryProtocol = PushTokenRepository()
    ) {
        self.accountRepository = accountRepository
        self.pushTokenRepository = pushTokenRepository
    }

    /// Checks Core Data for an active account and transitions launch state accordingly.
    /// Called once from `.task` when `AppRootView` appears.
    func checkSession() {
        let activeAccount = accountRepository.getActiveAccount()
        launchState = (activeAccount != nil) ? .authenticated : .login
    }

    /// Transitions to the authenticated state after a successful login.
    ///
    /// Also re-registers the stored FCM token with all accounts. This is
    /// required because Firebase can deliver the FCM token at launch — BEFORE
    /// this account is saved — in which case `didReceiveRegistrationToken`
    /// registers it to zero accounts and nothing else retries. That path covers
    /// account-before-token; this covers token-before-account.
    func onLoginSuccess() {
        launchState = .authenticated
        Task { [pushTokenRepository] in
            if let token = pushTokenRepository.getToken() {
                await pushTokenRepository.registerTokenWithAllAccounts(token)
            }
        }
    }

    /// Transitions back to the login state when the session expires
    /// (e.g., the WebView detects a redirect to `/web/login`).
    func onSessionExpired() {
        launchState = .login
    }
}
