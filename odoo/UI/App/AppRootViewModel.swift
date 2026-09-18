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

    /// Handles a session-expired signal (e.g., the WebView detected a redirect to `/web/login`).
    ///
    /// Self-heal first (AC7.b, WI-3 parity): instead of unconditionally bouncing to login, it attempts
    /// one silent, guardrail'd re-auth of the active account's expired session and STAYS
    /// `.authenticated` when that succeeds — so token updates keep working and the user is not forced
    /// to log in again. It transitions to `.login` only when re-auth is impossible (no active/https
    /// account, credentials rejected, unsafe host — every guardrail is enforced inside
    /// `SessionReauthenticator`; see `attemptSelfHealOrLogin`).
    /// 使用者主動要新增一個 Odoo 實例時呼叫。
    ///
    /// **刻意不走 `onSessionExpired()`。** 那個事件的語意是「目前這個 session 失效了」，
    /// 它會先嘗試靜默自癒（`attemptSelfHealOrLogin`）——而在「新增帳號」的情境下，
    /// 目前的 active account 通常是**健康的**，自癒因此會成功並把 `launchState` 設回
    /// `.authenticated`，使用者還沒看到登入表單就被彈回原本的 WebView，
    /// 永遠新增不了第二個實例。
    ///
    /// 這裡無條件進入 `.login`：新增實例本來就不是 session 失效，不該做任何 re-auth。
    /// 呼叫端另外把 `isAddingAccount` 設為 true，使 `LoginView` 從空白的伺服器資訊
    /// 步驟開始，而不是預填現有帳號。
    func beginAddAccount() {
        launchState = .login
    }

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
