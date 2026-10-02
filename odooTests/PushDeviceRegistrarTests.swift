import XCTest
import CoreData
import WebKit
@testable import odoo

/// Scripted URLProtocol catches every request, including authentication. No DNS,
/// Firebase configuration, or live account is used by this suite.
@MainActor
final class PushDeviceRegistrarTests: XCTestCase {
    private var api: OdooAPIClient!
    private var session: URLSession!
    private var accounts: PushAccounts!
    private var credentials: PushCredentials!
    private var healer: PushSessionHealer!
    private let a = OdooAccount(id: "push-a", serverUrl: "https://push.invalid:8443/base",
                                database: "db-a", username: "same", displayName: "Fixture A")
    private let b = OdooAccount(id: "push-b", serverUrl: "https://push.invalid:8443/base",
                                database: "db-b", username: "same", displayName: "Fixture B")
    private static let cap: [String: Any] = ["push_contract_version": 2, "supported_brands": ["woowtech", "apporo"]]
    private static let ack: [String: Any] = ["app_brand": "apporo", "push_contract_version": 2,
                                            "device_id": 1, "odoo_tenant_id": "fixture-tenant"]

    override func setUp() async throws {
        try await super.setUp()
        PushContractURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushContractURLProtocol.self]
        config.httpCookieStorage = .shared
        session = URLSession(configuration: config)
        api = OdooAPIClient(session: session)
        accounts = PushAccounts([a, b])
        credentials = PushCredentials()
        credentials.savePushCredential(PushCredential(account: a, password: "fixture-password-a", sessionId: "sid-a"))
        credentials.savePushCredential(PushCredential(account: b, password: "fixture-password-b", sessionId: "sid-b"))
        healer = PushSessionHealer()
        PushRegistrationStatusStore.shared.remove(accountId: a.id)
        PushRegistrationStatusStore.shared.remove(accountId: b.id)
        clearFixtureCookies()
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        SecureStorage.shared.deleteFcmToken()
        for account in [a, b] {
            SecureStorage.shared.deletePassword(accountId: account.id)
            SecureStorage.shared.deleteSessionId(accountId: account.id)
        }
        clearFixtureCookies()
        PushRegistrationStatusStore.shared.remove(accountId: a.id)
        PushRegistrationStatusStore.shared.remove(accountId: b.id)
        PushContractURLProtocol.reset()
        try await super.tearDown()
    }

    private func clearFixtureCookies() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain == "push.invalid" || cookie.domain == ".push.invalid" {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    private func registrar(_ brand: AppBrand.Code = .apporo, repository: AccountRepositoryProtocol? = nil) -> PushDeviceRegistrar {
        PushDeviceRegistrar(brand: brand, api: api, accounts: repository ?? accounts,
                            credentials: credentials, healer: healer)
    }

    private func register(_ account: OdooAccount? = nil) async throws -> Any? {
        try await registrar().register(account: account ?? a, token: "fixture-token", deviceName: "Fixture")
    }

    private func expectFailure(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected rejection") } catch { }
    }

    func test_woow_oldAndNewServer_omitsCapabilityAndBrand() async throws {
        let results: [Any] = [true, Self.ack]
        for result in results {
            PushContractURLProtocol.reset([.result(result), .result(true)])
            _ = try await registrar(.woowtech).register(account: a, token: "fixture", deviceName: "Fixture")
            try await registrar(.woowtech).unregister(account: a, token: "fixture")
            XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["register_device", "unregister_device"])
            XCTAssertTrue(PushContractURLProtocol.calls.allSatisfy { $0.kwargs["app_brand"] == nil })
        }
        XCTAssertEqual(PushTokenRepository.parseTenantId(from: Self.ack), "fixture-tenant")
    }

    func test_apporo_validServer_capabilityBeforeEveryWrite_andEcho() async throws {
        PushContractURLProtocol.reset([.result(Self.cap), .result(Self.ack), .result(Self.cap), .result(false)])
        let result = try await register()
        XCTAssertEqual(PushTokenRepository.parseTenantId(from: result), "fixture-tenant")
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .acknowledged)
        try await registrar().unregister(account: a, token: "fixture-token")
        let calls = PushContractURLProtocol.calls
        XCTAssertEqual(calls.map(\.method), ["get_push_capabilities", "register_device", "get_push_capabilities", "unregister_device"])
        XCTAssertEqual(calls[0].kwargs.count, 0)
        XCTAssertTrue(calls[0].args.isEmpty)
        XCTAssertEqual(calls[1].kwargs["app_brand"] as? String, "apporo")
        XCTAssertEqual(calls[3].kwargs["app_brand"] as? String, "apporo")
        XCTAssertTrue(calls.allSatisfy { $0.cookie == "session_id=sid-a" && !$0.handlesCookies })
    }

    func test_apporo_badCapabilities_registerAndUnregisterProduceZeroWrites() async {
        let bad: [Any] = [true, [:], ["push_contract_version": 1, "supported_brands": ["apporo"]],
            ["push_contract_version": "2", "supported_brands": ["apporo"]],
            ["push_contract_version": true, "supported_brands": ["apporo"]],
            ["push_contract_version": 2.5, "supported_brands": ["apporo"]],
            ["push_contract_version": 2, "supported_brands": ["woowtech"]],
            ["push_contract_version": 2, "supported_brands": "apporo"],
            ["push_contract_version": 2, "supported_brands": ["apporo", 7]]]
        for capability in bad {
            for unregister in [false, true] {
                PushContractURLProtocol.reset([.result(capability)])
                await expectFailure {
                    if unregister { try await self.registrar().unregister(account: self.a, token: "fixture") }
                    else { _ = try await self.register() }
                }
                XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities"])
                XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .notConfigured)
            }
        }
    }

    func test_apporo_oldServerMethodError_zeroWrites() async {
        PushContractURLProtocol.reset([.serverError])
        await expectFailure { _ = try await self.register() }
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities"])
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .notConfigured)
    }

    func test_apporo_invalidEcho_neverAcknowledgesOrFallsBack() async {
        let bad: [Any] = [true, ["app_brand": "woowtech", "push_contract_version": 2],
                         ["app_brand": "apporo"], ["app_brand": "apporo", "push_contract_version": "2"],
                         ["app_brand": "apporo", "push_contract_version": 1],
                         ["app_brand": "apporo", "push_contract_version": 2, "error": "fixture"]]
        for echo in bad {
            PushContractURLProtocol.reset([.result(Self.cap), .result(echo)])
            await expectFailure { _ = try await self.register() }
            XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities", "register_device"])
            XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .invalidResponse)
        }
    }

    func test_apporo_writeExpiry_healsOnceAndRepeatsCapabilityOnNewSession() async throws {
        PushContractURLProtocol.reset([.result(Self.cap), .expired, .auth("sid-healed"),
                                       .result(Self.cap), .result(Self.ack)])
        _ = try await register()
        let calls = PushContractURLProtocol.calls
        XCTAssertEqual(calls.map(\.method), ["get_push_capabilities", "register_device", "authenticate", "get_push_capabilities", "register_device"])
        XCTAssertEqual(calls.map(\.cookie), ["session_id=sid-a", "session_id=sid-a", nil, "session_id=sid-healed", "session_id=sid-healed"])
        XCTAssertEqual(calls[2].params["db"] as? String, "db-a")
        XCTAssertEqual(calls[2].params["login"] as? String, "same")
        XCTAssertTrue(calls.allSatisfy { $0.url.hasPrefix(a.fullServerUrl + "/web/") })
    }

    func test_apporo_capabilityExpiry_healsThenChecksCapability() async throws {
        PushContractURLProtocol.reset([.expired, .auth("sid-new"), .result(Self.cap), .result(Self.ack)])
        _ = try await register()
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities", "authenticate", "get_push_capabilities", "register_device"])
    }

    func test_apporo_secondExpiry_neverHealsTwice() async {
        PushContractURLProtocol.reset([.result(Self.cap), .expired, .auth("sid-new"), .result(Self.cap), .expired])
        await expectFailure { _ = try await self.register() }
        XCTAssertEqual(PushContractURLProtocol.calls.filter { $0.method == "authenticate" }.count, 1)
        XCTAssertEqual(PushContractURLProtocol.calls.count, 5)
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .signInRequired)
    }

    func test_apporo_healedSessionLacksCapability_noReplayedWrite() async {
        PushContractURLProtocol.reset([.result(Self.cap), .expired, .auth("sid-new"), .result([:])])
        await expectFailure { _ = try await self.register() }
        XCTAssertEqual(PushContractURLProtocol.calls.filter { $0.method == "register_device" }.count, 1)
        XCTAssertEqual(PushContractURLProtocol.calls.count, 4)
    }

    func test_apporo_sameHostDifferentDatabase_usesAccountBoundSessionsAndStates() async throws {
        PushContractURLProtocol.reset([.result(Self.cap), .result(Self.ack), .result([:])])
        _ = try await register(a)
        await expectFailure { _ = try await self.register(self.b) }
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.cookie), ["session_id=sid-a", "session_id=sid-a", "session_id=sid-b"])
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .acknowledged)
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: b.id), .notConfigured)
    }

    func test_apporo_secondAccountExpiry_authenticatesExactDatabaseNotFirstHostMatch() async throws {
        PushContractURLProtocol.reset([.expired, .auth("sid-b-new"), .result(Self.cap), .result(Self.ack)])
        _ = try await register(b)
        XCTAssertEqual(PushContractURLProtocol.calls[1].params["db"] as? String, "db-b")
        XCTAssertEqual(credentials.pushCredential(accountId: a.id)?.sessionId, "sid-a")
        XCTAssertEqual(credentials.pushCredential(accountId: b.id)?.sessionId, "sid-b-new")
    }

    func test_apporo_pushHealing_neverReadsOrWritesSharedCookieJar() async throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session_id", .value: "unrelated",
            .domain: "push.invalid", .path: "/", .secure: "TRUE"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        PushContractURLProtocol.reset([.expired, .auth("sid-healed"), .result(Self.cap), .result(Self.ack)])
        _ = try await register()
        XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "unrelated")
        XCTAssertNil(PushContractURLProtocol.calls[1].cookie)
        XCTAssertTrue(PushContractURLProtocol.calls.allSatisfy { !$0.handlesCookies })
    }

    func test_apporo_missingScopedCredential_refusesLegacyFallback() async {
        credentials.deletePushCredential(accountId: a.id)
        SecureStorage.shared.savePassword(accountId: a.id, password: "legacy-fixture")
        SecureStorage.shared.saveSessionId(accountId: a.id, sessionId: "legacy-sid")
        await expectFailure { _ = try await self.register() }
        XCTAssertEqual(PushContractURLProtocol.calls.count, 0)
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .signInRequired)
    }

    func test_apporo_changedPortPathDatabaseOrUsername_rejectsBindingWithoutNetwork() async {
        for changed in [
            OdooAccount(id: a.id, serverUrl: "https://push.invalid:9443/base", database: a.database, username: a.username, displayName: "Fixture"),
            OdooAccount(id: a.id, serverUrl: "https://push.invalid:8443/other", database: a.database, username: a.username, displayName: "Fixture"),
            OdooAccount(id: a.id, serverUrl: a.serverUrl, database: "other", username: a.username, displayName: "Fixture"),
            OdooAccount(id: a.id, serverUrl: a.serverUrl, database: a.database, username: "other", displayName: "Fixture")
        ] {
            await expectFailure { _ = try await self.register(changed) }
        }
        XCTAssertEqual(PushContractURLProtocol.calls.count, 0)
    }

    func test_apporo_removedAccount_blocksRegistrationButAllowsCapturedCleanup() async throws {
        let captured = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
        accounts.rows = []
        await expectFailure { _ = try await self.register() }
        XCTAssertEqual(PushContractURLProtocol.calls.count, 0)
        PushContractURLProtocol.reset([.result(Self.cap), .result(true)])
        try await registrar().unregister(account: a, token: "fixture", capturedCredential: captured)
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities", "unregister_device"])
    }

    func test_apporo_removedAccountExpiredCleanup_doesNotReauthenticate() async throws {
        let captured = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
        accounts.rows = []
        PushContractURLProtocol.reset([.expired])
        await expectFailure { try await self.registrar().unregister(account: self.a, token: "fixture", capturedCredential: captured) }
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities"])
    }

    func test_apporo_badPasswordCircuit_newManualLoginGenerationResetsOnlyThatAccount() async throws {
        PushContractURLProtocol.reset([.expired, .badPassword, .expired])
        await expectFailure { _ = try await self.register() }
        await expectFailure { _ = try await self.register() }
        XCTAssertEqual(PushContractURLProtocol.calls.filter { $0.method == "authenticate" }.count, 1)
        credentials.savePushCredential(PushCredential(account: a, password: "new-fixture", sessionId: "manual-new"))
        PushContractURLProtocol.reset([.expired, .auth("healed-new-login"), .result(Self.cap), .result(Self.ack)])
        _ = try await register()
        XCTAssertEqual(PushContractURLProtocol.calls.filter { $0.method == "authenticate" }.count, 1)
        XCTAssertEqual(credentials.pushCredential(accountId: b.id)?.sessionId, "sid-b")
    }

    func test_apporo_transportFailure_hasSanitizedAccountDiagnostic() async {
        // Exhausting the script produces a local URLProtocol error, never real transport.
        await expectFailure { _ = try await self.register() }
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .temporarilyUnavailable)
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: b.id), .notRegistered)
    }

    func test_apporo_rotation_unregisteredOldThenRegisteredNewWithFreshCaps() async {
        accounts.rows = [a]
        SecureStorage.shared.saveFcmToken("old-fixture")
        PushContractURLProtocol.reset([.result(Self.cap), .result(true), .result(Self.cap), .result(Self.ack)])
        let repository = PushTokenRepository(accountRepository: accounts, apiClient: api,
                                             brand: .apporo, pushCredentials: credentials)
        await repository.registerTokenWithAllAccounts("new-fixture")
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities", "unregister_device", "get_push_capabilities", "register_device"])
        XCTAssertEqual(PushContractURLProtocol.calls[1].kwargs["fcm_token"] as? String, "old-fixture")
        XCTAssertEqual(PushContractURLProtocol.calls[3].kwargs["fcm_token"] as? String, "new-fixture")
        XCTAssertEqual(accounts.tenantWrites[a.id], "fixture-tenant")
    }

    func test_apporo_emptyAccountsTokenReplay_registersWhenAccountAppears() async {
        SecureStorage.shared.deleteFcmToken()
        accounts.rows = []
        let repository = PushTokenRepository(accountRepository: accounts, apiClient: api,
                                             brand: .apporo, pushCredentials: credentials)
        await repository.registerTokenWithAllAccounts("fixture-replay")
        XCTAssertTrue(PushContractURLProtocol.calls.isEmpty)
        accounts.rows = [a]
        PushContractURLProtocol.reset([.result(Self.cap), .result(Self.ack)])
        await repository.registerTokenWithAllAccounts("fixture-replay")
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities", "register_device"])
    }

    func test_apporo_logoutAndRemove_missingCapability_stillDeleteOnlyLocalTarget() async throws {
        for logout in [true, false] {
            let persistence = PersistenceController(inMemory: true)
            for account in [a, b] { OdooAccountEntity(context: persistence.container.viewContext).update(from: account) }
            try persistence.container.viewContext.save()
            let repository = AccountRepository(persistence: persistence, apiClient: api, brand: .apporo,
                                               pushCredentials: credentials)
            credentials.savePushCredential(PushCredential(account: a, password: "fixture", sessionId: "sid-a"))
            SecureStorage.shared.saveFcmToken("fixture")
            PushContractURLProtocol.reset([.result([:])])
            if logout { await repository.logout(accountId: a.id) }
            else { await repository.removeAccount(id: a.id) }
            XCTAssertEqual(repository.getAllAccounts().map(\.id), [b.id])
            XCTAssertNil(credentials.pushCredential(accountId: a.id))
            XCTAssertNotNil(credentials.pushCredential(accountId: b.id))
            XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities"])
        }
    }

    func test_apporo_logoutAndRemove_validServer_alwaysUseBrandedAdapter() async throws {
        for logout in [true, false] {
            let persistence = PersistenceController(inMemory: true)
            OdooAccountEntity(context: persistence.container.viewContext).update(from: a)
            try persistence.container.viewContext.save()
            let repository = AccountRepository(persistence: persistence, apiClient: api, brand: .apporo,
                                               pushCredentials: credentials)
            credentials.savePushCredential(PushCredential(account: a, password: "fixture", sessionId: "sid-a"))
            SecureStorage.shared.saveFcmToken("fixture")
            PushContractURLProtocol.reset([.result(Self.cap), .result(true)])
            if logout { await repository.logout(accountId: a.id) }
            else { await repository.removeAccount(id: a.id) }
            XCTAssertTrue(repository.getAllAccounts().isEmpty)
            XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities", "unregister_device"])
            XCTAssertEqual(PushContractURLProtocol.calls.last?.kwargs["app_brand"] as? String, "apporo")
        }
    }

    func test_apporo_manualLogin_singleRequestStoresResponseSession_andPublishesForWebView() async throws {
        let repository = AccountRepository(persistence: PersistenceController(inMemory: true), apiClient: api,
                                           brand: .apporo, pushCredentials: credentials)
        PushContractURLProtocol.reset([.auth("manual-response")])
        let result = await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                    username: a.username, password: "fixture")
        guard case .success = result else { return XCTFail("Login rejected") }
        let account = try XCTUnwrap(repository.getActiveAccount())
        XCTAssertEqual(credentials.pushCredential(accountId: account.id)?.sessionId, "manual-response")
        XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "manual-response")
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["authenticate"])
        XCTAssertFalse(PushContractURLProtocol.calls[0].handlesCookies)
        XCTAssertNil(PushContractURLProtocol.calls[0].cookie)
    }

    func test_apporo_manualLogin_lateCompletionCannotReplaceNewerAccountOrCookie() async throws {
        let repository = AccountRepository(persistence: PersistenceController(inMemory: true), apiClient: api,
                                           brand: .apporo, pushCredentials: credentials)
        let held = expectation(description: "First login response held")
        PushContractURLProtocol.reset([.heldAuth("old-response"), .auth("new-response")])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let first = Task { await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                         username: a.username, password: "fixture") }
        await fulfillment(of: [held], timeout: 2)
        let second = await repository.authenticate(serverUrl: b.serverUrl, database: b.database,
                                                    username: b.username, password: "fixture")
        guard case .success = second else { return XCTFail("New login rejected") }
        PushContractURLProtocol.releaseHeld()
        let stale = await first.value
        guard case .error = stale else { return XCTFail("Stale login must not activate") }
        XCTAssertEqual(repository.getActiveAccount()?.database, b.database)
        XCTAssertEqual(api.getSessionId(for: b.fullServerUrl), "new-response")
        XCTAssertEqual(repository.getAllAccounts().count, 1)
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["authenticate", "authenticate"])
    }

    func test_apporo_accountRemovedDuringCapability_doesNotWrite() async throws {
        let held = expectation(description: "Capability held")
        var capability = PushContractURLProtocol.Reply.result(Self.cap)
        capability.hold = true
        PushContractURLProtocol.reset([capability])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { try await register() }
        await fulfillment(of: [held], timeout: 2)
        accounts.rows = []
        credentials.deletePushCredential(accountId: a.id)
        PushContractURLProtocol.releaseHeld()
        await expectFailure { _ = try await work.value }
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities"])
    }

    func test_apporo_missingOrInvalidSessionManualLogin_preservesExistingAccountAndJar() async throws {
        let persistence = PersistenceController(inMemory: true)
        let previous = OdooAccount(id: b.id, serverUrl: b.serverUrl, database: b.database,
                                   username: b.username, displayName: b.displayName, isActive: true)
        OdooAccountEntity(context: persistence.container.viewContext).update(from: previous)
        try persistence.container.viewContext.save()
        let repository = AccountRepository(persistence: persistence, apiClient: api,
                                           brand: .apporo, pushCredentials: credentials)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session_id", .value: "previous-account",
            .domain: "push.invalid", .path: "/", .secure: "TRUE"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        let before = credentials.pushCredential(accountId: b.id)
        let beforeA = credentials.pushCredential(accountId: a.id)
        let oldSession = SecureStorage.shared.getSessionId(accountId: a.id)
        for reply in [PushContractURLProtocol.Reply.result(["uid": 7, "name": "Fixture"]), .auth("bad sid")] {
            PushContractURLProtocol.reset([reply])
            let result = await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                        username: a.username, password: "fixture")
            guard case .error(let message, let type) = result else { return XCTFail("Missing valid login session must fail closed") }
            XCTAssertEqual(type, .serverError)
            XCTAssertEqual(message, String(localized: "error_session_setup"))
            XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
            XCTAssertEqual(repository.getAllAccounts().map(\.id), [b.id])
            XCTAssertEqual(credentials.pushCredential(accountId: b.id), before)
            XCTAssertEqual(credentials.pushCredential(accountId: a.id), beforeA)
            XCTAssertEqual(SecureStorage.shared.getSessionId(accountId: a.id), oldSession)
            XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "previous-account")
            XCTAssertEqual(PushContractURLProtocol.calls.count, 1)
        }
    }

    func test_apporo_validLoginButPushNotConfigured_loginStaysSuccessful() async throws {
        let repository = AccountRepository(persistence: PersistenceController(inMemory: true), apiClient: api,
                                           brand: .apporo, pushCredentials: credentials)
        PushContractURLProtocol.reset([.auth("manual-valid"), .result([:])])
        let result = await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                    username: a.username, password: "fixture")
        guard case .success = result else { return XCTFail("Valid login rejected") }
        let account = try XCTUnwrap(repository.getActiveAccount())
        await expectFailure { _ = try await self.registrar(repository: repository).register(account: account, token: "fixture", deviceName: "Fixture") }
        XCTAssertEqual(repository.getActiveAccount()?.id, account.id)
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: account.id), .notConfigured)
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["authenticate", "get_push_capabilities"])
    }

    func test_apporo_unregisterWriteExpiry_rechecksCapabilityAfterHealing() async throws {
        PushContractURLProtocol.reset([.result(Self.cap), .expired, .auth("cleanup-new"), .result(Self.cap), .result(true)])
        try await registrar().unregister(account: b, token: "fixture")
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities", "unregister_device", "authenticate", "get_push_capabilities", "unregister_device"])
        XCTAssertEqual(PushContractURLProtocol.calls.last?.cookie, "session_id=cleanup-new")
        XCTAssertEqual(PushContractURLProtocol.calls[2].params["db"] as? String, b.database)
    }

    func test_apporo_sameHostDifferentPort_preservesFullBaseURL() async throws {
        let other = OdooAccount(id: "push-other-port", serverUrl: "https://push.invalid:9443/other-base",
                                database: "db-other", username: "other-user", displayName: "Other")
        accounts.rows.append(other)
        credentials.savePushCredential(PushCredential(account: other, password: "fixture", sessionId: "other-port-sid"))
        PushContractURLProtocol.reset([.result(Self.cap), .result(Self.ack), .result(Self.cap), .result(Self.ack)])
        _ = try await register(a)
        _ = try await register(other)
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.url), [
            a.fullServerUrl + "/web/dataset/call_kw", a.fullServerUrl + "/web/dataset/call_kw",
            other.fullServerUrl + "/web/dataset/call_kw", other.fullServerUrl + "/web/dataset/call_kw"])
        XCTAssertEqual(PushContractURLProtocol.calls.last?.cookie, "session_id=other-port-sid")
        PushRegistrationStatusStore.shared.remove(accountId: other.id)
    }

    func test_apporo_concurrentHealing_singleFlightForAccountGeneration() async throws {
        let held = expectation(description: "Healing held")
        PushContractURLProtocol.reset([.heldAuth("single-flight-sid")])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let credential = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
        async let first = healer.heal(account: a, credential: credential, api: api, storage: credentials, accounts: accounts)
        async let second = healer.heal(account: a, credential: credential, api: api, storage: credentials, accounts: accounts)
        await fulfillment(of: [held], timeout: 2)
        PushContractURLProtocol.releaseHeld()
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { if case .healed(let credential) = $0 { return credential.sessionId }; return nil }, ["single-flight-sid", "single-flight-sid"])
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["authenticate"])
    }

    func test_apporo_sessionReplacedDuringCapability_doesNotReuseOldAuthorization() async {
        let held = expectation(description: "Capability held")
        var capability = PushContractURLProtocol.Reply.result(Self.cap)
        capability.hold = true
        PushContractURLProtocol.reset([capability])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { try await register() }
        await fulfillment(of: [held], timeout: 2)
        credentials.savePushCredential(PushCredential(account: a, password: "fixture", sessionId: "new-manual-sid"))
        PushContractURLProtocol.releaseHeld()
        await expectFailure { _ = try await work.value }
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities"])
    }

    func test_apporo_explicitAccountSelection_invalidatesPendingManualLogin() async throws {
        let persistence = PersistenceController(inMemory: true)
        OdooAccountEntity(context: persistence.container.viewContext).update(from: b)
        try persistence.container.viewContext.save()
        let repository = AccountRepository(persistence: persistence, apiClient: api,
                                           brand: .apporo, pushCredentials: credentials)
        let held = expectation(description: "Manual login held")
        PushContractURLProtocol.reset([.heldAuth("superseded-response")])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                        username: a.username, password: "fixture") }
        await fulfillment(of: [held], timeout: 2)
        XCTAssertTrue(repository.activateAccount(id: b.id))
        PushContractURLProtocol.releaseHeld()
        guard case .error = await work.value else { return XCTFail("Superseded login activated") }
        XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
        XCTAssertEqual(repository.getAllAccounts().map(\.id), [b.id])
        XCTAssertNil(api.getSessionId(for: a.fullServerUrl))
    }

    func test_apporo_cleanupCapturedBeforeRemoval_stillWritesWithCapturedSession() async throws {
        let held = expectation(description: "Cleanup capability held")
        var capability = PushContractURLProtocol.Reply.result(Self.cap)
        capability.hold = true
        PushContractURLProtocol.reset([capability, .result(true)])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { try await registrar().unregister(account: a, token: "fixture") }
        await fulfillment(of: [held], timeout: 2)
        accounts.rows = []
        credentials.deletePushCredential(accountId: a.id)
        PushContractURLProtocol.releaseHeld()
        try await work.value
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["get_push_capabilities", "unregister_device"])
        XCTAssertEqual(PushContractURLProtocol.calls.last?.cookie, "session_id=sid-a")
        XCTAssertEqual(PushContractURLProtocol.calls.last?.kwargs["app_brand"] as? String, "apporo")
    }

    func test_apporo_manualLogin_rejectedResponseDoesNotPublishSession() async {
        let repository = AccountRepository(persistence: PersistenceController(inMemory: true), apiClient: api,
                                           brand: .apporo, pushCredentials: credentials)
        PushContractURLProtocol.reset([.badPassword])
        _ = await repository.authenticate(serverUrl: a.serverUrl, database: a.database, username: a.username, password: "fixture")
        XCTAssertNil(repository.getActiveAccount())
        XCTAssertNil(api.getSessionId(for: a.fullServerUrl))
        XCTAssertEqual(PushContractURLProtocol.calls.count, 1)
    }
    func test_apporo_healHeld_manualCommitWinsWithoutOldCredentialOrError() async throws {
        for reject in [false, true] {
            let persistence = PersistenceController(inMemory: true)
            OdooAccountEntity(context: persistence.container.viewContext).update(from: a)
            try persistence.container.viewContext.save()
            let repository = AccountRepository(persistence: persistence, apiClient: api,
                brand: .apporo, pushCredentials: credentials)
            let old = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
            let held = expectation(description: "Old heal stopped before CAS")
            var reply = reject ? PushContractURLProtocol.Reply.badPassword : .auth("old-healed")
            reply.hold = true
            PushContractURLProtocol.reset([reply, .auth("manual-winner")])
            PushContractURLProtocol.onHold = { held.fulfill() }
            let work = Task { await healer.heal(account: a, credential: old, api: api,
                                                storage: credentials, accounts: repository) }
            await fulfillment(of: [held], timeout: 2)
            let login = await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                      username: a.username, password: "new-fixture")
            XCTAssertTrue(login.isSuccess)
            let winner = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
            XCTAssertNotEqual(winner.generation, old.generation)
            PushContractURLProtocol.releaseHeld()
            let outcome = await work.value
            XCTAssertEqual(outcome, .superseded)
            XCTAssertEqual(credentials.pushCredential(accountId: a.id), winner)
            XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "manual-winner")
            XCTAssertEqual(PushContractURLProtocol.calls.count, 2)
            // Restore the original binding for the second subcase.
            credentials.savePushCredential(PushCredential(account: a, password: "fixture", sessionId: "sid-a"))
        }
    }

    /// pi 1001b P2: a push heal that loses the CAS (a newer manual login won while it was in flight)
    /// must best-effort revoke the session it just created and never published — and only that one.
    func test_apporo_healHeld_loserRevokesOnlyItsOwnUnpublishedSession() async throws {
        let persistence = PersistenceController(inMemory: true)
        OdooAccountEntity(context: persistence.container.viewContext).update(from: a)
        try persistence.container.viewContext.save()
        let repository = AccountRepository(persistence: persistence, apiClient: api,
            brand: .apporo, pushCredentials: credentials)
        let old = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
        let held = expectation(description: "Old heal stopped before CAS")
        PushContractURLProtocol.reset([.heldAuth("old-healed"), .auth("manual-winner")])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { await healer.heal(account: a, credential: old, api: api,
                                            storage: credentials, accounts: repository) }
        await fulfillment(of: [held], timeout: 2)
        let login = await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                  username: a.username, password: "new-fixture")
        XCTAssertTrue(login.isSuccess)
        PushContractURLProtocol.releaseHeld()
        let outcome = await work.value
        XCTAssertEqual(outcome, .superseded)
        var destroyed: [String] = []
        for _ in 0..<150 {
            destroyed = PushContractURLProtocol.destroyedCookies
            if destroyed.contains("session_id=old-healed") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(destroyed.contains("session_id=old-healed"),
                      "the losing heal revokes the session it created but never published")
        XCTAssertFalse(destroyed.contains("session_id=manual-winner"), "the winner's session is never revoked")
        XCTAssertEqual(credentials.pushCredential(accountId: a.id)?.sessionId, "manual-winner")
        credentials.savePushCredential(PushCredential(account: a, password: "fixture-password-a", sessionId: "sid-a"))
    }

    /// pi 1001c P2: a heal answered for another user (uid mismatch → `.credentialRejected`) must not
    /// revoke a session id that is the one currently stored — that session is held, not unpublished.
    func test_apporo_healUidMismatch_neverRevokesTheCurrentlyStoredSession() async throws {
        let c = OdooAccount(id: "push-c", serverUrl: "https://push.invalid:8443/base", database: "db-c",
                            username: "same", displayName: "Fixture C", userId: 99)
        let rows = PushAccounts([c])
        let stored = PushCredential(account: c, password: "fixture-password-c", sessionId: "sid-same")
        credentials.savePushCredential(stored)
        PushContractURLProtocol.reset([.auth("sid-same")])   // uid 7 ≠ 99
        let outcome = await healer.heal(account: c, credential: stored, api: api,
                                        storage: credentials, accounts: rows)
        XCTAssertEqual(outcome, .credentialRejected)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(PushContractURLProtocol.destroyedCookies.contains("session_id=sid-same"),
                       "the currently stored session is never revoked as 'unpublished'")
        credentials.deletePushCredential(accountId: c.id)
    }

    func test_apporo_healHeld_removeWinsWithoutResurrection() async throws {
        for logout in [false, true] {
            let persistence = PersistenceController(inMemory: true)
            OdooAccountEntity(context: persistence.container.viewContext).update(from: a)
            try persistence.container.viewContext.save()
            let repository = AccountRepository(persistence: persistence, apiClient: api,
                brand: .apporo, pushCredentials: credentials)
            credentials.savePushCredential(PushCredential(account: a, password: "fixture", sessionId: "sid-a"))
            let old = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
            let held = expectation(description: "Heal held before remove")
            PushContractURLProtocol.reset([.heldAuth("must-not-resurrect")])
            PushContractURLProtocol.onHold = { held.fulfill() }
            let work = Task { await healer.heal(account: a, credential: old, api: api,
                                                storage: credentials, accounts: repository) }
            await fulfillment(of: [held], timeout: 2)
            SecureStorage.shared.deleteFcmToken()
            if logout { await repository.logout(accountId: a.id) }
            else { await repository.removeAccount(id: a.id) }
            PushContractURLProtocol.releaseHeld()
            let outcome = await work.value
            XCTAssertEqual(outcome, .superseded)
            XCTAssertNil(credentials.pushCredential(accountId: a.id))
            XCTAssertTrue(repository.getAllAccounts().isEmpty)
            XCTAssertEqual(PushContractURLProtocol.calls.count, 1)
        }
    }

    func test_apporo_oldRegisterCompletionOrError_cannotOverwriteNewGenerationStatusOrTenant() async throws {
        for failure in [false, true] {
            let held = expectation(description: "Old register held")
            var old = failure ? PushContractURLProtocol.Reply.expired : .result(Self.ack.merging(
                ["odoo_tenant_id": "old-tenant"]) { _, new in new })
            old.hold = true
            PushContractURLProtocol.reset([.result(Self.cap), old, .result(Self.cap), .result(Self.ack)])
            PushContractURLProtocol.onHold = { held.fulfill() }
            let work = Task { try await register() }
            await fulfillment(of: [held], timeout: 2)
            // Same identity: only generation changes, as on a manual re-login.
            credentials.savePushCredential(PushCredential(account: a, password: "new", sessionId: "new-generation"))
            _ = try await register()
            PushContractURLProtocol.releaseHeld()
            await expectFailure { _ = try await work.value }
            XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .acknowledged)
            XCTAssertEqual(accounts.tenantWrites[a.id], "fixture-tenant")
            XCTAssertEqual(PushContractURLProtocol.calls.count, 4)
        }
    }

    func test_apporo_oldUnregisterCompletionOrError_cannotOverwriteNewGenerationStatus() async throws {
        for failure in [false, true] {
            let held = expectation(description: "Old unregister held")
            var old = failure ? PushContractURLProtocol.Reply.expired : .result(true)
            old.hold = true
            PushContractURLProtocol.reset([.result(Self.cap), old, .result(Self.cap), .result(Self.ack)])
            PushContractURLProtocol.onHold = { held.fulfill() }
            let work = Task { try await registrar().unregister(account: a, token: "old-token") }
            await fulfillment(of: [held], timeout: 2)
            credentials.savePushCredential(PushCredential(account: a, password: "new", sessionId: "new-generation"))
            _ = try await register()
            PushContractURLProtocol.releaseHeld()
            if failure { await expectFailure { try await work.value } }
            else { try await work.value }
            XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .acknowledged)
            XCTAssertEqual(accounts.tenantWrites[a.id], "fixture-tenant")
            XCTAssertEqual(PushContractURLProtocol.calls.count, 4)
        }
    }

    func test_apporo_sameGeneration_operationRevisionRejectsOlderAck() async throws {
        let held = expectation(description: "Older registration response held")
        var old = PushContractURLProtocol.Reply.result(Self.ack)
        old.hold = true
        PushContractURLProtocol.reset([.result(Self.cap), old, .result(Self.cap), .result(true)])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { try await register() }
        await fulfillment(of: [held], timeout: 2)
        try await registrar().unregister(account: a, token: "fixture")
        PushContractURLProtocol.releaseHeld()
        await expectFailure { _ = try await work.value }
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .notRegistered)
        XCTAssertNil(accounts.tenantWrites[a.id])
    }

    func test_apporo_identityChangesDuringResponse_noStatusOrTenantCommit() async throws {
        let held = expectation(description: "Register response held")
        var reply = PushContractURLProtocol.Reply.result(Self.ack)
        reply.hold = true
        PushContractURLProtocol.reset([.result(Self.cap), reply])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { try await register() }
        await fulfillment(of: [held], timeout: 2)
        accounts.rows = [OdooAccount(id: a.id, serverUrl: a.serverUrl,
            database: "changed-db", username: a.username, displayName: "Changed")]
        PushRegistrationStatusStore.shared.set(.notRegistered, for: a.id)
        PushContractURLProtocol.releaseHeld()
        await expectFailure { _ = try await work.value }
        XCTAssertNil(accounts.tenantWrites[a.id])
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .notRegistered)
    }

    func test_apporo_capturedCleanupStartingAfterNewGeneration_doesNotSupersedeItsOperation() async throws {
        let old = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
        credentials.savePushCredential(PushCredential(account: a, password: "new", sessionId: "new-generation"))
        let held = expectation(description: "New registration response held")
        var reply = PushContractURLProtocol.Reply.result(Self.ack)
        reply.hold = true
        PushContractURLProtocol.reset([.result(Self.cap), reply, .result(Self.cap), .result(true)])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { try await register() }
        await fulfillment(of: [held], timeout: 2)
        try await registrar().unregister(account: a, token: "old", capturedCredential: old)
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .registering)
        PushContractURLProtocol.releaseHeld()
        _ = try await work.value
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .acknowledged)
        XCTAssertEqual(accounts.tenantWrites[a.id], "fixture-tenant")
        XCTAssertEqual(PushContractURLProtocol.calls.last?.cookie, "session_id=sid-a")
    }

    func test_apporo_removeHeldCleanup_newManualLoginSurvivesRemoteCompletion() async throws {
        let persistence = PersistenceController(inMemory: true)
        OdooAccountEntity(context: persistence.container.viewContext).update(from: a)
        try persistence.container.viewContext.save()
        let repository = AccountRepository(persistence: persistence, apiClient: api,
            brand: .apporo, pushCredentials: credentials)
        SecureStorage.shared.saveFcmToken("fixture")
        let held = expectation(description: "Removed account cleanup held")
        var cap = PushContractURLProtocol.Reply.result(Self.cap)
        cap.hold = true
        PushContractURLProtocol.reset([cap, .auth("new-login"), .result(true)])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { await repository.removeAccount(id: a.id) }
        await fulfillment(of: [held], timeout: 2)
        XCTAssertTrue(repository.getAllAccounts().isEmpty)
        XCTAssertNil(credentials.pushCredential(accountId: a.id))
        let login = await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                  username: a.username, password: "new")
        XCTAssertTrue(login.isSuccess)
        let winner = try XCTUnwrap(repository.getActiveAccount())
        let credential = try XCTUnwrap(credentials.pushCredential(accountId: winner.id))
        PushContractURLProtocol.releaseHeld()
        await work.value
        XCTAssertEqual(repository.getActiveAccount()?.id, winner.id)
        XCTAssertEqual(credentials.pushCredential(accountId: winner.id), credential)
        XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: winner.id), .notRegistered)
        XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "new-login")
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method),
                       ["get_push_capabilities", "authenticate", "unregister_device"])
        XCTAssertEqual(PushContractURLProtocol.calls.last?.cookie, "session_id=sid-a")
    }

    func test_apporo_healTransientTimeoutAndServerError_preserveCredentialAndAllowNextHeal() async throws {
        var timeout = PushContractURLProtocol.Reply.result(false)
        timeout.transportError = .timedOut
        var server = PushContractURLProtocol.Reply.result(false)
        server.statusCode = 503
        for transient in [timeout, server] {
            let before = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
            PushContractURLProtocol.reset([.expired, transient])
            await expectFailure { _ = try await register() }
            XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .temporarilyUnavailable)
            XCTAssertEqual(credentials.pushCredential(accountId: a.id), before)
            PushContractURLProtocol.reset([.expired, .auth("recovered"), .result(Self.cap), .result(Self.ack)])
            _ = try await register()
            XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .acknowledged)
            XCTAssertEqual(credentials.pushCredential(accountId: a.id)?.generation, before.generation)
            XCTAssertEqual(PushContractURLProtocol.calls.map(\.method),
                ["get_push_capabilities", "authenticate", "get_push_capabilities", "register_device"])
        }
    }

    func test_apporo_typedHeal_rejectionCircuitAndTransientAreDistinct() async throws {
        let old = try XCTUnwrap(credentials.pushCredential(accountId: a.id))
        var timeout = PushContractURLProtocol.Reply.result(false)
        timeout.transportError = .timedOut
        PushContractURLProtocol.reset([timeout, .badPassword])
        let transient = await healer.heal(account: a, credential: old, api: api, storage: credentials, accounts: accounts)
        XCTAssertEqual(transient, .temporarilyUnavailable)
        let rejected = await healer.heal(account: a, credential: old, api: api, storage: credentials, accounts: accounts)
        XCTAssertEqual(rejected, .credentialRejected)
        let circuit = await healer.heal(account: a, credential: old, api: api, storage: credentials, accounts: accounts)
        XCTAssertEqual(circuit, .credentialRejected)
        XCTAssertEqual(PushContractURLProtocol.calls.count, 2)
        XCTAssertEqual(credentials.pushCredential(accountId: a.id), old)
    }

    func test_apporo_switchAccount_expiredAThroughBToA_withoutToken_reachesWebCookieConsumer() async throws {
        let repository = try switchRepository()
        SecureStorage.shared.deleteFcmToken()
        let url = try XCTUnwrap(URL(string: a.fullServerUrl + "/web/session/authenticate"))
        let oldCookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session_id", .value: "expired-a",
            .domain: "push.invalid", .path: "/base", .secure: "TRUE", .expires: Date(timeIntervalSince1970: 100)]))
        let expiredPolicy = try XCTUnwrap(PushSessionCookie(cookie: oldCookie, responseURL: url,
                                                           now: Date(timeIntervalSince1970: 0)))
        credentials.savePushCredential(PushCredential(account: a, password: "fixture-a",
            sessionId: "expired-a", sessionCookie: expiredPolicy))
        XCTAssertNil(expiredPolicy.cookie())
        XCTAssertTrue(repository.activateAccount(id: a.id))

        let expiration = oneHourCookieExpiry()
        var freshA = PushContractURLProtocol.Reply.auth("fresh-a")
        freshA.headers = ["Set-Cookie": "session_id=fresh-a; Domain=push.invalid; Path=/base; Secure; HttpOnly; Expires=\(expiration.header)"]
        PushContractURLProtocol.reset([.auth("fresh-b"), freshA])
        // These stores are private to this test; no shared/persistent WebKit data is read or cleared.
        let stores = [a.id: WKWebsiteDataStore.nonPersistent(), b.id: WKWebsiteDataStore.nonPersistent()]
        let loaded = (0..<3).map { expectation(description: "Cookie injection completed \($0)") }
        var consumed: [[HTTPCookie]] = []
        var baseRequests: [URLRequest] = []
        let coordinator = OdooWebViewCoordinator(serverUrl: a.fullServerUrl,
            onSessionExpired: { XCTFail("No navigation should run") }, isLoading: .constant(false),
            openExternalURL: { _ in XCTFail("No Safari") }, brand: .apporo, pushCredentials: credentials,
            websiteDataStore: { stores[$0]! }, loadBaseRequest: { webView, request in
                // Intercept the actual post-setCookie load point. Never call WKWebView.load.
                baseRequests.append(request)
                let index = baseRequests.count - 1
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    consumed.append(cookies)
                    loaded[index].fulfill()
                }
            })
        coordinator.apply(serverUrl: a.fullServerUrl, database: a.database, accountId: a.id,
                          sessionId: "ambient-stale", deepLink: nil)
        await fulfillment(of: [loaded[0]], timeout: 2)
        XCTAssertTrue(consumed[0].isEmpty)
        let switchedB = await repository.switchAccount(id: b.id)
        XCTAssertTrue(switchedB)
        coordinator.apply(serverUrl: b.fullServerUrl, database: b.database, accountId: b.id,
                          sessionId: "ambient-stale", deepLink: nil)
        await fulfillment(of: [loaded[1]], timeout: 2)
        XCTAssertEqual(consumed[1].first(where: { $0.name == "session_id" })?.value, "fresh-b")
        let switchedA = await repository.switchAccount(id: a.id)
        XCTAssertTrue(switchedA)
        coordinator.apply(serverUrl: a.fullServerUrl, database: a.database, accountId: a.id,
                          sessionId: "ambient-stale", deepLink: nil)
        await fulfillment(of: [loaded[2]], timeout: 2)
        let cookie = try XCTUnwrap(consumed[2].first(where: { $0.name == "session_id" }))
        XCTAssertEqual(cookie.value, "fresh-a")
        XCTAssertEqual(cookie.path, "/base")
        XCTAssertTrue(cookie.domain == "push.invalid" || cookie.domain == ".push.invalid")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.expiresDate, expiration.date)
        XCTAssertEqual(credentials.pushCredential(accountId: a.id)?.sessionId, cookie.value)
        XCTAssertEqual(repository.getActiveAccount()?.id, a.id)
        XCTAssertNil(SecureStorage.shared.getFcmToken())
        XCTAssertEqual(baseRequests.count, 3)
        XCTAssertEqual(PushContractURLProtocol.calls.map(\.method), ["authenticate", "authenticate"])
        XCTAssertTrue(PushContractURLProtocol.calls.allSatisfy { !$0.handlesCookies && $0.cookie == nil })
    }

    /// `aUserId`: the user id recorded on account A's row (the fixture's is unknown — nil).
    private func switchRepository(aUserId: Int? = nil) throws -> AccountRepository {
        let persistence = PersistenceController(inMemory: true)
        for account in [aUserId.map { accountA(userId: $0) } ?? a, b] {
            OdooAccountEntity(context: persistence.container.viewContext).update(from: account)
        }
        try persistence.container.viewContext.save()
        let repository = AccountRepository(persistence: persistence, apiClient: api,
            brand: .apporo, pushCredentials: credentials)
        XCTAssertTrue(repository.activateAccount(id: b.id))
        return repository
    }

    func test_apporo_switchAccount_missingSID_preservesActiveCredentialAndCookie() async throws {
        let repository = try switchRepository()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session_id", .value: "previous-b",
            .domain: "push.invalid", .path: "/", .secure: "TRUE"]))
        HTTPCookieStorage.shared.setCookie(cookie)
        let before = credentials.pushCredential(accountId: a.id)
        let beforeB = credentials.pushCredential(accountId: b.id)
        for reply in [PushContractURLProtocol.Reply.result(["uid": 7]), .auth("bad sid")] {
            PushContractURLProtocol.reset([reply])
            let switched = await repository.switchAccount(id: a.id)
            XCTAssertFalse(switched)
            XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
            XCTAssertEqual(credentials.pushCredential(accountId: a.id), before)
            XCTAssertEqual(credentials.pushCredential(accountId: b.id), beforeB)
            XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "previous-b")
            XCTAssertEqual(PushContractURLProtocol.calls.count, 1)
        }
    }

    func test_apporo_switchAccount_missingScopedCredential_doesNotBorrowLegacyOrActivate() async throws {
        let repository = try switchRepository()
        credentials.deletePushCredential(accountId: a.id)
        SecureStorage.shared.savePassword(accountId: a.id, password: "legacy-ambiguous")
        let beforeB = credentials.pushCredential(accountId: b.id)
        let switched = await repository.switchAccount(id: a.id)
        XCTAssertFalse(switched)
        XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
        XCTAssertNil(credentials.pushCredential(accountId: a.id))
        XCTAssertEqual(credentials.pushCredential(accountId: b.id), beforeB)
        XCTAssertTrue(PushContractURLProtocol.calls.isEmpty)
    }

    private func accountA(userId: Int) -> OdooAccount {
        OdooAccount(id: a.id, serverUrl: a.serverUrl, database: a.database, username: a.username,
                    displayName: a.displayName, userId: userId)
    }

    /// A passwordless credential whose session cookie is bound to `account`'s server.
    private func passwordlessBoundCredential(for account: OdooAccount, sessionId: String) throws -> PushCredential {
        let url = try XCTUnwrap(URL(string: account.fullServerUrl + "/web/session/authenticate"))
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session_id", .value: sessionId,
            .domain: "push.invalid", .path: "/base", .secure: "TRUE"]))
        let policy = try XCTUnwrap(PushSessionCookie(cookie: cookie, responseURL: url))
        return PushCredential(account: account, password: "", sessionId: sessionId, sessionCookie: policy)
    }

    /// B's session in the jar, and a relogin baseline so a request for A is this test's own.
    private func putPreviousJarSession() throws {
        ReloginSignal.shared.requestRelogin(accountId: "baseline")
        HTTPCookieStorage.shared.setCookie(try XCTUnwrap(HTTPCookie(properties: [.name: "session_id",
            .value: "previous-b", .domain: "push.invalid", .path: "/", .secure: "TRUE"])))
    }

    /// pi 1001g: a passwordless switch needs a usable bound cookie AND the server's proof that the
    /// session is still this account's (known user id, same uid and database) — one isolated
    /// `get_session_info` call, never an authenticate. Without a cookie nothing is asked at all.
    func test_apporo_switchAccount_withoutPassword_requiresUsableBoundCookie() async throws {
        let repository = try switchRepository(aUserId: 7)
        let a7 = accountA(userId: 7)
        credentials.savePushCredential(PushCredential(account: a7, password: "", sessionId: "no-policy"))
        let rejected = await repository.switchAccount(id: a.id)
        XCTAssertFalse(rejected)
        XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
        XCTAssertTrue(PushContractURLProtocol.sessionCheckCookies.isEmpty, "no cookie — nothing to prove")
        let bound = try passwordlessBoundCredential(for: a7, sessionId: "bound-a")
        credentials.savePushCredential(bound)
        PushContractURLProtocol.sessionInfoReply = .result(["uid": 7, "db": "db-a"])
        let switched = await repository.switchAccount(id: a.id)
        XCTAssertTrue(switched)
        XCTAssertEqual(repository.getActiveAccount()?.id, a.id)
        XCTAssertEqual(credentials.pushCredential(accountId: a.id), bound)
        XCTAssertEqual(PushContractURLProtocol.sessionCheckCookies, ["session_id=bound-a"],
                       "the session is proven with ONLY its own cookie before the switch commits")
        XCTAssertTrue(PushContractURLProtocol.calls.isEmpty, "no authenticate / call_kw")
    }

    /// pi 1001g (P1): A's user id is unknown and A's passwordless credential carries the session of
    /// another user (C, uid 99) of the same database. Nothing proves it is A's — fail closed: B stays
    /// active, the jar is untouched, A is asked to sign in again.
    func test_apporo_passwordlessSwitch_unknownUserId_otherUsersSessionSameDatabase_doesNotSwitch() async throws {
        let repository = try switchRepository()
        try putPreviousJarSession()
        credentials.savePushCredential(try passwordlessBoundCredential(for: a, sessionId: "sid-c"))
        let beforeB = credentials.pushCredential(accountId: b.id)
        PushContractURLProtocol.sessionInfoReply = .result(["uid": 99, "db": "db-a"])

        let switched = await repository.switchAccount(id: a.id)

        XCTAssertFalse(switched)
        XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
        XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "previous-b", "C's session is never published")
        XCTAssertEqual(credentials.pushCredential(accountId: b.id), beforeB)
        XCTAssertEqual(ReloginSignal.shared.lastRequestedAccountId, a.id)
    }

    /// pi 1001g (P1): A's user id is known, but the server says the session belongs to another user.
    func test_apporo_passwordlessSwitch_knownUserIdButSessionOfAnotherUser_doesNotSwitch() async throws {
        let repository = try switchRepository(aUserId: 7)
        try putPreviousJarSession()
        credentials.savePushCredential(try passwordlessBoundCredential(for: accountA(userId: 7), sessionId: "sid-c"))
        PushContractURLProtocol.sessionInfoReply = .result(["uid": 99, "db": "db-a"])

        let switched = await repository.switchAccount(id: a.id)

        XCTAssertFalse(switched)
        XCTAssertEqual(PushContractURLProtocol.sessionCheckCookies, ["session_id=sid-c"])
        XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
        XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "previous-b")
        XCTAssertEqual(ReloginSignal.shared.lastRequestedAccountId, a.id)
    }

    /// pi 1001g (P1): no answer from the server is no proof either.
    func test_apporo_passwordlessSwitch_sessionCheckUnreachable_doesNotSwitch() async throws {
        let repository = try switchRepository(aUserId: 7)
        try putPreviousJarSession()
        credentials.savePushCredential(try passwordlessBoundCredential(for: accountA(userId: 7), sessionId: "sid-a7"))
        var unreachable = PushContractURLProtocol.Reply.result(["uid": 7, "db": "db-a"])
        unreachable.transportError = .notConnectedToInternet
        PushContractURLProtocol.sessionInfoReply = unreachable

        let switched = await repository.switchAccount(id: a.id)

        XCTAssertFalse(switched)
        XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
        XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "previous-b")
        XCTAssertEqual(ReloginSignal.shared.lastRequestedAccountId, a.id)
    }

    /// pi 1001g: the proven case — known user id, same uid and database — switches and publishes.
    func test_apporo_passwordlessSwitch_sessionProvenForThisUserAndDatabase_switches() async throws {
        let repository = try switchRepository(aUserId: 7)
        try putPreviousJarSession()
        let bound = try passwordlessBoundCredential(for: accountA(userId: 7), sessionId: "sid-a7")
        credentials.savePushCredential(bound)
        PushContractURLProtocol.sessionInfoReply = .result(["uid": 7, "db": "db-a"])

        let switched = await repository.switchAccount(id: a.id)

        XCTAssertTrue(switched)
        XCTAssertEqual(PushContractURLProtocol.sessionCheckCookies, ["session_id=sid-a7"])
        XCTAssertEqual(repository.getActiveAccount()?.id, a.id)
        XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "sid-a7")
        XCTAssertEqual(credentials.pushCredential(accountId: a.id), bound)
    }

    func test_apporo_switchHeld_newerManualLoginWinsSelectionCredentialAndCookie() async throws {
        let repository = try switchRepository()
        let held = expectation(description: "Switch auth held")
        PushContractURLProtocol.reset([.heldAuth("stale-switch"), .auth("manual-winner")])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { await repository.switchAccount(id: a.id) }
        await fulfillment(of: [held], timeout: 2)
        let manual = await repository.authenticate(serverUrl: a.fullServerUrl, database: a.database,
            username: a.username, password: "new-password")
        XCTAssertTrue(manual.isSuccess)
        let winner = credentials.pushCredential(accountId: a.id)
        PushContractURLProtocol.releaseHeld()
        let stale = await work.value
        XCTAssertFalse(stale)
        XCTAssertEqual(repository.getActiveAccount()?.id, a.id)
        XCTAssertEqual(credentials.pushCredential(accountId: a.id), winner)
        XCTAssertEqual(api.getSessionId(for: a.fullServerUrl), "manual-winner")
    }

    func test_apporo_manualHeld_newerSwitchWinsSelectionCredentialAndCookie() async throws {
        let repository = try switchRepository()
        let held = expectation(description: "Manual auth held")
        PushContractURLProtocol.reset([.heldAuth("stale-manual"), .auth("switch-winner")])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { await repository.authenticate(serverUrl: a.fullServerUrl, database: a.database,
            username: a.username, password: "old-password") }
        await fulfillment(of: [held], timeout: 2)
        let switched = await repository.switchAccount(id: b.id)
        XCTAssertTrue(switched)
        let winner = credentials.pushCredential(accountId: b.id)
        let beforeA = credentials.pushCredential(accountId: a.id)
        PushContractURLProtocol.releaseHeld()
        let stale = await work.value
        XCTAssertFalse(stale.isSuccess)
        XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
        XCTAssertEqual(credentials.pushCredential(accountId: b.id), winner)
        XCTAssertEqual(credentials.pushCredential(accountId: a.id), beforeA)
        XCTAssertEqual(api.getSessionId(for: b.fullServerUrl), "switch-winner")
    }

    func test_apporo_switchHeld_newerSwitchWinsSelectionCredentialAndCookie() async throws {
        let repository = try switchRepository()
        let beforeA = credentials.pushCredential(accountId: a.id)
        let held = expectation(description: "First switch auth held")
        PushContractURLProtocol.reset([.heldAuth("stale-switch"), .auth("switch-winner")])
        PushContractURLProtocol.onHold = { held.fulfill() }
        let work = Task { await repository.switchAccount(id: a.id) }
        await fulfillment(of: [held], timeout: 2)
        let switched = await repository.switchAccount(id: b.id)
        XCTAssertTrue(switched)
        let winner = credentials.pushCredential(accountId: b.id)
        PushContractURLProtocol.releaseHeld()
        let stale = await work.value
        XCTAssertFalse(stale)
        XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
        XCTAssertEqual(credentials.pushCredential(accountId: a.id), beforeA)
        XCTAssertEqual(credentials.pushCredential(accountId: b.id), winner)
        XCTAssertEqual(api.getSessionId(for: b.fullServerUrl), "switch-winner")
    }

    func test_apporo_switchHeld_changedIdentityOrGeneration_rejectsCommit() async throws {
        for changeIdentity in [false, true] {
            let persistence = PersistenceController(inMemory: true)
            let entity = OdooAccountEntity(context: persistence.container.viewContext)
            entity.update(from: a)
            OdooAccountEntity(context: persistence.container.viewContext).update(from: b)
            try persistence.container.viewContext.save()
            let repository = AccountRepository(persistence: persistence, apiClient: api,
                brand: .apporo, pushCredentials: credentials)
            XCTAssertTrue(repository.activateAccount(id: b.id))
            let held = expectation(description: "Switch auth held before revalidation")
            PushContractURLProtocol.reset([.heldAuth("stale-binding")])
            PushContractURLProtocol.onHold = { held.fulfill() }
            let work = Task { await repository.switchAccount(id: a.id) }
            await fulfillment(of: [held], timeout: 2)
            if changeIdentity {
                entity.database = "changed-database"
                try persistence.container.viewContext.save()
            } else {
                credentials.savePushCredential(PushCredential(account: a, password: "new", sessionId: "new-generation"))
            }
            let before = credentials.pushCredential(accountId: a.id)
            PushContractURLProtocol.releaseHeld()
            let switched = await work.value
            XCTAssertFalse(switched)
            XCTAssertEqual(repository.getActiveAccount()?.id, b.id)
            XCTAssertEqual(credentials.pushCredential(accountId: a.id), before)
            XCTAssertNil(api.getSessionId(for: a.fullServerUrl))
        }
    }

    func test_apporo_staleSnapshotBeginningWhileNewAckHeld_doesNotStealRevision() async throws {
        for unregister in [false, true] {
            let current = OdooAccount(id: a.id, serverUrl: a.serverUrl, database: "new-db",
                username: a.username, displayName: "Current")
            accounts.rows = [current, b]
            accounts.tenantWrites = [:]
            credentials.savePushCredential(PushCredential(account: current, password: "new", sessionId: "new-binding"))
            let held = expectation(description: "Current identity ACK held")
            var ack = PushContractURLProtocol.Reply.result(Self.ack)
            ack.hold = true
            PushContractURLProtocol.reset([.result(Self.cap), ack])
            PushContractURLProtocol.onHold = { held.fulfill() }
            let work = Task { try await register(current) }
            await fulfillment(of: [held], timeout: 2)
            do {
                if unregister { try await registrar().unregister(account: a, token: "stale") }
                else { _ = try await register(a) }
                XCTFail("Stale snapshot must be superseded at begin")
            } catch PushDeviceRegistrar.Failure.superseded { }
            catch { XCTFail("Unexpected failure: \(type(of: error))") }
            XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .registering)
            XCTAssertEqual(PushContractURLProtocol.calls.count, 2)
            PushContractURLProtocol.releaseHeld()
            _ = try await work.value
            XCTAssertEqual(PushRegistrationStatusStore.shared.status(for: a.id), .acknowledged)
            XCTAssertEqual(accounts.tenantWrites[a.id], "fixture-tenant")
        }
    }

    func test_apporo_manualCookie_keepsPathDomainSecureHttpOnlyExpiryAndWebConsumer() async throws {
        let repository = AccountRepository(persistence: PersistenceController(inMemory: true), apiClient: api,
                                           brand: .apporo, pushCredentials: credentials)
        let expiration = oneHourCookieExpiry()
        var reply = PushContractURLProtocol.Reply.auth("scoped-policy")
        reply.headers = ["Set-Cookie": "session_id=scoped-policy; Domain=push.invalid; Path=/base; Secure; HttpOnly; Expires=\(expiration.header)"]
        PushContractURLProtocol.reset([reply])
        let result = await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                   username: a.username, password: "fixture")
        XCTAssertTrue(result.isSuccess)
        let account = try XCTUnwrap(repository.getActiveAccount())
        let stored = try XCTUnwrap(credentials.pushCredential(accountId: account.id))
        let roundTrip = try JSONDecoder().decode(PushCredential.self, from: JSONEncoder().encode(stored))
        let cookie = try XCTUnwrap(roundTrip.sessionCookie?.cookie())
        XCTAssertEqual(cookie.path, "/base")
        XCTAssertTrue(cookie.domain == "push.invalid" || cookie.domain == ".push.invalid")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
        XCTAssertEqual(cookie.expiresDate, expiration.date)
        let published = try XCTUnwrap(HTTPCookieStorage.shared.cookies(for: URL(string: a.fullServerUrl + "/web")!)?.first { $0.name == "session_id" })
        XCTAssertEqual(published.properties as NSDictionary?, cookie.properties as NSDictionary?)
        XCTAssertFalse((HTTPCookieStorage.shared.cookies(for: URL(string: "https://push.invalid:8443/base-other/web")!) ?? []).contains { $0.value == "scoped-policy" })
        let web = try XCTUnwrap(credentials.webSessionCookie(accountId: account.id, serverURL: account.fullServerUrl, database: account.database))
        XCTAssertEqual(web.properties as NSDictionary?, cookie.properties as NSDictionary?)
        XCTAssertNil(credentials.webSessionCookie(accountId: account.id, serverURL: b.fullServerUrl, database: b.database))
        XCTAssertNil(roundTrip.sessionCookie?.cookie(now: expiration.date.addingTimeInterval(1)))
    }

    private func oneHourCookieExpiry() -> (date: Date, header: String) {
        // HTTP dates have whole-second precision. A far-future fixed year is clamped
        // by Foundation/WebKit cookie policy and does not test app preservation.
        let date = Date(timeIntervalSince1970: TimeInterval(Int(Date().timeIntervalSince1970)) + 3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return (date, formatter.string(from: date))
    }

    func test_apporo_manualCookie_invalidDomainPathAndExpiry_failClosed() async throws {
        let repository = AccountRepository(persistence: PersistenceController(inMemory: true), apiClient: api,
                                           brand: .apporo, pushCredentials: credentials)
        let before = credentials.pushCredential(accountId: a.id)
        for policy in ["Domain=other.invalid; Path=/", "Path=/base-other", "Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT", "Path=/; Max-Age=0"] {
            var reply = PushContractURLProtocol.Reply.auth("invalid-policy")
            reply.headers = ["Set-Cookie": "session_id=invalid-policy; Secure; HttpOnly; " + policy]
            PushContractURLProtocol.reset([reply])
            let result = await repository.authenticate(serverUrl: a.serverUrl, database: a.database,
                                                       username: a.username, password: "fixture")
            guard case .error(_, .serverError) = result else { return XCTFail("Invalid cookie accepted") }
            XCTAssertTrue(repository.getAllAccounts().isEmpty)
            XCTAssertEqual(credentials.pushCredential(accountId: a.id), before)
            XCTAssertNil(api.getSessionId(for: a.fullServerUrl))
            XCTAssertEqual(PushContractURLProtocol.calls.count, 1)
        }
    }

    func test_apporo_manualCookie_maxAgeDoesNotRenewAndNonSecurePolicyIsPreserved() throws {
        let url = try XCTUnwrap(URL(string: a.fullServerUrl + "/web/session/authenticate"))
        let cookie = try XCTUnwrap(HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "session_id=policy-fixture; Path=/base; Max-Age=60; HttpOnly"], for: url).first)
        let snapshot = try XCTUnwrap(PushSessionCookie(cookie: cookie, responseURL: url))
        let saved = try XCTUnwrap(snapshot.cookie())
        XCTAssertFalse(saved.isSecure)
        XCTAssertTrue(saved.isHTTPOnly)
        let expiry = try XCTUnwrap(saved.expiresDate)
        XCTAssertEqual(snapshot.cookie(now: expiry.addingTimeInterval(-1))?.expiresDate, expiry)
        XCTAssertNil(snapshot.cookie(now: expiry.addingTimeInterval(1)))
        XCTAssertNil(saved.properties?[.maximumAge])
    }

}

private final class PushCredentials: PushCredentialStorage, Sendable {
    @MainActor private var values: [String: PushCredential] = [:]
    @MainActor func pushCredential(accountId: String) -> PushCredential? { values[accountId] }
    @MainActor func savePushCredential(_ credential: PushCredential) { values[credential.accountId] = credential }
    @MainActor func deletePushCredential(accountId: String) { values.removeValue(forKey: accountId) }
}

private final class PushAccounts: AccountRepositoryProtocol, @unchecked Sendable {
    var rows: [OdooAccount]
    var tenantWrites: [String: String] = [:]
    init(_ rows: [OdooAccount]) { self.rows = rows }
    func getAllAccounts() -> [OdooAccount] { rows }
    func getActiveAccount() -> OdooAccount? { rows.first }
    func getAccount(byTenantId tenantId: String) -> OdooAccount? { rows.first { $0.tenantId == tenantId } }
    func authenticate(serverUrl: String, database: String, username: String, password: String) async -> AuthResult { .error("fixture", .unknown) }
    func switchAccount(id: String) async -> Bool { true }
    func activateAccount(id: String) -> Bool { true }
    func setTenantId(_ tenantId: String, forServerUrl serverUrl: String) { }
    func setTenantId(_ tenantId: String, forAccountId accountId: String) { tenantWrites[accountId] = tenantId }
    func logout(accountId: String?) async { }
    func removeAccount(id: String) async { }
    func getSessionId(for serverUrl: String) -> String? { nil }
}

private final class PushContractURLProtocol: URLProtocol {
    struct Call {
        let url: String
        let method: String
        let params: [String: Any]
        let kwargs: [String: Any]
        let args: [Any]
        let cookie: String?
        let handlesCookies: Bool
    }
    struct Reply {
        let envelope: [String: Any]
        var headers: [String: String] = [:]
        var hold = false
        var transportError: URLError.Code?
        var statusCode = 200
        static func result(_ result: Any) -> Reply { Reply(envelope: ["jsonrpc": "2.0", "id": "r1", "result": result]) }
        static let expired = Reply(envelope: ["error": ["code": 100, "message": "Odoo Session Expired"]])
        static let serverError = Reply(envelope: ["error": ["code": 200, "message": "Unknown method"]])
        static let badPassword = Reply(envelope: ["error": ["code": 200, "message": "Invalid credentials"]])
        static func heldAuth(_ sid: String) -> Reply {
            var reply = auth(sid); reply.hold = true; return reply
        }
        static func auth(_ sid: String) -> Reply {
            Reply(envelope: ["result": ["uid": 7, "name": "Fixture"]],
                  headers: ["Set-Cookie": "session_id=\(sid); Path=/; Secure; HttpOnly"])
        }
    }
    private static let lock = NSLock()
    private static var recorded: [Call] = []
    private static var replies: [Reply] = []
    /// D1/D5 (2026-09-29) session housekeeping is answered OUTSIDE the reply queue, so it can never
    /// consume a reply a test sequenced for authenticate/call_kw: `/web/session/destroy` (logout and
    /// switch revoke the replaced session, detached) and `/web/session/get_session_info` (a switch
    /// probes the target's stored session first). Session checks answer `sessionInfoReply`, which
    /// defaults to expired — the re-authenticate flows these tests were written for.
    private static var destroyed: [String] = []
    private static var checks: [String] = []
    static var sessionInfoReply: Reply = .expired
    static var destroyedCookies: [String] { lock.lock(); defer { lock.unlock() }; return destroyed }
    static var sessionCheckCookies: [String] { lock.lock(); defer { lock.unlock() }; return checks }
    private static var held: [(PushContractURLProtocol, Reply)] = []
    static var onHold: (() -> Void)?
    static func releaseHeld() {
        lock.lock(); let pending = held; held = []; lock.unlock()
        for (transport, reply) in pending { transport.deliver(reply) }
    }
    static var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset(_ replies: [Reply] = []) {
        lock.lock(); defer { lock.unlock() }
        recorded = []; self.replies = replies; held = []; onHold = nil
        destroyed = []; checks = []; sessionInfoReply = .expired
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // Accounts in this suite live under a path prefix (`…/base`), so match the endpoint suffix.
        let path = request.url?.path ?? ""
        switch true {
        case path.hasSuffix("/web/session/destroy"):
            Self.lock.lock(); Self.destroyed.append(request.value(forHTTPHeaderField: "Cookie") ?? ""); Self.lock.unlock()
            return deliver(.result(NSNull()))
        case path.hasSuffix("/web/session/get_session_info"):
            Self.lock.lock(); Self.checks.append(request.value(forHTTPHeaderField: "Cookie") ?? "")
            let reply = Self.sessionInfoReply; Self.lock.unlock()
            return deliver(reply)
        default:
            break
        }
        do {
            let root = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any]
            let params = root?["params"] as? [String: Any] ?? [:]
            let method = params["method"] as? String ?? "authenticate"
            Self.lock.lock()
            Self.recorded.append(Call(url: request.url!.absoluteString, method: method, params: params,
                kwargs: params["kwargs"] as? [String: Any] ?? [:], args: params["args"] as? [Any] ?? [],
                cookie: request.value(forHTTPHeaderField: "Cookie"), handlesCookies: request.httpShouldHandleCookies))
            let reply = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
            Self.lock.unlock()
            guard let reply else { throw URLError(.cannotConnectToHost) }
            if reply.hold {
                Self.lock.lock(); Self.held.append((self, reply)); let callback = Self.onHold; Self.lock.unlock()
                callback?()
            } else { deliver(reply) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func deliver(_ reply: Reply) {
        do {
            if let code = reply.transportError { throw URLError(code) }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.statusCode, httpVersion: nil, headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: reply.envelope))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
