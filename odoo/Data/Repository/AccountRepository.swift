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

    /// True when `tenantId` matches more than one local account, so it cannot identify one.
    ///
    /// Only used to choose a DROP REASON — it can never turn a drop into a navigation. See
    /// `NotificationDeepLinkRouter.DropReason.ambiguousTenant` (story 10-1, P2-9).
    /// True when `accountId` is one of the accounts carrying `tenantId`. See the implementation
    /// for why this can never cause a cross-tenant switch.
    func isAccount(_ accountId: String, candidateForTenantId tenantId: String) -> Bool

    /// Resolves the account owning `deviceId` — the ACCOUNT-scoped routing key (P2-9).
    func getAccount(byDeviceId deviceId: String) -> OdooAccount?

    /// Persists the ACCOUNT-scoped routing key for one account (P2-9).
    func setDeviceId(_ deviceId: String, forAccountId accountId: String)

    /// True when `deviceId` matches more than one account (per-database sequence collision).
    func isDeviceIdAmbiguous(_ deviceId: String) -> Bool

    /// True when ANY account has stored a routing key.
    func anyAccountHasDeviceId() -> Bool

    func isTenantIdAmbiguous(_ tenantId: String) -> Bool
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
    /// Returns `nil` when the id is empty, matches nothing, **or matches more than one account**.
    ///
    /// Ambiguity is refused rather than resolved (story 10-1, P2-9). Two accounts can legitimately
    /// share a tenant id — the id is the Odoo database name, so two boxes deployed with the same
    /// `POSTGRES_DB` collide, and two users on ONE database collide unavoidably. Picking either one
    /// opens the wrong server, or the wrong user's session on the right server. Dropping the deep
    /// link is the safe half of a bad choice; the real fix is server-side and is recorded in the
    /// story's follow-ups.
    func getAccount(byTenantId tenantId: String) -> OdooAccount? {
        guard !tenantId.isEmpty else { return nil }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchByTenantIdRequest(tenantId: tenantId)
        guard let matches = try? context.fetch(request), matches.count == 1 else { return nil }
        return matches[0].toDomainModel()
    }

    /// True when `tenantId` matches MORE THAN ONE local account.
    ///
    /// Exists purely so a dropped deep link can say WHY. `getAccount(byTenantId:)` returns nil for
    /// both "no match" and "several matches", and those are different operational problems: one is
    /// a push for an account this device does not have, the other is two boxes deployed with the
    /// same database name. An operator reading logs must be able to tell them apart.
    func isTenantIdAmbiguous(_ tenantId: String) -> Bool {
        guard !tenantId.isEmpty else { return false }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchByTenantIdRequest(tenantId: tenantId)
        // `count(for:)` rather than fetching and counting — the objects are never used.
        return ((try? context.count(for: request)) ?? 0) > 1
    }

    /// True when `accountId` is one of the accounts carrying `tenantId`.
    ///
    /// Used only on the ambiguous path, to decide whether the ALREADY-ACTIVE account may keep a
    /// deep link rather than the tap becoming a silent no-op. It can never cause a switch, so it
    /// cannot produce a cross-tenant navigation (story 10-1 review).
    func isAccount(_ accountId: String, candidateForTenantId tenantId: String) -> Bool {
        guard !tenantId.isEmpty, !accountId.isEmpty else { return false }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchByTenantIdRequest(tenantId: tenantId)
        guard let matches = try? context.fetch(request) else { return false }
        return matches.contains { $0.id == accountId }
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
    /// Persists the ACCOUNT-scoped push routing key for ONE account (P2-9).
    ///
    /// Keyed by account id, unlike `setTenantId(_:forServerUrl:)` — the whole reason this
    /// key exists is to separate two users on one server, so keying it by server would
    /// collapse exactly the distinction it is meant to draw.
    func setDeviceId(_ deviceId: String, forAccountId accountId: String) {
        guard !deviceId.isEmpty, !accountId.isEmpty else { return }
        let context = persistence.container.viewContext
        guard let entity = (try? context.fetch(OdooAccountEntity.fetchByIdRequest(id: accountId)))?.first,
              entity.deviceId != deviceId else { return }
        entity.deviceId = deviceId
        try? context.save()
    }

    /// Resolves the account owning `deviceId`, or nil. Unique per (fcm_token, user_id) by
    /// construction — but still refuses on more than one, because a routing lookup must
    /// surface a violated assumption rather than hide it behind a first match.
    func getAccount(byDeviceId deviceId: String) -> OdooAccount? {
        guard !deviceId.isEmpty else { return nil }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchByDeviceIdRequest(deviceId: deviceId)
        guard let matches = try? context.fetch(request), matches.count == 1 else { return nil }
        return matches[0].toDomainModel()
    }

    /// True when `deviceId` matches MORE THAN ONE account — see `DropReason.ambiguousDevice`.
    func isDeviceIdAmbiguous(_ deviceId: String) -> Bool {
        guard !deviceId.isEmpty else { return false }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchByDeviceIdRequest(deviceId: deviceId)
        return ((try? context.count(for: request)) ?? 0) > 1
    }

    /// True when ANY account has stored a routing key. False means the server upgraded
    /// before this device re-registered, and the tenant path must still be tried.
    func anyAccountHasDeviceId() -> Bool {
        getAllAccounts().contains { !($0.deviceId ?? "").isEmpty }
    }

    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) {
        guard !tenantId.isEmpty else { return }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchAllRequest()
        request.predicate = NSPredicate(format: "serverUrl == %@", serverUrl)
        guard let entities = try? context.fetch(request), !entities.isEmpty else { return }

        // Stamp EVERY account on this server, not just the first (story 10-1 review).
        //
        // The first version took `.first` and then short-circuited on
        // `entity.tenantId != tenantId`. Two users on ONE Odoo database share a
        // `serverUrl`, so the registration loop's second pass resolved to the SAME row
        // and was swallowed by that guard — only one of the two rows ever got stamped.
        //
        // That silently defeats the ambiguity refusal on the read side:
        // `isTenantIdAmbiguous` counts rows carrying the id, so with only one stamped it
        // reports false, `getAccount(byTenantId:)` returns that single row, and a push
        // for the OTHER user opens this one's session. The evidence was being destroyed
        // at WRITE time — the same failure mode as the `fetchLimit` this story removed
        // from the read path, one layer earlier.
        //
        // Which row won was `createdAt DESC`, and `authenticate` refreshes `createdAt`
        // on every re-login, so it could also flip over the device's lifetime.
        var changed = false
        for entity in entities where entity.tenantId != tenantId {
            entity.tenantId = tenantId
            changed = true
        }
        if changed { try? context.save() }
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

    /// Honest logout (FCM token-lifecycle S4 / AC9): logging out an account must leave **no trace**
    /// of it that a later reconcile could resurrect.
    ///
    /// The order matters and is guaranteed here:
    /// 1. issue a best-effort remote `unregister_device` so the server **hard-deletes** the
    ///    `(fcm_token, user_id)` row (it never blocks logout — a dead/unreachable host is swallowed), THEN
    /// 2. **remove the local account row** and clear its stored password + session id — not merely the
    ///    session cookie. This is the demo444 fix: a decommissioned tenant used to linger in the local
    ///    DB after "logout" (which only cleared the cookie) and poison every launch reconcile.
    ///
    /// Multi-account is preserved: only the logged-out account's row + credentials + server
    /// registration are removed; a sibling on the same device keeps its row, credentials, and push.
    /// A still-logged-in sibling is promoted to active; the login screen appears only on the last logout.
    ///
    /// This is deliberately minimal — there is no pruning counter or state machine (that was the
    /// abandoned option-A machinery). Honest row removal is the whole story.
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
