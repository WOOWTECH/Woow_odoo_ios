import Foundation
import CoreFoundation

/// One adapter for every registration/rotation/logout/remove write. Apporo pins
/// capability and write to the same account-owned SID and replays the WHOLE pair
/// once after expiry; WOOW deliberately retains its legacy wire contract.
struct PushDeviceRegistrar: Sendable {
    enum Failure: Error, Sendable { case notConfigured, invalidResponse, signInRequired, accountRemoved, superseded, temporarilyUnavailable }

    let brand: AppBrand.Code
    let api: OdooAPIClient
    let accounts: AccountRepositoryProtocol
    let credentials: PushCredentialStorage
    let healer: PushSessionHealer
    let legacyReauthenticator: SessionReauthenticator?

    init(brand: AppBrand.Code = AppBrand.current.code, api: OdooAPIClient,
         accounts: AccountRepositoryProtocol, credentials: PushCredentialStorage = SecureStorage.shared,
         healer: PushSessionHealer = .shared, legacyReauthenticator: SessionReauthenticator? = nil) {
        self.brand = brand
        self.api = api
        self.accounts = accounts
        self.credentials = credentials
        self.healer = healer
        self.legacyReauthenticator = legacyReauthenticator
    }

    private struct Operation: Sendable {
        let account: OdooAccount
        let credential: PushCredential?
        let revision: UUID
    }

    @MainActor private func begin(account: OdooAccount, captured: PushCredential? = nil) throws -> Operation {
        let identityIsCurrent = accounts.getAllAccounts().contains(where: { sameIdentity($0, account) })
        // Reject stale callers BEFORE they can supersede a live operation's revision.
        if brand == .apporo && captured == nil && !identityIsCurrent { throw Failure.superseded }
        let current = credentials.pushCredential(accountId: account.id)
        if let captured, captured.generation != current?.generation || !identityIsCurrent {
            // Cleanup captured before removal must not even supersede a newer operation.
            return Operation(account: account, credential: captured, revision: UUID())
        }
        return Operation(account: account, credential: captured ?? current,
                         revision: PushRegistrationStatusStore.shared.begin(accountId: account.id))
    }

    /// Identity, generation, operation ordering, status and tenant form ONE local
    /// commit. A captured cleanup may finish remotely but never change a new login.
    @MainActor @discardableResult
    private func commit(_ status: PushRegistrationStatus,
                        operation: Operation, tenantId: String? = nil) -> Bool {
        let account = operation.account
        guard accounts.getAllAccounts().contains(where: { sameIdentity($0, account) }),
              PushRegistrationStatusStore.shared.isCurrent(operation.revision, accountId: account.id) else { return false }
        if brand == .apporo {
            guard credentials.pushCredential(accountId: account.id)?.generation == operation.credential?.generation else { return false }
        }
        if let tenantId { accounts.setTenantId(tenantId, forAccountId: account.id) }
        PushRegistrationStatusStore.shared.set(status, for: account.id)
        return true
    }

    func register(account: OdooAccount, token: String, deviceName: String) async throws -> Any? {
        let operation = try await begin(account: account)
        await commit(.registering, operation: operation)
        do {
            let response = try await perform(account: account, credential: operation.credential,
                method: "register_device", kwargs: ["fcm_token": token, "device_name": deviceName, "platform": "ios"])
            let committed = await commit(.acknowledged, operation: operation,
                                         tenantId: PushTokenRepository.parseTenantId(from: response))
            if brand == .apporo && !committed { throw Failure.superseded }
            return response
        } catch {
            if case Failure.superseded = error { throw error }
            await commit(Self.status(for: error), operation: operation)
            throw error
        }
    }

    /// Retains the legacy URL-only API; Apporo must always resolve an account.
    func unregisterLegacyURL(_ serverURL: String, token: String) async throws {
        guard brand == .woowtech else { throw Failure.signInRequired }
        _ = try await api.callKw(serverUrl: serverURL, model: "woow.fcm.device",
                                 method: "unregister_device", kwargs: ["fcm_token": token])
    }

    func unregister(account: OdooAccount, token: String, capturedCredential: PushCredential? = nil) async throws {
        let operation = try await begin(account: account, captured: capturedCredential)
        do {
            _ = try await perform(account: account, credential: operation.credential,
                                  method: "unregister_device", kwargs: ["fcm_token": token])
            await commit(.notRegistered, operation: operation)
        } catch {
            if case Failure.superseded = error { throw error }
            await commit(Self.status(for: error), operation: operation)
            throw error
        }
    }

    private func perform(account: OdooAccount, credential: PushCredential?, method: String, kwargs: [String: Any]) async throws -> Any? {
        if brand == .woowtech {
            if method == "register_device" {
                return try await SessionHealingRegistrar(apiClient: api,
                    reauthenticator: legacyReauthenticator ?? .shared).callKwHealing(
                        account: account, model: "woow.fcm.device", method: method, kwargs: kwargs)
            }
            return try await api.callKw(serverUrl: account.fullServerUrl, model: "woow.fcm.device",
                                        method: method, kwargs: kwargs)
        }
        guard let credential,
              credential.matches(account), !credential.sessionId.isEmpty else { throw Failure.signInRequired }
        do {
            return try await capabilityAndWrite(account: account, credential: credential, method: method, kwargs: kwargs)
        } catch OdooAPIError.sessionExpired {
            let refreshed: PushCredential
            switch await healer.heal(account: account, credential: credential,
                                    api: api, storage: credentials, accounts: accounts) {
            case .healed(let value): refreshed = value
            case .credentialRejected: throw Failure.signInRequired
            case .superseded: throw Failure.superseded
            case .temporarilyUnavailable: throw Failure.temporarilyUnavailable
            }
            // No inner healing: even a write expiry restarts capability on the new SID.
            return try await capabilityAndWrite(account: account, credential: refreshed, method: method, kwargs: kwargs)
        }
    }

    private func capabilityAndWrite(account: OdooAccount, credential: PushCredential,
                                    method: String, kwargs: [String: Any]) async throws -> Any? {
        let registering = method == "register_device"
        if registering {
            guard await accountExists(account) else { throw Failure.accountRemoved }
        }
        let capability: Any?
        do {
            capability = try await api.callKwWithPushSession(serverUrl: credential.serverURL,
                sessionId: credential.sessionId, method: "get_push_capabilities")
        } catch OdooAPIError.serverError {
            throw Failure.notConfigured
        }
        guard let cap = capability as? [String: Any], cap["error"] == nil,
              Self.supportsVersion(cap["push_contract_version"]),
              let brands = cap["supported_brands"] as? [String], brands.contains("apporo") else {
            throw Failure.notConfigured
        }
        // A concurrent manual login/removal cannot authorize a stale registration.
        // Unregister is allowed to finish with its captured binding after local removal.
        if registering {
            guard await MainActor.run(body: {
                accounts.getAllAccounts().contains(where: { credential.matches($0) }) &&
                    credentials.pushCredential(accountId: account.id) == credential
            }) else { throw Failure.superseded }
        }
        var branded = kwargs
        branded["app_brand"] = "apporo"
        let result = try await api.callKwWithPushSession(serverUrl: credential.serverURL,
            sessionId: credential.sessionId, method: method, kwargs: branded)
        if registering {
            guard let response = result as? [String: Any], response["error"] == nil,
                  response["app_brand"] as? String == "apporo",
                  Self.supportsVersion(response["push_contract_version"]) else { throw Failure.invalidResponse }
        } else {
            guard let value = result as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw Failure.invalidResponse
            }
        }
        return result
    }

    private func accountExists(_ account: OdooAccount) async -> Bool {
        await MainActor.run {
            accounts.getAllAccounts().contains {
                sameIdentity($0, account)
            }
        }
    }

    private func sameIdentity(_ lhs: OdooAccount, _ rhs: OdooAccount) -> Bool {
        lhs.id == rhs.id && lhs.fullServerUrl == rhs.fullServerUrl && lhs.database == rhs.database &&
            lhs.username == rhs.username && lhs.userId == rhs.userId
    }

    static func supportsVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        let version = number.doubleValue
        return version.isFinite && version >= 2 && version.rounded() == version
    }

    static func status(for error: Error) -> PushRegistrationStatus {
        switch error {
        case Failure.notConfigured: return .notConfigured
        case Failure.invalidResponse, OdooAPIError.invalidResponse: return .invalidResponse
        case Failure.signInRequired, OdooAPIError.sessionExpired: return .signInRequired
        case Failure.accountRemoved: return .notRegistered
        default: return .temporarilyUnavailable
        }
    }
}
