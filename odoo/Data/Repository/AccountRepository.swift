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
    func setTenantId(_ tenantId: String, forAccountId accountId: String)
    func logout(accountId: String?) async
    func removeAccount(id: String) async
    func getSessionId(for serverUrl: String) -> String?
}

final class AccountRepository: AccountRepositoryProtocol, @unchecked Sendable {

    private let persistence: PersistenceController
    private let secureStorage: SecureStorage
    private let apiClient: OdooAPIClient
    private let brand: AppBrand.Code
    private let pushCredentials: PushCredentialStorage
    /// Removes a removed account's WebKit store (D1). Injectable for tests.
    private let webDataCleaner: AccountWebDataCleaning
    /// Best-effort server revoke of one session (`serverUrl`, `sessionId`). Injectable for tests.
    private let revokeSession: @Sendable (String, String) async -> Void
#if DEBUG
    /// Test seam (pi 1001c): runs once a manual login's commit has returned, so a test can order a
    /// second login against it.
    nonisolated(unsafe) var afterLoginCommitForTesting: (@Sendable () -> Void)?
#endif

    init(
        persistence: PersistenceController = .shared,
        secureStorage: SecureStorage = .shared,
        apiClient: OdooAPIClient = OdooAPIClient(),
        brand: AppBrand.Code = AppBrand.current.code,
        pushCredentials: PushCredentialStorage = SecureStorage.shared,
        webDataCleaner: AccountWebDataCleaning? = nil,
        revokeSession: (@Sendable (String, String) async -> Void)? = nil
    ) {
        self.persistence = persistence
        self.secureStorage = secureStorage
        self.apiClient = apiClient
        self.brand = brand
        self.pushCredentials = pushCredentials
        self.webDataCleaner = webDataCleaner ?? AccountWebDataCleaner()
        self.revokeSession = revokeSession ?? { [apiClient] url, sid in await apiClient.destroySession(serverUrl: url, sessionId: sid) }
        migratePasswordKeysIfNeeded()
    }

    /// Removes WebKit data stores that no longer belong to any account — left by an earlier build
    /// (before D1), or one whose deletion at logout failed. Run at launch, before any account's
    /// WebView is built; an account's own store is never touched.
    func pruneOrphanWebData() async {
        let ids = Set(getAllAccounts().map(\.id))
        await webDataCleaner.pruneOrphanStores(keeping: ids)
    }

    /// Local + server cleanup of a removed account's web session (D1), after its row, Keychain
    /// entries and push registration are gone:
    /// 1. collect every session id it used — Keychain / push credential copies plus whatever its
    ///    WebKit store holds (the WebView may have rotated to a newer session);
    /// 2. retire its live WebView and remove THAT account's WebKit store (a same-host sibling's store
    ///    and cookies are kept) — while the app keeps running (pi 0930, P2);
    /// 3. drop a pending deep link bound to it;
    /// 4. revoke each session on the server, detached — a dead server never delays logout.
    private func cleanUpWebSession(accountId: String, serverUrl: String, host: String,
                                   knownSessionIds: [String?]) async {
        let cleaner = webDataCleaner
        let fromStore = await cleaner.sessionIds(forAccountId: accountId, host: host)
        let all = Set((knownSessionIds.compactMap { $0 } + fromStore).filter { !$0.isEmpty })
        let otherHosts = await MainActor.run { getAllAccounts().filter { $0.id != accountId }.map(\.serverHost) }
        await cleaner.removeWebData(forAccountId: accountId, host: host, sessionIds: all, otherAccountHosts: otherHosts)
        await MainActor.run { DeepLinkManager.shared.drop(boundTo: accountId) }
        let revoke = revokeSession
        Task.detached {
            for sessionId in all.sorted() { await revoke(serverUrl, sessionId) }
        }
    }

    /// Runs the one-time Keychain key migration from `pwd_{username}` to
    /// `pwd_{host}_{username}` for all persisted accounts. Called once in init;
    /// the migration itself is idempotent.
    private func migratePasswordKeysIfNeeded() {
        let accounts = getAllAccounts()
        secureStorage.migratePasswordKeys(accounts: accounts)
        secureStorage.migrateSessionKeys(accounts: accounts)
    }

    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult {
        // Auto-prefix https
        let fullUrl = serverUrl.ensureHTTPS

        // pi 1001b (P1): logins and switches share one selection order for both brands — a later
        // selection supersedes this login, and this login supersedes an in-flight switch.
        let attempt = await PushManualLoginOrder.begin()
        // pi 1001d (P1): a login that starts while this identity is being logged out or removed is
        // refused at once; and one whose identity began a removal after it started stays stale even
        // after that removal ends (removal generation captured here, re-checked at the commit).
        let removalAtStart = await MainActor.run {
            AccountRemovalFence.state(serverUrl: fullUrl, database: database, username: username)
        }
        if removalAtStart.isRemoving {
            return .error(String(localized: "error_login_superseded"), .unknown)
        }
        // demo111 1001 (defect 2): both brands log in WITHOUT the shared jar. The WOOW login used to
        // send the jar's session_id — another same-host account's — and Odoo re-authenticated THAT
        // session as this user and rotated it, logging the other account out on the server.
        let result = await apiClient.authenticatePushSession(
            serverUrl: fullUrl, database: database, username: username, password: password)

        if case .success(let auth) = result {
            let context = persistence.container.viewContext
            // pi 1001c (P1): ONE fenced main-actor commit — account row, jar, Keychain password and
            // session copy, and the replaced-session decision. Nothing is written after the fence, so a
            // later login to the same account can never be overwritten by an earlier one resuming.
            let outcome = await MainActor.run { () -> (rejection: AuthResult?, replaced: String?) in
                // pi 1001c (P1): an account being logged out or removed is not brought back by a login
                // that raced the removal (its order is invalidated before the removal's first await;
                // a login started during the removal is refused here).
                if !PushManualLoginOrder.isCurrent(attempt) ||
                    AccountRemovalFence.state(serverUrl: fullUrl, database: database, username: username) != removalAtStart {
                    return (.error(String(localized: "error_login_superseded"), .unknown), nil)
                }
                // A short-lived response cookie may expire while waiting to commit. pi 1001b (P1): for
                // both brands — a WOOW success without a usable cookie used to activate this account
                // while the jar kept the previous same-host account's session, which the new account's
                // WebView then borrowed. No usable cookie from THIS response: nothing changes.
                guard let cookie = auth.sessionCookie?.cookie(), !auth.sessionId.isEmpty,
                      cookie.value == auth.sessionId else {
                    return (.error(String(localized: "error_session_setup"), .serverError), nil)
                }
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

                let savedId: String
                if let existing = found?.first {
                    existing.displayName = auth.displayName
                    existing.userId = Int32(auth.userId)
                    existing.isActive = true
                    existing.createdAt = Date()
                    savedId = existing.id
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
                    savedId = entity.id
                }

                try? context.save()
                // pi 1001b (P2): the session this re-login replaces — read inside the fence, so it is the
                // one actually stored when this login wins.
                let replaced = secureStorage.getSessionId(accountId: savedId)
                if brand == .apporo,
                   let saved = getAllAccounts().first(where: {
                       $0.fullServerUrl == fullUrl && $0.database == database && $0.username == username && $0.isActive
                   }) {
                    pushCredentials.savePushCredential(PushCredential(account: saved, password: password,
                                                                       sessionId: auth.sessionId, sessionCookie: auth.sessionCookie))
                    PushRegistrationStatusStore.shared.set(.notRegistered, for: saved.id)
                    // Keep legacy UI credentials in the same winning-login transaction.
                    secureStorage.savePassword(accountId: saved.id, password: password)
                    secureStorage.saveSessionId(accountId: saved.id, sessionId: auth.sessionId)
                    // Only the winning manual login publishes to the legacy WebView jar.
                    // Push healing uses the isolated response SID without publishing it.
                    HTTPCookieStorage.shared.setCookie(cookie)
                    return (nil, nil)
                }
                // WOOW (1001, defect 2): the jar holds the ACTIVE account's session for the legacy
                // requests and the WebView; publish the new account's response session to it, with the
                // Keychain password and session copy (hardware-backed, kept out of backups).
                HTTPCookieStorage.shared.setCookie(cookie)
                secureStorage.savePassword(accountId: savedId, password: password)
                secureStorage.saveSessionId(accountId: savedId, sessionId: auth.sessionId)
                guard let replaced, !replaced.isEmpty, replaced != auth.sessionId,
                      !isSessionHeldByAnotherAccount(replaced, accountId: savedId) else { return (nil, nil) }
                return (nil, replaced)
            }
            if let rejection = outcome.rejection {
                // The session this login created was never published — revoke it (best effort).
                revokeUnpublishedSession(auth.sessionId, serverUrl: fullUrl)
                return rejection
            }
#if DEBUG
            afterLoginCommitForTesting?()
#endif
            if let replaced = outcome.replaced {
                let revoke = revokeSession
                Task.detached { await revoke(fullUrl, replaced) }
            }
        }

        return result
    }

    /// Whether another saved account still holds `sessionId` — its Keychain copy or its push
    /// credential. pi 1001c: accounts are told apart by id (server + database + username), not by
    /// server + username; such a session is never revoked on this account's behalf.
    @MainActor
    private func isSessionHeldByAnotherAccount(_ sessionId: String, accountId: String) -> Bool {
        getAllAccounts().contains { other in
            other.id != accountId &&
                (secureStorage.getSessionId(accountId: other.id) == sessionId ||
                 pushCredentials.pushCredential(accountId: other.id)?.sessionId == sessionId)
        }
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
    ///
    /// An AMBIGUOUS tenant id — one carried by more than one stored account — also returns
    /// `nil`. `woow_fcm_push.tenant_id_for` falls back to the Odoo database name and the
    /// host is not part of the value, so two unrelated customers whose databases are both
    /// called e.g. "odoo" publish the same tenant id. Taking the first match would open one
    /// customer's notification inside another customer's account, which is exactly the
    /// isolation invariant above. Counting and refusing is also what the plugin's own
    /// `DEVICE_ID_DATA_KEY` contract requires of clients.
    func getAccount(byTenantId tenantId: String) -> OdooAccount? {
        guard !tenantId.isEmpty else { return nil }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchByTenantIdRequest(tenantId: tenantId)
        guard let matches = try? context.fetch(request) else { return nil }
        guard matches.count == 1 else {
            if matches.count > 1 {
                AppLogger.push.error(
                    "Refusing ambiguous tenant id: \(matches.count, privacy: .public) accounts match; dropping the deep link")
            }
            return nil
        }
        return matches[0].toDomainModel()
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
        if saved {
            // pi 1001c (P1): a notification tap is a selection for both brands — it supersedes a
            // pending WOOW switch too (B's late answer must not replace the notification's C).
            MainActor.assumeIsolated { PushManualLoginOrder.invalidate() }
            NotificationCenter.default.post(name: .activeAccountDidChange, object: nil)
        }
        return saved
    }

    /// Persists the opaque `tenantId` for the account matching `serverUrl`.
    ///
    /// **Refuses to write when `serverUrl` resolves to more than one account.** Two accounts
    /// can share a server URL (the same host serving several Odoo databases), and this
    /// signature carries nothing that could tell them apart — writing to an arbitrary one
    /// would mis-route every later push for that tenant to the wrong instance. This mirrors
    /// the count-and-refuse contract already applied to `getAccount(byTenantId:)`.
    ///
    /// Prefer ``setTenantId(_:forAccountId:)``: the registration caller always knows exactly
    /// which account it registered, so it never needs this ambiguous lookup. This overload
    /// remains for callers that genuinely only hold a URL.
    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) {
        guard !tenantId.isEmpty else { return }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchAllRequest()
        request.predicate = NSPredicate(format: "serverUrl == %@", serverUrl)
        guard let matches = try? context.fetch(request), matches.count == 1,
              let entity = matches.first else { return }
        guard entity.tenantId != tenantId else { return }
        entity.tenantId = tenantId
        try? context.save()
    }

    /// Persists the opaque `tenantId` against a specific account id.
    ///
    /// This is the unambiguous path: `id` is the account's UUID, so it identifies exactly one
    /// connection regardless of how many databases share a host. Used by the FCM registration
    /// flow, which already holds the account it just registered.
    func setTenantId(_ tenantId: String, forAccountId accountId: String) {
        guard !tenantId.isEmpty, !accountId.isEmpty else { return }
        let context = persistence.container.viewContext
        let request = OdooAccountEntity.fetchAllRequest()
        request.predicate = NSPredicate(format: "id == %@", accountId)
        guard let entity = (try? context.fetch(request))?.first else { return }
        guard entity.tenantId != tenantId else { return }
        entity.tenantId = tenantId
        try? context.save()
    }

    /// Switches to the specified account after validating the session.
    /// Re-authenticates with stored password if the session cookie is expired. (G8)
    ///
    /// `@MainActor` (Core Data confinement): every Core Data access here goes through the
    /// main-queue `viewContext`. A plain `async` method on this non-isolated class runs on the
    /// Swift cooperative pool, so before this annotation the WOOW branch fetched/deleted/saved
    /// `viewContext` off the main thread — racing the main run loop's own change processing and
    /// crashing intermittently (`-[__NSCFSet addObject:]: attempt to insert nil`, SIGTRAP/SEGV).
    /// Awaited network work (unregister/authenticate) still suspends off-main; only the Core Data
    /// and bookkeeping between awaits runs on main — the same owner the Apporo branch already uses.
    @MainActor
    func switchAccount(id: String) async -> Bool {
        if brand == .apporo { return await switchApporoAccount(id: id) }
        // pi 1001b (P1): the same selection order as Apporo — a late result for an older selection
        // (B answered after the user chose C) must not activate B or publish its cookie.
        let attempt = PushManualLoginOrder.begin()
        let context = persistence.container.viewContext
        guard let account = (try? context.fetch(OdooAccountEntity.fetchAllRequest()))?
            .first(where: { $0.id == id })?.toDomainModel() else { return false }

        // Validate session — try to authenticate with stored password. demo111 1001 (defect 2): not
        // over the shared jar — it carries the current (often same-host) account's session_id, and
        // Odoo would re-authenticate and rotate THAT session as the target user, logging the current
        // account out on the server. The target gets a session of its own instead.
        let replacedSessionId = secureStorage.getSessionId(accountId: account.id)
        var targetSession: HTTPCookie?
        var freshSessionId: String?
        var provenUserId: Int?
        if let password = secureStorage.getPassword(accountId: account.id) {
            let result = await apiClient.authenticatePushSession(
                serverUrl: account.fullServerUrl,
                database: account.database,
                username: account.username,
                password: password
            )
            switch result {
            case .success(let auth):
                // pi 1001b (P1): a success whose response cookie is no longer usable must not activate
                // the target — the jar would keep the current same-host account's session for it.
                guard let cookie = auth.sessionCookie?.cookie(), !auth.sessionId.isEmpty,
                      cookie.value == auth.sessionId else {
                    revokeUnpublishedSession(auth.sessionId, serverUrl: account.fullServerUrl)
                    return false
                }
                targetSession = cookie
                freshSessionId = auth.sessionId
                provenUserId = auth.userId
            case .error(_, let type):
                AppLogger.auth.info("Session validation failed for \(account.username)")
                if type == .invalidCredentials { ReloginSignal.shared.requestRelogin(accountId: account.id) }
                return false
            }
        } else if let replacedSessionId, !replacedSessionId.isEmpty,
                  await storedSessionIsValid(replacedSessionId, for: account) {
            // No stored password: the target keeps its own stored session — only once the server has
            // confirmed it is still this account's (same user and database). pi 1001e (P1): a session
            // id is not an identity merely because it exists. pi 1001f (P1): nor is a database match —
            // an account whose user id is unknown cannot prove the session is its own (sign in again).
            targetSession = HTTPCookie(properties: [.name: "session_id", .value: replacedSessionId,
                                                    .domain: account.serverHost, .path: "/", .secure: "TRUE"])
        }
        // pi 1001e (P1): no session can be obtained for the target (no password and no valid stored
        // session — e.g. an ambiguous legacy key was dropped on upgrade). Fail closed: the current
        // account and its jar stay as they are, and the target is routed to its own sign-in.
        guard targetSession != nil else {
            ReloginSignal.shared.requestRelogin(accountId: account.id)
            return false
        }

        // Revalidate after the await: still the newest selection, target still present and unchanged.
        guard PushManualLoginOrder.isCurrent(attempt),
              let all = try? context.fetch(OdooAccountEntity.fetchAllRequest()),
              let target = all.first(where: { $0.id == id }),
              target.toDomainModel().fullServerUrl == account.fullServerUrl,
              target.toDomainModel().username == account.username else {
            if let freshSessionId { revokeUnpublishedSession(freshSessionId, serverUrl: account.fullServerUrl) }
            return false
        }

        // Activate the target account
        all.forEach { $0.isActive = false }
        target.isActive = true
        // pi 1001f (P1): a credential login proves the user — record its id so the account's own
        // stored session can be proven on a later switch without a password.
        if target.userId <= 0, let provenUserId, provenUserId > 0 { target.userId = Int32(provenUserId) }
        let saved = (try? context.save()) != nil
        if saved, let targetSession {
            // The jar holds the active account's session (legacy requests, WebView) — the target's.
            secureStorage.saveSessionId(accountId: account.id, sessionId: targetSession.value)
            HTTPCookieStorage.shared.setCookie(targetSession)
            if let old = replacedSessionId, !old.isEmpty, old != targetSession.value,
               !isSessionHeldByAnotherAccount(old, accountId: account.id) {
                let revoke = revokeSession, serverUrl = account.fullServerUrl
                Task.detached { await revoke(serverUrl, old) }
            }
        }
        // Broadcast so MainViewModel reloads the WebView onto the newly active account.
        if saved { NotificationCenter.default.post(name: .activeAccountDidChange, object: nil) }
        return saved
    }

    /// Whether the server still accepts `sessionId` as `account`'s — same user, same database. No
    /// database in the answer, another user, rejected or no answer: not valid (fail closed).
    /// pi 1001f (P1): an account whose user id is unknown proves nothing — not valid either.
    private func storedSessionIsValid(_ sessionId: String, for account: OdooAccount) async -> Bool {
        guard let userId = account.userId,
              case .valid(let uid, let db) = await apiClient.pushSessionInfo(
            serverUrl: account.fullServerUrl, sessionId: sessionId), let db, db == account.database else { return false }
        return userId == uid
    }

    /// Best-effort revoke of a session a login/switch created but never published (superseded, or
    /// its response cookie was no longer usable). Never delays the caller.
    private func revokeUnpublishedSession(_ sessionId: String, serverUrl: String) {
        guard !sessionId.isEmpty else { return }
        let revoke = revokeSession
        Task.detached { await revoke(serverUrl, sessionId) }
    }

    /// D5: whether a switch can keep the target account's current session. It needs a cookie the
    /// WebView can be handed (bound to the stored session id, not expired) and the server must
    /// still accept that session for the same user and database. Anything else — rejected, another
    /// user/database, or no answer — falls back to the previous behaviour (log in again).
    private func canReuseSession(of credential: PushCredential, for account: OdooAccount) async -> Bool {
        guard !credential.sessionId.isEmpty,
              let cookie = credential.sessionCookie?.cookie(), cookie.value == credential.sessionId,
              cookie.expiresDate.map({ $0 > Date() }) ?? true else { return false }
        guard case .valid(let uid, let db) = await apiClient.pushSessionInfo(
            serverUrl: account.fullServerUrl, sessionId: credential.sessionId) else { return false }
        // pi 0930: no database in the answer is no proof the session belongs to this database (two
        // databases on one host can share a uid) — fail closed to a fresh login.
        guard let db, db == account.database else { return false }
        // pi 1001f (P1): the user must be positively the same — an unknown user id is no proof, so
        // the switch logs in with the stored credential instead.
        guard let userId = account.userId else { return false }
        return userId == uid
    }

    /// D5 (pi 0930): best-effort revoke of the session a switch replaced — called only AFTER the new
    /// credential is committed. A switch superseded by a newer selection commits nothing, so the
    /// target keeps its stored session (possibly its only one) untouched. Never delays the switch.
    private func revokeReplacedSession(_ old: PushCredential, by new: PushCredential, serverUrl: String) {
        guard !old.sessionId.isEmpty, old.sessionId != new.sessionId else { return }
        let revoke = revokeSession, oldId = old.sessionId
        Task.detached { await revoke(serverUrl, oldId) }
    }

    /// Selection and manual login share an order and transaction owner. Never borrow
    /// host-keyed credentials: they cannot identify the selected database/account.
    @MainActor
    private func switchApporoAccount(id: String) async -> Bool {
        let attempt = PushManualLoginOrder.begin()
        guard let account = getAllAccounts().first(where: { $0.id == id }),
              let captured = pushCredentials.pushCredential(accountId: id),
              captured.matches(account) else { return false }

        let selected: PushCredential
        if !captured.password.isEmpty {
            if await canReuseSession(of: captured, for: account) {
                // D5: the target's own session is still accepted for this user and database — no
                // new login, no new res.users.log row, no orphaned session, same push generation.
                selected = captured
            } else {
                let result = await apiClient.authenticatePushSession(serverUrl: account.fullServerUrl,
                    database: account.database, username: account.username, password: captured.password)
                guard case .success(let auth) = result,
                      account.userId == nil || account.userId == auth.userId else { return false }
                selected = PushCredential(account: account, password: captured.password,
                    sessionId: auth.sessionId, sessionCookie: auth.sessionCookie)
            }
        } else {
            selected = captured
        }

        // No suspension from revalidation through active/credential/cookie publication.
        let context = persistence.container.viewContext
        guard PushManualLoginOrder.isCurrent(attempt),
              let all = try? context.fetch(OdooAccountEntity.fetchAllRequest()),
              let target = all.first(where: { $0.id == id }),
              captured.matches(target.toDomainModel()),
              pushCredentials.pushCredential(accountId: id)?.generation == captured.generation,
              let cookie = selected.sessionCookie?.cookie(),
              !selected.sessionId.isEmpty, cookie.value == selected.sessionId else { return false }
        all.forEach { $0.isActive = false }
        target.isActive = true
        guard (try? context.save()) != nil else { return false }
        pushCredentials.savePushCredential(selected)
        revokeReplacedSession(captured, by: selected, serverUrl: account.fullServerUrl)
        if selected.generation != captured.generation {
            PushRegistrationStatusStore.shared.set(.notRegistered, for: id)
        }
        secureStorage.saveSessionId(accountId: account.id, sessionId: selected.sessionId)
        HTTPCookieStorage.shared.setCookie(cookie)
        NotificationCenter.default.post(name: .activeAccountDidChange, object: nil)
        return true
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
    ///
    /// `@MainActor` for Core Data confinement — see ``switchAccount(id:)``.
    @MainActor
    func logout(accountId: String? = nil) async {
        if brand == .apporo {
            await removeApporoAccount(id: accountId, logout: true)
            return
        }
        let context = persistence.container.viewContext
        let account: OdooAccountEntity?

        if let id = accountId {
            account = (try? context.fetch(OdooAccountEntity.fetchByIdRequest(id: id)))?.first
        } else {
            account = (try? context.fetch(OdooAccountEntity.fetchActiveRequest()))?.first
        }

        guard let account else { return }
        // pi 1001c (P1): before any await — an in-flight login or switch can no longer commit, and a
        // login started while this logout runs cannot re-add the account.
        PushManualLoginOrder.invalidate()
        let fenceKey = AccountRemovalFence.begin(account.toDomainModel())
        defer { AccountRemovalFence.end(fenceKey) }
        let wasActive = account.isActive

        // Unregister FCM token from THIS account's server (G9 — best-effort, never blocks logout).
        let removed = account.toDomainModel()
        await unregisterFcmToken(account: account.toDomainModel())
        let keychainSessionId = secureStorage.getSessionId(accountId: removed.id)

        // F4 (0930): the WOOW brand shares one cookie jar across accounts. While another account on
        // the same host remains, remove only THIS account's session cookie — not the host's cookies,
        // which would sign the sibling out. The host's last account clears them all, as before.
        let siblingOnHost = ((try? context.fetch(OdooAccountEntity.fetchAllRequest())) ?? []).contains {
            $0.id != account.id
                && $0.toDomainModel().serverHost.caseInsensitiveCompare(removed.serverHost) == .orderedSame
        }
        if siblingOnHost {
            await apiClient.clearSessionCookies(for: account.serverUrl, values: Set([keychainSessionId].compactMap { $0 }))
        } else {
            await apiClient.clearCookies(for: account.serverUrl)
        }
        secureStorage.deletePassword(accountId: removed.id)
        // Delete the Keychain session_id copy so the session cannot be reused after logout.
        secureStorage.deleteSessionId(accountId: removed.id)
        pushCredentials.deletePushCredential(accountId: account.id)
        PushRegistrationStatusStore.shared.remove(accountId: account.id)
        context.delete(account)
        try? context.save()
        await cleanUpWebSession(accountId: removed.id, serverUrl: removed.fullServerUrl,
                                host: removed.serverHost, knownSessionIds: [keychainSessionId])

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

    /// `@MainActor` for Core Data confinement — see ``switchAccount(id:)``.
    @MainActor
    func removeAccount(id: String) async {
        if brand == .apporo {
            await removeApporoAccount(id: id, logout: false)
            return
        }
        let context = persistence.container.viewContext
        guard let entity = (try? context.fetch(OdooAccountEntity.fetchByIdRequest(id: id)))?.first else { return }

        // pi 1001c (P1): see ``logout(accountId:)`` — fenced before any await.
        PushManualLoginOrder.invalidate()
        let fenceKey = AccountRemovalFence.begin(entity.toDomainModel())
        defer { AccountRemovalFence.end(fenceKey) }
        // Unregister FCM token from Odoo server (G9)
        let removed = entity.toDomainModel()
        await unregisterFcmToken(account: entity.toDomainModel())
        let keychainSessionId = secureStorage.getSessionId(accountId: removed.id)

        secureStorage.deletePassword(accountId: removed.id)
        secureStorage.deleteSessionId(accountId: removed.id)
        pushCredentials.deletePushCredential(accountId: entity.id)
        PushRegistrationStatusStore.shared.remove(accountId: entity.id)
        context.delete(entity)
        try? context.save()
        await cleanUpWebSession(accountId: removed.id, serverUrl: removed.fullServerUrl,
                                host: removed.serverHost, knownSessionIds: [keychainSessionId])

        // If no accounts remain, clear the local FCM token
        let remaining = (try? context.fetch(OdooAccountEntity.fetchAllRequest())) ?? []
        if remaining.isEmpty {
            secureStorage.deleteFcmToken()
        }
    }

    /// Remove local state before suspending for best-effort remote cleanup. This
    /// shares MainActor with manual commit and healer CAS, across all instances.
    private func removeApporoAccount(id: String?, logout: Bool) async {
        let captured = await MainActor.run { () -> (OdooAccount, PushCredential?, String?, String?)? in
            let context = persistence.container.viewContext
            let request = id.map { OdooAccountEntity.fetchByIdRequest(id: $0) } ?? OdooAccountEntity.fetchActiveRequest()
            guard let entity = (try? context.fetch(request))?.first else { return nil }
            PushManualLoginOrder.invalidate()
            let account = entity.toDomainModel()
            let credential = pushCredentials.pushCredential(accountId: account.id)
            let token = secureStorage.getFcmToken()
            let keychainSessionId = secureStorage.getSessionId(accountId: account.id)
            pushCredentials.deletePushCredential(accountId: account.id)
            PushRegistrationStatusStore.shared.remove(accountId: account.id)
            secureStorage.deletePassword(accountId: account.id)
            secureStorage.deleteSessionId(accountId: account.id)
            if logout, let cookie = credential?.sessionCookie?.cookie() {
                // Never clear another account's same-host jar cookie.
                for existing in HTTPCookieStorage.shared.cookies ?? [] where
                    existing.name == cookie.name && existing.domain == cookie.domain &&
                    existing.path == cookie.path && existing.value == cookie.value {
                    HTTPCookieStorage.shared.deleteCookie(existing)
                }
            }
            context.delete(entity)
            try? context.save()
            let remaining = (try? context.fetch(OdooAccountEntity.fetchAllRequest())) ?? []
            if remaining.isEmpty { secureStorage.deleteFcmToken() }
            else if logout && (account.isActive || !remaining.contains(where: { $0.isActive })) {
                remaining.forEach { $0.isActive = false }
                remaining.first?.isActive = true
                try? context.save()
                NotificationCenter.default.post(name: .activeAccountDidChange, object: nil)
            }
            return (account, credential, token, keychainSessionId)
        }
        // The Keychain session copy is captured inside the transaction (it is deleted there).
        let keychainSessionId = captured?.3
        guard let (account, credential, token) = captured.map({ ($0.0, $0.1, $0.2) }) else { return }
        if let credential, let token {
            do {
                try await PushDeviceRegistrar(brand: brand, api: apiClient, accounts: self,
                    credentials: pushCredentials).unregister(account: account, token: token, capturedCredential: credential)
            } catch {
                AppLogger.push.error("FCM unregister failed: \(PushDeviceRegistrar.status(for: error).rawValue, privacy: .public)")
            }
        }
        // After the unregister (which still needs the session), revoke and remove the web session.
        await cleanUpWebSession(accountId: account.id, serverUrl: account.fullServerUrl, host: account.serverHost,
                                knownSessionIds: [credential?.sessionId, credential?.sessionCookie?.cookie()?.value, keychainSessionId])
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
    private func unregisterFcmToken(account: OdooAccount) async {
        guard let token = secureStorage.getFcmToken() else {
            AppLogger.push.info("FCM unregister skipped: no local token")
            return
        }
        do {
            // Lazy construction avoids AccountRepository → shared reauthenticator init recursion.
            try await PushDeviceRegistrar(brand: brand, api: apiClient, accounts: self,
                credentials: pushCredentials).unregister(account: account, token: token)
        } catch {
            AppLogger.push.error("FCM unregister failed: \(PushDeviceRegistrar.status(for: error).rawValue, privacy: .public)")
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
                secureStorage.deletePassword(accountId: entity.id)
                secureStorage.deleteSessionId(accountId: entity.id)
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
        secureStorage.saveSessionId(accountId: entity.id, sessionId: seeded.sessionCookie)

        print("[TestHook] replaceAccountsForTesting: installed \(seeded.username)@\(host) active=\(isActive) tenant=\(seeded.tenantId ?? "nil")")
    }
#endif
}

/// pi 1001c: identities whose logout/removal is in progress. A login committing for one of them
/// is refused, so a removed account is never resurrected by a login that raced the removal.
@MainActor
enum AccountRemovalFence {
    /// pi 1001d: the identity's removal state — removing now, and how many removals ever began. A
    /// login compares the state at its start with the state at its commit; any removal in between
    /// (even one already finished) makes it stale.
    struct State: Equatable { let isRemoving: Bool; let generation: Int }
    private static var removing: [String: Int] = [:]
    private static var generations: [String: Int] = [:]
    private static func key(_ serverUrl: String, _ database: String, _ username: String) -> String {
        "\(serverUrl.ensureHTTPS)|\(database)|\(username)"
    }
    static func begin(_ account: OdooAccount) -> String {
        let k = key(account.serverUrl, account.database, account.username)
        removing[k, default: 0] += 1
        generations[k, default: 0] += 1
        return k
    }
    static func state(serverUrl: String, database: String, username: String) -> State {
        let k = key(serverUrl, database, username)
        return State(isRemoving: removing[k] != nil, generation: generations[k] ?? 0)
    }
    static func end(_ key: String) {
        guard let count = removing[key] else { return }
        if count <= 1 { removing.removeValue(forKey: key) } else { removing[key] = count - 1 }
    }
}

/// A late Apporo login or switch cannot replace a newer explicit selection.
@MainActor
/// Internal (not private) only so tests can supersede an in-flight selection.
enum PushManualLoginOrder {
    private static var current = UUID()
    static func begin() -> UUID { current = UUID(); return current }
    static func invalidate() { current = UUID() }
    static func isCurrent(_ attempt: UUID) -> Bool { current == attempt }
}
