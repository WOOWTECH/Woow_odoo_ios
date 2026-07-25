//
//  FcmTokenReconcileTests.swift
//  odooTests
//
//  S2 (client reconcile, LEAN) — T-I1 / AC8.
//
//  Verifies the event-driven upsert reconcile: on account-restored (cold-start),
//  login, and account-switch — IN ADDITION to `didReceiveRegistrationToken` — the
//  client upserts the CURRENT token for every logged-in account. This fixes the
//  iOS token-arrives-before-account race (AC8.b): a token Firebase delivered before
//  any account existed is registered as soon as an account appears.
//
//  Hermetic: a fake `PushTokenRepositoryProtocol` records the register calls — no
//  real DNS, no network. No diff-set / tri-state is asserted or required (AC8.c);
//  a redundant trigger simply fires another cheap upsert (server early-return).
//

import XCTest
@testable import odoo

@MainActor
final class FcmTokenReconcileTests: XCTestCase {

    // MARK: - AC8.b — account-restored (cold-start) triggers register-for-all

    /// A token already delivered by Firebase, an active account restored on cold start:
    /// `checkSession()` must upsert that token for all accounts.
    func test_checkSession_givenActiveAccountAndStoredToken_reconcilesTokenForAllAccounts() {
        let account = makeAccount()
        let accountRepo = MockAccountRepository()
        accountRepo.stubbedActiveAccount = account
        let pushRepo = MockPushTokenRepository(storedToken: "tok-restore")

        let registered = expectation(description: "register fires on cold-start restore")
        pushRepo.onRegister = { registered.fulfill() }

        let sut = AppRootViewModel(accountRepository: accountRepo, pushTokenRepository: pushRepo)
        sut.checkSession()

        wait(for: [registered], timeout: 1.0)
        XCTAssertEqual(sut.launchState, .authenticated)
        XCTAssertEqual(pushRepo.registeredTokens, ["tok-restore"],
                       "cold-start restore must upsert the current token for all accounts")
    }

    /// The exact AC8.b race: a token arrived BEFORE any account existed (so
    /// `didReceiveRegistrationToken` registered to zero accounts). Once an account
    /// appears and `checkSession()` runs, the stored token is finally registered.
    func test_tokenArrivedBeforeAccount_thenAccountRestored_registerFires() {
        // Simulate the race: Firebase already saved a token; at that time there were no
        // accounts, so nothing was registered (registeredTokens is still empty).
        let pushRepo = MockPushTokenRepository()
        pushRepo.saveToken("tok-early")
        XCTAssertTrue(pushRepo.registeredTokens.isEmpty,
                      "precondition: token arrived before any account — nothing registered yet")

        let accountRepo = MockAccountRepository()
        accountRepo.stubbedActiveAccount = makeAccount()

        let registered = expectation(description: "register fires once account appears")
        pushRepo.onRegister = { registered.fulfill() }

        let sut = AppRootViewModel(accountRepository: accountRepo, pushTokenRepository: pushRepo)
        sut.checkSession()

        wait(for: [registered], timeout: 1.0)
        XCTAssertEqual(pushRepo.registeredTokens, ["tok-early"],
                       "the pre-account token must be registered as soon as an account is restored")
    }

    /// No active account (first launch / logged out): the reconcile must NOT fire —
    /// there is nothing to register against.
    func test_checkSession_givenNoActiveAccount_doesNotReconcile() {
        let accountRepo = MockAccountRepository()
        accountRepo.stubbedActiveAccount = nil
        let pushRepo = MockPushTokenRepository(storedToken: "tok-unused")

        let noRegister = expectation(description: "register must not fire without an account")
        noRegister.isInverted = true
        pushRepo.onRegister = { noRegister.fulfill() }

        let sut = AppRootViewModel(accountRepository: accountRepo, pushTokenRepository: pushRepo)
        sut.checkSession()

        wait(for: [noRegister], timeout: 0.3)
        XCTAssertEqual(sut.launchState, .login)
        XCTAssertTrue(pushRepo.registeredTokens.isEmpty)
    }

    /// Active account but no token yet (Firebase hasn't delivered one): reconcile is a
    /// safe no-op — no crash, no register call.
    func test_checkSession_givenActiveAccountButNoToken_skipsRegister() {
        let accountRepo = MockAccountRepository()
        accountRepo.stubbedActiveAccount = makeAccount()
        let pushRepo = MockPushTokenRepository(storedToken: nil)

        let noRegister = expectation(description: "register must not fire without a token")
        noRegister.isInverted = true
        pushRepo.onRegister = { noRegister.fulfill() }

        let sut = AppRootViewModel(accountRepository: accountRepo, pushTokenRepository: pushRepo)
        sut.checkSession()

        wait(for: [noRegister], timeout: 0.3)
        XCTAssertEqual(sut.launchState, .authenticated)
        XCTAssertTrue(pushRepo.registeredTokens.isEmpty)
    }

    // MARK: - AC8.a/b — login triggers register-for-all

    /// `onLoginSuccess()` upserts the current token for all accounts (the already-shipped
    /// account-before-token path — kept working through the extracted reconcile).
    func test_onLoginSuccess_reconcilesTokenForAllAccounts() {
        let accountRepo = MockAccountRepository()
        let pushRepo = MockPushTokenRepository(storedToken: "tok-login")

        let registered = expectation(description: "register fires on login")
        pushRepo.onRegister = { registered.fulfill() }

        let sut = AppRootViewModel(accountRepository: accountRepo, pushTokenRepository: pushRepo)
        sut.onLoginSuccess()

        wait(for: [registered], timeout: 1.0)
        XCTAssertEqual(sut.launchState, .authenticated)
        XCTAssertEqual(pushRepo.registeredTokens, ["tok-login"])
    }

    // MARK: - AC8.c — redundant triggers are safe (no diff-set / tri-state)

    /// Firing the reconcile repeatedly (cold-start restore then a foreground re-check) is
    /// harmless: each trigger simply re-upserts the current token. The server early-return
    /// makes the redundant re-post a cheap no-op — the client keeps no diff-set to protect.
    func test_redundantReconcileTriggers_areSafe() {
        let accountRepo = MockAccountRepository()
        accountRepo.stubbedActiveAccount = makeAccount()
        let pushRepo = MockPushTokenRepository(storedToken: "tok-repeat")

        let registeredTwice = expectation(description: "register fires for each trigger")
        registeredTwice.expectedFulfillmentCount = 2
        pushRepo.onRegister = { registeredTwice.fulfill() }

        let sut = AppRootViewModel(accountRepository: accountRepo, pushTokenRepository: pushRepo)
        sut.checkSession()
        sut.checkSession()

        wait(for: [registeredTwice], timeout: 1.0)
        XCTAssertEqual(pushRepo.registeredTokens, ["tok-repeat", "tok-repeat"],
                       "redundant triggers each re-upsert the same current token, safely")
    }

    // MARK: - AC8.b — account-switch triggers register-for-all

    /// Switching to another account is an "account-added/available" event: the current
    /// token must be upserted for all accounts so the newly-active account is covered.
    func test_switchAccount_success_reconcilesTokenForAllAccounts() async {
        let accountRepo = MockAccountRepository()
        accountRepo.stubbedSwitchResult = true
        let pushRepo = MockPushTokenRepository(storedToken: "tok-switch")

        let registered = expectation(description: "register fires on successful switch")
        pushRepo.onRegister = { registered.fulfill() }

        let sut = ConfigViewModel(accountRepository: accountRepo, pushTokenRepository: pushRepo)
        let ok = await sut.switchAccount(id: "acct-2")

        XCTAssertTrue(ok)
        await fulfillment(of: [registered], timeout: 1.0)
        XCTAssertEqual(pushRepo.registeredTokens, ["tok-switch"])
    }

    /// A failed switch must NOT reconcile — the active account did not change.
    func test_switchAccount_failure_doesNotReconcile() async {
        let accountRepo = MockAccountRepository()
        accountRepo.stubbedSwitchResult = false
        let pushRepo = MockPushTokenRepository(storedToken: "tok-switch")

        let noRegister = expectation(description: "register must not fire on failed switch")
        noRegister.isInverted = true
        pushRepo.onRegister = { noRegister.fulfill() }

        let sut = ConfigViewModel(accountRepository: accountRepo, pushTokenRepository: pushRepo)
        let ok = await sut.switchAccount(id: "acct-2")

        XCTAssertFalse(ok)
        await fulfillment(of: [noRegister], timeout: 0.3)
        XCTAssertTrue(pushRepo.registeredTokens.isEmpty)
    }

    // MARK: - Helpers

    private func makeAccount() -> OdooAccount {
        OdooAccount(
            id: UUID().uuidString,
            serverUrl: "https://myodoo.com",
            database: "prod_db",
            username: "alan@woow.com",
            displayName: "Test User",
            isActive: true
        )
    }
}
