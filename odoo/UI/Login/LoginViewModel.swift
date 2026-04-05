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

    init(
        repository: AccountRepositoryProtocol = AccountRepository(),
        secureStorage: any SecureStorageProtocol = SecureStorage.shared
    ) {
        self.repository = repository
        self.secureStorage = secureStorage
        prefillFromActiveAccount()
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
        if let savedPassword = secureStorage.getPassword(serverUrl: account.fullServerUrl, username: account.username) {
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
            error = "Server URL is required"
            return
        }

        guard !database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Database name is required"
            return
        }

        // Reject http:// explicitly
        if trimmed.lowercased().hasPrefix("http://") {
            error = "HTTPS connection required"
            return
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
            error = "Username is required"
            return
        }
        guard !trimmedPass.isEmpty else {
            error = "Password is required"
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

    func clearError() {
        error = nil
    }

    // MARK: - Error Mapping (same as Android)

    private func mapError(message: String, type: AuthResult.ErrorType) -> String {
        switch type {
        case .networkError: return "Unable to connect to server"
        case .invalidUrl: return "Invalid server URL"
        case .databaseNotFound: return "Database not found"
        case .invalidCredentials: return "Invalid username or password"
        case .sessionExpired: return "Session expired, please login again"
        case .httpsRequired: return "HTTPS connection required"
        case .serverError: return "Server error: \(message)"
        case .unknown: return message
        }
    }

    /// Display URL with https:// prefix for user.
    var displayUrl: String {
        let trimmed = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("https://") { return trimmed }
        return "https://\(trimmed)"
    }
}
