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
    ///
    /// When an account is restored (cold start), this also fires the token-registration
    /// reconcile (AC8.b) so a token Firebase delivered BEFORE any account existed — the
    /// iOS token-arrives-before-account race — is registered now that an account is present.
    func checkSession() {
        let activeAccount = accountRepository.getActiveAccount()
        if activeAccount != nil {
            launchState = .authenticated
            reconcileTokenRegistration()
        } else {
            launchState = .login
        }
    }

    /// Transitions to the authenticated state after a successful login and reconciles
    /// the token registration (covers account-before-token: Firebase may have delivered
    /// the token before this account was saved).
    func onLoginSuccess() {
        launchState = .authenticated
        reconcileTokenRegistration()
    }

    /// Upserts the current FCM token for every logged-in account.
    ///
    /// Fires on the account-restored (cold-start) and login events, in addition to
    /// `didReceiveRegistrationToken`, so a token that arrived before any account existed
    /// is registered as soon as an account appears (AC8.b). Relies on the server-side
    /// upsert early-return, so a redundant re-post of an already-current `(token, user)`
    /// pair is a cheap no-op — the client keeps NO persisted diff-set, NO tri-state result,
    /// and runs NO full reconcile against a canonical endpoint (AC8.c).
    private func reconcileTokenRegistration() {
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
