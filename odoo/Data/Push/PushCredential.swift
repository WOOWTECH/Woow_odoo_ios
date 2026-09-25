import Foundation

/// A push credential belongs to one saved account, not merely a hostname. Legacy
/// host+username keys cannot distinguish databases/ports and are never imported.
struct PushCredential: Codable, Sendable, Equatable {
    let accountId: String
    let serverURL: String
    let database: String
    let username: String
    let userId: Int?
    let password: String
    let sessionId: String
    let generation: UUID
    let sessionCookie: PushSessionCookie?

    init(account: OdooAccount, password: String, sessionId: String, generation: UUID = UUID(), sessionCookie: PushSessionCookie? = nil) {
        accountId = account.id
        serverURL = account.fullServerUrl
        database = account.database
        username = account.username
        userId = account.userId
        self.password = password
        self.sessionId = sessionId
        self.generation = generation
        self.sessionCookie = sessionCookie
    }

    func matches(_ account: OdooAccount) -> Bool {
        accountId == account.id && serverURL == account.fullServerUrl &&
            database == account.database && username == account.username && userId == account.userId &&
            URL(string: serverURL)?.scheme == "https" && URL(string: account.serverUrl)?.scheme == "https"
    }
}

/// MainActor is the ONE process-wide transaction owner, across every storage
/// instance (including SecureStorage wrappers of the same Keychain namespace).
/// Check/account validation/save/delete and local completion run synchronously on
/// this actor. No lock, await, network or actor hop is allowed inside those blocks.
protocol PushCredentialStorage: Sendable {
    @MainActor func pushCredential(accountId: String) -> PushCredential?
    @MainActor func savePushCredential(_ credential: PushCredential)
    @MainActor func deletePushCredential(accountId: String)
}

enum PushHealOutcome: Sendable, Equatable {
    case healed(PushCredential)
    case credentialRejected
    case superseded
    case temporarilyUnavailable
}

/// Account-and-login-generation single flight; only explicit credential rejection
/// opens a circuit. Manual login creates a new generation, leaving siblings alone.
actor PushSessionHealer {
    static let shared = PushSessionHealer()
    private var inFlight: [UUID: Task<PushHealOutcome, Never>] = [:]
    private var openCircuits: Set<UUID> = []

    func heal(account: OdooAccount, credential: PushCredential, api: OdooAPIClient,
              storage: PushCredentialStorage, accounts: AccountRepositoryProtocol) async -> PushHealOutcome {
        guard let current = await MainActor.run(body: { () -> PushCredential? in
            guard credential.matches(account),
                  accounts.getAllAccounts().contains(where: { credential.matches($0) }),
                  let current = storage.pushCredential(accountId: account.id),
                  current.generation == credential.generation, current.matches(account) else { return nil }
            return current
        }) else { return .superseded }
        if openCircuits.contains(credential.generation) { return .credentialRejected }
        if let task = inFlight[credential.generation] { return await task.value }
        if current != credential { return .healed(current) }
        guard !credential.password.isEmpty else { return .credentialRejected }
        let task = Task<PushHealOutcome, Never> {
            let result = await api.authenticatePushSession(
                serverUrl: credential.serverURL, database: credential.database,
                username: credential.username, password: credential.password)
            let outcome = await MainActor.run { () -> PushHealOutcome in
                // CAS and account revalidation share the manual/remove transaction owner.
                guard accounts.getAllAccounts().contains(where: { credential.matches($0) }),
                      storage.pushCredential(accountId: account.id) == credential else { return .superseded }
                switch result {
                case .success(let auth):
                    guard !auth.sessionId.isEmpty,
                          account.userId == nil || account.userId == auth.userId else { return .credentialRejected }
                    let refreshed = PushCredential(account: account, password: credential.password,
                        sessionId: auth.sessionId, generation: credential.generation, sessionCookie: auth.sessionCookie)
                    storage.savePushCredential(refreshed)
                    return .healed(refreshed)
                case .error(_, let type):
                    if type == .invalidCredentials {
                        ReloginSignal.shared.requestRelogin(accountId: account.id)
                        return .credentialRejected
                    }
                    return .temporarilyUnavailable
                }
            }
            if outcome == .credentialRejected { self.openCircuits.insert(credential.generation) }
            return outcome
        }
        inFlight[credential.generation] = task
        let result = await task.value
        inFlight[credential.generation] = nil
        return result
    }
}

@MainActor
extension PushCredentialStorage {
    /// WebView consumes the same response cookie policy, never an ambient SID or
    /// a newly manufactured root cookie. Legacy credentials without policy fail closed.
    func webSessionCookie(accountId: String, serverURL: String, database: String) -> HTTPCookie? {
        guard let credential = pushCredential(accountId: accountId),
              credential.serverURL == serverURL, credential.database == database else { return nil }
        return credential.sessionCookie?.cookie()
    }
}
