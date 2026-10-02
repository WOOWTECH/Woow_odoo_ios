import Foundation

/// Login flow ViewModel — manages 2-step login (server info → credentials).
/// On init, attempts to pre-fill credentials from the last active account
/// (Core Data + Keychain) so that returning users after session expiry
/// can log in with a single tap instead of re-entering all fields.
/// Ported from Android: LoginViewModel.kt
@MainActor
final class LoginViewModel: ObservableObject {

    enum Step {
        case serverInfo
        case credentials
    }

    @Published var step: Step = .serverInfo
    @Published var serverUrl: String = ""
    @Published var database: String = ""
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var rememberMe: Bool = true
    @Published var isLoading: Bool = false
    @Published var error: String?

    private let repository: AccountRepositoryProtocol
    private let secureStorage: any SecureStorageProtocol
    /// Source of every user-facing message; tests pass a `<lang>.lproj` bundle.
    private let localizationBundle: Bundle

    /// Creates a LoginViewModel.
    /// - Parameter addingAccount: When true, the server info step is always shown
    ///   so the user can enter credentials for a new, distinct account. When false
    ///   (the default), existing active-account credentials are pre-filled for a
    ///   faster session re-authentication after expiry.
    /// - Parameter localizationBundle: Bundle that localizes error messages (default `.main`).
    init(
        addingAccount: Bool = false,
        repository: AccountRepositoryProtocol = AccountRepository(),
        secureStorage: any SecureStorageProtocol = SecureStorage.shared,
        localizationBundle: Bundle = .main
    ) {
        self.repository = repository
        self.secureStorage = secureStorage
        self.localizationBundle = localizationBundle
        if !addingAccount {
            prefillFromActiveAccount()
        }
    }

    /// Pre-fills login fields from the last active account if one exists.
    /// Reads server URL, database, and username from Core Data, and the
    /// saved password from Keychain. Skips the server info step so the user
    /// lands directly on the credentials screen for a quick re-login.
    private func prefillFromActiveAccount() {
        guard let account = repository.getActiveAccount() else { return }
        serverUrl = account.serverUrl
        database = account.database
        username = account.username
        if let savedPassword = secureStorage.getPassword(accountId: account.id) {
            password = savedPassword
        }
        step = .credentials
    }

    // MARK: - Navigation

    /// Validates server info and moves to credentials step.
    func goToNextStep() {
        error = nil

        let trimmed = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = String(localized: "error_server_url_required", bundle: localizationBundle)
            return
        }

        guard !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = String(localized: "error_database_required", bundle: localizationBundle)
            return
        }

        switch ServerUrlInput.classify(serverUrl) {
        case .httpsRequired:
            error = String(localized: "error_https_required", bundle: localizationBundle)
            return
        case .invalid:
            error = String(localized: "error_invalid_server_url", bundle: localizationBundle)
            return
        case .valid(let normalized):
            // Write back so the credentials summary and login() see one scheme.
            serverUrl = normalized
        }

        step = .credentials
    }

    func goBack() {
        error = nil
        step = .serverInfo
    }

    // MARK: - Login

    /// Authenticates with Odoo server.
    func login(onSuccess: @escaping () -> Void) {
        error = nil

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPass = password.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedUser.isEmpty else {
            error = String(localized: "error_username_required", bundle: localizationBundle)
            return
        }
        guard !trimmedPass.isEmpty else {
            error = String(localized: "error_password_required", bundle: localizationBundle)
            return
        }

        isLoading = true

        Task {
            let result = await repository.authenticate(
                serverUrl: serverUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                database: database.trimmingCharacters(in: .whitespacesAndNewlines),
                username: trimmedUser,
                password: trimmedPass
            )

            isLoading = false

            switch result {
            case .success:
                onSuccess()
            case .error(let message, let errorType):
                error = mapError(message: message, type: errorType)
            }
        }
    }

    // MARK: - Keyboard (Return key + keeping the action button visible)

    /// Focusable login fields, in keyboard order.
    enum Field: Hashable {
        case serverUrl, database, username, password
    }

    /// The step's action button, used as the ScrollView anchor that must stay above the keyboard.
    enum ActionButton: Hashable {
        case next, login
    }

    /// Which action button to scroll into view while `field` is focused. On the credentials step
    /// the software keyboard otherwise covers the Login button (live run 2026-09-27: the first
    /// Login tap landed on the keyboard).
    static func actionButton(revealedFor field: Field) -> ActionButton {
        switch field {
        case .serverUrl, .database: return .next
        case .username, .password: return .login
        }
    }

    /// Handles Return in `field` and returns the field to focus next (`nil` dismisses the keyboard).
    ///
    /// Return in the password field performs exactly the Login button's action — `login(onSuccess:)`
    /// with its validation, so empty fields never submit. Return in the database field is the Next
    /// button's `goToNextStep()`.
    func handleReturnKey(in field: Field, onLoginSuccess: @escaping () -> Void) -> Field? {
        switch field {
        case .serverUrl:
            return .database
        case .database:
            goToNextStep()
            return step == .credentials ? .username : nil
        case .username:
            return .password
        case .password:
            login(onSuccess: onLoginSuccess)
            return nil
        }
    }

    func clearError() {
        error = nil
    }

    // MARK: - Error Mapping (same as Android)

    private func mapError(message: String, type: AuthResult.ErrorType) -> String {
        switch type {
        case .networkError: return String(localized: "error_network", bundle: localizationBundle)
        case .invalidUrl: return String(localized: "error_invalid_url", bundle: localizationBundle)
        case .databaseNotFound: return String(localized: "error_database_not_found", bundle: localizationBundle)
        case .invalidCredentials: return String(localized: "error_invalid_credentials", bundle: localizationBundle)
        case .sessionExpired: return String(localized: "error_session_expired", bundle: localizationBundle)
        case .httpsRequired: return String(localized: "error_https_required", bundle: localizationBundle)
        case .serverError: return String(format: String(localized: "error_server_%@", bundle: localizationBundle), message)
        case .serverHTTPStatus(let code):
            return String(format: String(localized: "error_server_http_%lld", bundle: localizationBundle), code)
        case .unexpectedResponse: return String(localized: "error_unexpected_response", bundle: localizationBundle)
        case .unknown: return message
        }
    }

    /// Display URL with https:// prefix for user.
    var displayUrl: String {
        let trimmed = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        return trimmed.ensureHTTPS
    }
}
