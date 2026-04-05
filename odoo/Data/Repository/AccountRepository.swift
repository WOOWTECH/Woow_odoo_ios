import CoreData
import Foundation

/// Manages Odoo account lifecycle — auth, switch, logout, CRUD.
/// Ported from Android: AccountRepository.kt
protocol AccountRepositoryProtocol: Sendable {
    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult
    func getActiveAccount() -> OdooAccount?
    func getAllAccounts() -> [OdooAccount]
    func switchAccount(id: String) async -> Bool
    func logout(accountId: String?) async
    func removeAccount(id: String) async
    func getSessionId(for serverUrl: String) -> String?
}

final class AccountRepository: AccountRepositoryProtocol, @unchecked Sendable {

    private let persistence: PersistenceController
    private let secureStorage: SecureStorage
    private let apiClient: OdooAPIClient

    init(
        persistence: PersistenceController = .shared,
        secureStorage: SecureStorage = .shared,
        apiClient: OdooAPIClient = OdooAPIClient()
    ) {
        self.persistence = persistence
        self.secureStorage = secureStorage
        self.apiClient = apiClient
    }

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        // Auto-prefix https
        let fullUrl = serverUrl.hasPrefix("https://") ? serverUrl :
                      serverUrl.hasPrefix("http://") ? "https://" + serverUrl.dropFirst("http://".count) :
                      "https://\(serverUrl)"

        let result = await apiClient.authenticate(
            serverUrl: fullUrl, database: database, username: username, password: password
        )

        if case .success(let auth) = result {
            let context = persistence.container.viewContext
            await MainActor.run {
                // Deactivate all existing accounts
                let allRequest = OdooAccountEntity.fetchAllRequest()
                if let existing = try? context.fetch(allRequest) {
                    existing.forEach { $0.isActive = false }
                }

                // Check if account already exists
                let findRequest = OdooAccountEntity.fetchAllRequest()
                findRequest.predicate = NSPredicate(
                    format: "serverUrl == %@ AND database == %@ AND username == %@",
                    fullUrl, database, username
                )
                let found = try? context.fetch(findRequest)

                if let existing = found?.first {
                    existing.displayName = auth.displayName
                    existing.userId = Int32(auth.userId)
                    existing.isActive = true
                    existing.createdAt = Date()
                } else {
                    let entity = OdooAccountEntity(context: context)
                    entity.id = UUID().uuidString
                    entity.serverUrl = fullUrl
                    entity.database = database
                    entity.username = username
                    entity.displayName = auth.displayName
                    entity.userId = Int32(auth.userId)
                    entity.isActive = true
                    entity.createdAt = Date()
                }

                try? context.save()
            }

            // Save password in Keychain
            secureStorage.savePassword(accountId: username, password: password)
        }

        return result
    }

    func getActiveAccount() -> OdooAccount? {
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchActiveRequest()
        return (try? context.fetch(request))?.first?.toDomainModel()
    }

    func getAllAccounts() -> [OdooAccount] {
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchAllRequest()
        return (try? context.fetch(request))?.map { $0.toDomainModel() } ?? []
    }

    /// Switches to the specified account after validating the session.
    /// Re-authenticates with stored password if the session cookie is expired. (G8)
    func switchAccount(id: String) async -> Bool {
        let context = persistence.container.viewContext
        let allRequest = OdooAccountEntity.fetchAllRequest()
        guard let all = try? context.fetch(allRequest) else { return false }
        guard let target = all.first(where: { $0.id == id }) else { return false }

        let account = target.toDomainModel()

        // Validate session — try to authenticate with stored password
        if let password = secureStorage.getPassword(accountId: account.username) {
            let result = await apiClient.authenticate(
                serverUrl: account.fullServerUrl,
                database: account.database,
                username: account.username,
                password: password
            )
            switch result {
            case .success:
                break // Session valid, proceed
            case .error:
                #if DEBUG
                print("[AccountRepository] Session validation failed for \(account.username)")
                #endif
                return false
            }
        }

        // Activate the target account
        all.forEach { $0.isActive = false }
        target.isActive = true
        return (try? context.save()) != nil
    }

    func logout(accountId: String? = nil) async {
        let context = persistence.container.viewContext
        let account: OdooAccountEntity?

        if let id = accountId {
            account = (try? context.fetch(OdooAccountEntity.fetchByIdRequest(id: id)))?.first
        } else {
            account = (try? context.fetch(OdooAccountEntity.fetchActiveRequest()))?.first
        }

        guard let account else { return }

        // Unregister FCM token from Odoo server (G9 — best-effort, never blocks logout)
        await unregisterFcmToken(serverUrl: account.serverUrl)

        await apiClient.clearCookies(for: account.serverUrl)
        secureStorage.deletePassword(accountId: account.username)
        context.delete(account)
        try? context.save()

        // If no accounts remain, clear the local FCM token
        let remaining = (try? context.fetch(OdooAccountEntity.fetchAllRequest())) ?? []
        if remaining.isEmpty {
            secureStorage.deleteFcmToken()
        }
    }

    func removeAccount(id: String) async {
        let context = persistence.container.viewContext
        guard let entity = (try? context.fetch(OdooAccountEntity.fetchByIdRequest(id: id)))?.first else { return }

        // Unregister FCM token from Odoo server (G9)
        await unregisterFcmToken(serverUrl: entity.serverUrl)

        secureStorage.deletePassword(accountId: entity.username)
        context.delete(entity)
        try? context.save()

        // If no accounts remain, clear the local FCM token
        let remaining = (try? context.fetch(OdooAccountEntity.fetchAllRequest())) ?? []
        if remaining.isEmpty {
            secureStorage.deleteFcmToken()
        }
    }

    /// Unregisters FCM token from Odoo server. Best-effort — errors logged, never blocks.
    private func unregisterFcmToken(serverUrl: String) async {
        guard let token = secureStorage.getFcmToken() else { return }
        do {
            _ = try await apiClient.callKw(
                serverUrl: "https://\(serverUrl)",
                model: "woow.fcm.device",
                method: "unregister_device",
                args: [],
                kwargs: ["fcm_token": token]
            )
        } catch {
            #if DEBUG
            print("[AccountRepository] FCM unregister failed for \(serverUrl): \(error)")
            #endif
        }
    }

    func getSessionId(for serverUrl: String) -> String? {
        // Delegate to API client's cookie management
        // This is a synchronous call — session is in HTTPCookieStorage
        let semaphore = DispatchSemaphore(value: 0)
        var sessionId: String?
        Task {
            sessionId = await apiClient.getSessionId(for: serverUrl)
            semaphore.signal()
        }
        semaphore.wait()
        return sessionId
    }
}
