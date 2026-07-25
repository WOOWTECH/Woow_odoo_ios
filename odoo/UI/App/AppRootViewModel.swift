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

    private let reauthenticator: SessionReauthenticator

    /// Creates the root ViewModel.
    /// - Parameters:
    ///   - accountRepository: Repository to query for the active account.
    ///   - pushTokenRepository: Repository used to (re-)register the FCM token after login.
    ///   - reauthenticator: Guardrail'd engine used to silently re-auth an expired session before
    ///     bouncing the user to login (WI-3 parity, AC7.b).
    init(
        accountRepository: AccountRepositoryProtocol = AccountRepository(),
        pushTokenRepository: PushTokenRepositoryProtocol = PushTokenRepository(),
        reauthenticator: SessionReauthenticator = SessionReauthenticator.shared
    ) {
        self.accountRepository = accountRepository
        self.pushTokenRepository = pushTokenRepository
        self.reauthenticator = reauthenticator
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

    /// Handles a session-expired signal (e.g., the WebView detected a redirect to `/web/login`).
    ///
    /// Self-heal first (AC7.b, WI-3 parity): instead of unconditionally bouncing to login, it attempts
    /// one silent, guardrail'd re-auth of the active account's expired session and STAYS
    /// `.authenticated` when that succeeds — so token updates keep working and the user is not forced
    /// to log in again. It transitions to `.login` only when re-auth is impossible (no active/https
    /// account, credentials rejected, unsafe host — every guardrail is enforced inside
    /// `SessionReauthenticator`; see `attemptSelfHealOrLogin`).
    func onSessionExpired() {
        Task { await attemptSelfHealOrLogin() }
    }

    /// The awaitable core of `onSessionExpired`, exposed for deterministic unit testing. Attempts a
    /// single silent re-auth of the active account and sets `launchState` to `.authenticated` on
    /// success, `.login` otherwise. Returns the resulting state.
    @discardableResult
    func attemptSelfHealOrLogin() async -> LaunchState {
        guard let account = accountRepository.getActiveAccount(),
              await reauthenticator.reauthenticateForHost(account.serverHost) else {
            launchState = .login
            return .login
        }
        launchState = .authenticated
        return .authenticated
    }
}
