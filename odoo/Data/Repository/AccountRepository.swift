import CoreData
import Foundation

extension Notification.Name {
    /// Posted whenever the active account changes (account switch, or the fast activate-on-tap
    /// used for a notification deep link). Observers such as `MainViewModel` react by reloading the
    /// WebView onto the new active account — this is the fix for "multi-account switch left the UI
    /// on the previous account" (iOS Problem #1).
    static let activeAccountDidChange = Notification.Name("io.woowtech.odoo.activeAccountDidChange")
}

/// Manages Odoo account lifecycle — auth, switch, logout, CRUD.
/// Ported from Android: AccountRepository.kt
protocol AccountRepositoryProtocol: Sendable {
    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult
    func getActiveAccount() -> OdooAccount?
    func getAllAccounts() -> [OdooAccount]
    func getAccount(byTenantId tenantId: String) -> OdooAccount?
    func switchAccount(id: String) async -> Bool
    func activateAccount(id: String) -> Bool
    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String)
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
        migratePasswordKeysIfNeeded()
    }

    /// Runs the one-time Keychain key migration from `pwd_{username}` to
    /// `pwd_{host}_{username}` for all persisted accounts. Called once in init;
    /// the migration itself is idempotent.
    private func migratePasswordKeysIfNeeded() {
        let accounts = getAllAccounts()
        secureStorage.migratePasswordKeys(accounts: accounts)
    }

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        // Auto-prefix https
        let fullUrl = serverUrl.ensureHTTPS

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

            // Save password in Keychain, scoped to this server + username
            secureStorage.savePassword(serverUrl: fullUrl, username: username, password: password)

            // Save session_id to Keychain as a second, hardware-backed copy.
            // HTTPCookieStorage still holds the cookie for URLSession network requests,
            // but the Keychain copy is protected against backup extraction and jailbroken
            // device file access (kSecAttrAccessibleWhenUnlockedThisDeviceOnly).
            if !auth.sessionId.isEmpty {
                secureStorage.saveSessionId(serverUrl: fullUrl, username: username, sessionId: auth.sessionId)
            }
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

    /// Resolves the locally-stored account whose tenant id matches `tenantId`.
    ///
    /// This is the push-routing lookup: an incoming notification's opaque
    /// `odoo_tenant_id` is matched against persisted accounts. Returns `nil` when no
    /// account carries that tenant id — the caller MUST drop the deep link in that case
    /// and never fall back to the active account (cross-tenant isolation invariant).
    ///
    /// An empty `tenantId` never matches (guards against accounts with a nil/empty
    /// tenant id being selected by an empty payload value).
    func getAccount(byTenantId tenantId: String) -> OdooAccount? {
        guard !tenantId.isEmpty else { return nil }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchByTenantIdRequest(tenantId: tenantId)
        return (try? context.fetch(request))?.first?.toDomainModel()
    }

    /// Marks the account with `id` active and every other account inactive, without any
    /// network round-trip. Returns `false` if no account with that id exists.
    ///
    /// Unlike `switchAccount(id:)`, this performs no session re-validation — it is the
    /// fast, synchronous switch used on a notification tap so the UI can render the target
    /// account's WebView immediately. Session validity is enforced later by the WebView's
    /// `/web/login` redirect detection. Must be called from the main actor (Core Data
    /// `viewContext`).
    @discardableResult
    func activateAccount(id: String) -> Bool {
        let context = persistence.container.viewContext
        let allRequest = OdooAccountEntity.fetchAllRequest()
        guard let all = try? context.fetch(allRequest),
              let target = all.first(where: { $0.id == id }) else { return false }
        all.forEach { $0.isActive = false }
        target.isActive = true
        let saved = (try? context.save()) != nil
        // Broadcast so MainViewModel reloads the WebView onto the newly active account (the fast,
        // synchronous switch used on a notification deep-link tap).
        if saved { NotificationCenter.default.post(name: .activeAccountDidChange, object: nil) }
        return saved
    }

    /// Persists the opaque `tenantId` for the account matching `serverUrl`.
    ///
    /// Called at device registration once the server returns the tenant id, so later
    /// push notifications can be routed to this account. The match is by `serverUrl`
    /// (the registration is per-server); a no-op if no matching account exists or the
    /// tenant id is already stored.
    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) {
        guard !tenantId.isEmpty else { return }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchAllRequest()
        request.predicate = NSPredicate(format: "serverUrl == %@", serverUrl)
        guard let entity = (try? context.fetch(request))?.first else { return }
        guard entity.tenantId != tenantId else { return }
        entity.tenantId = tenantId
        try? context.save()
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
        if let password = secureStorage.getPassword(serverUrl: account.fullServerUrl, username: account.username) {
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
                AppLogger.auth.info("Session validation failed for \(account.username)")
                return false
            }
        }

        // Activate the target account
        all.forEach { $0.isActive = false }
        target.isActive = true
        let saved = (try? context.save()) != nil
        // Broadcast so MainViewModel reloads the WebView onto the newly active account.
        if saved { NotificationCenter.default.post(name: .activeAccountDidChange, object: nil) }
        return saved
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
        let wasActive = account.isActive

        // Unregister FCM token from THIS account's server (G9 — best-effort, never blocks logout).
        await unregisterFcmToken(serverUrl: account.serverUrl)

        await apiClient.clearCookies(for: account.serverUrl)
        secureStorage.deletePassword(serverUrl: account.serverUrl, username: account.username)
        // Delete the Keychain session_id copy so the session cannot be reused after logout.
        secureStorage.deleteSessionId(serverUrl: account.serverUrl, username: account.username)
        context.delete(account)
        try? context.save()

        let remaining = (try? context.fetch(OdooAccountEntity.fetchAllRequest())) ?? []
        if remaining.isEmpty {
            // Last account logged out — clear the shared local token; the UI returns to login.
            secureStorage.deleteFcmToken()
            return
        }

        // Multi-account fallback (fix for "logout stranded the user on the login screen"): if we
        // logged out the ACTIVE account (or none is active), promote the most-recently-used remaining
        // account so the app falls back to it and stays authenticated. `fetchAllRequest` is ordered
        // createdAt DESC, so `.first` is the most recent. Broadcast so MainViewModel reloads onto it.
        if wasActive || remaining.first(where: { $0.isActive }) == nil {
            remaining.forEach { $0.isActive = false }
            remaining.first?.isActive = true
            try? context.save()
            NotificationCenter.default.post(name: .activeAccountDidChange, object: nil)
        }
    }

    func removeAccount(id: String) async {
        let context = persistence.container.viewContext
        guard let entity = (try? context.fetch(OdooAccountEntity.fetchByIdRequest(id: id)))?.first else { return }

        // Unregister FCM token from Odoo server (G9)
        await unregisterFcmToken(serverUrl: entity.serverUrl)

        secureStorage.deletePassword(serverUrl: entity.serverUrl, username: entity.username)
        context.delete(entity)
        try? context.save()

        // If no accounts remain, clear the local FCM token
        let remaining = (try? context.fetch(OdooAccountEntity.fetchAllRequest())) ?? []
        if remaining.isEmpty {
            secureStorage.deleteFcmToken()
        }
    }

    /// Unregisters FCM token from Odoo server. Best-effort — errors logged, never blocks.
    /// Best-effort unregister of THIS phone's FCM token from ONE account's server (the account is
    /// the subject; the token is a shared device constant). Never blocks logout.
    ///
    /// Bug fix (iOS Problem "logged-out tenant keeps pushing"): the previous implementation built
    /// the URL as `"https://\(serverUrl)"`, but `serverUrl` is already stored https-prefixed, so it
    /// produced `https://https://…` — a malformed URL that made every unregister throw and get
    /// swallowed, leaving the logged-out tenant's device row active. `ensureHTTPS` is idempotent, so
    /// it fixes the double-prefix without breaking a rare non-prefixed value.
    private func unregisterFcmToken(serverUrl: String) async {
        guard let token = secureStorage.getFcmToken() else {
            // Not an error, but must not be silent — a missing local token means we cannot tell the
            // server to stop pushing, so the row stays active until the token rotates.
            AppLogger.push.info("FCM unregister skipped for \(serverUrl, privacy: .public): no local token")
            return
        }
        do {
            _ = try await apiClient.callKw(
                serverUrl: serverUrl.ensureHTTPS,
                model: "woow.fcm.device",
                method: "unregister_device",
                args: [],
                kwargs: ["fcm_token": token]
            )
        } catch {
            // Best-effort: logout still completes. Logged for retry/reconciliation — the server keeps
            // the row active until a later unregister succeeds or the token rotates.
            AppLogger.push.error("FCM unregister failed for \(serverUrl, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func getSessionId(for serverUrl: String) -> String? {
        // Direct synchronous read from HTTPCookieStorage — no async needed (H1 fix)
        apiClient.getSessionId(for: serverUrl)
    }

    // MARK: - DEBUG Test Helpers

#if DEBUG
    /// Replaces all persisted accounts with a single pre-authenticated test account and marks
    /// it active, then plants the session cookie in both HTTPCookieStorage and Keychain.
    ///
    /// Calling this bypasses the normal authentication flow, making the WebView open directly
    /// to the Odoo dashboard without a login round-trip. Intended exclusively for XCUITest
    /// suites that seed a known session via `WOOW_SEED_ACCOUNT` launch-environment JSON.
    ///
    /// - Parameter seeded: The account to install, including the raw `sessionCookie` value.
    func replaceAccountsForTesting(_ seeded: SeededAccount) {
        replaceAccountsForTesting([seeded])
    }

    /// Replaces all persisted accounts with the given pre-authenticated test accounts, marking one
    /// active (the first with `isActive == true`, else the first). Used by the multi-account
    /// cross-tenant deep-link E2E, which seeds two accounts on different servers — each with its own
    /// isolated session cookie and opaque `tenantId` — so a cross-account notification tap can
    /// resolve a target account by matching the push's `odoo_tenant_id`.
    func replaceAccountsForTesting(_ seededAccounts: [SeededAccount]) {
        let context = persistence.container.viewContext

        // Wipe all existing accounts and their Keychain credentials.
        let allRequest = OdooAccountEntity.fetchAllRequest()
        if let existing = try? context.fetch(allRequest) {
            for entity in existing {
                let url = entity.serverUrl ?? ""
                let user = entity.username ?? ""
                secureStorage.deletePassword(serverUrl: url, username: user)
                secureStorage.deleteSessionId(serverUrl: url, username: user)
                context.delete(entity)
            }
        }

        // If no account is explicitly marked active, the first one is (single-seed default).
        let activeIndex = seededAccounts.firstIndex { $0.isActive == true } ?? 0
        for (index, seeded) in seededAccounts.enumerated() {
            installSeededAccount(seeded, isActive: index == activeIndex, into: context)
        }
        try? context.save()
    }

    /// Installs one seeded account entity, plants its session cookie, and stores its tenant id.
    /// Does NOT save the context (the caller saves once after installing every account).
    private func installSeededAccount(
        _ seeded: SeededAccount,
        isActive: Bool,
        into context: NSManagedObjectContext
    ) {
        let entity = OdooAccountEntity(context: context)
        entity.id = UUID().uuidString
        entity.serverUrl = seeded.serverURL
        entity.database = seeded.database
        entity.username = seeded.username
        entity.displayName = seeded.username
        entity.userId = 1
        entity.isActive = isActive
        entity.createdAt = Date()
        // Seed the tenant id the app would normally learn during FCM registration, so a
        // cross-account notification tap can resolve THIS account as the target.
        if let tenantId = seeded.tenantId, !tenantId.isEmpty {
            entity.tenantId = tenantId
        }

        // Plant the session_id cookie in HTTPCookieStorage so WKWebView picks it up.
        let host = URL(string: seeded.serverURL.ensureHTTPS)?.host ?? seeded.serverURL
        let cookie = HTTPCookie(properties: [
            .name: "session_id",
            .value: seeded.sessionCookie,
            .domain: host,
            .path: "/",
            .secure: "TRUE",
        ])
        if let cookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        // Also save to Keychain so session reads via SecureStorage work.
        secureStorage.saveSessionId(
            serverUrl: seeded.serverURL.ensureHTTPS,
            username: seeded.username,
            sessionId: seeded.sessionCookie
        )

        print("[TestHook] replaceAccountsForTesting: installed \(seeded.username)@\(host) active=\(isActive) tenant=\(seeded.tenantId ?? "nil")")
    }
#endif
}
