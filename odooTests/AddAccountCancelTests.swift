//
//  AddAccountCancelTests.swift
//  odooTests
//
//  demo111 live run 2026-09-29 (D3): "Add Account" switched the root to the login form with no
//  way back — swipe-down and edge-swipe did nothing, only killing the app returned to the account
//  the user was already signed in to. `beginAddAccount()` must remember that a return path exists
//  and `cancelAddAccount()` must go back to the active account without touching any account.
//
//  Cancelling must not become an App Lock bypass: while the add-account form is up, a real
//  background still has to re-lock, so the gate re-prompts when the user cancels back.
//

import XCTest
@testable import odoo

@MainActor
final class AddAccountCancelTests: XCTestCase {

    private func account() -> OdooAccount {
        OdooAccount(id: UUID().uuidString, serverUrl: "https://myodoo.com", database: "prod_db",
                    username: "alan@example.com", displayName: "Alan", isActive: true)
    }

    func test_beginAddAccount_withActiveAccount_offersCancel() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = account()
        let sut = AppRootViewModel(accountRepository: repo)
        sut.checkSession()

        sut.beginAddAccount()

        XCTAssertEqual(sut.launchState, .login)
        XCTAssertTrue(sut.canCancelAddAccount, "an active account exists, so the form needs a way back")
    }

    func test_cancelAddAccount_returnsToActiveAccountWithoutChangingAccounts() {
        let repo = MockAccountRepository()
        let active = account()
        repo.stubbedActiveAccount = active
        let sut = AppRootViewModel(accountRepository: repo)
        sut.checkSession()
        sut.beginAddAccount()

        sut.cancelAddAccount()

        XCTAssertEqual(sut.launchState, .authenticated)
        XCTAssertFalse(sut.canCancelAddAccount)
        XCTAssertEqual(repo.getActiveAccount()?.id, active.id, "cancel must not switch or remove accounts")
        XCTAssertTrue(repo.activatedAccountIds.isEmpty, "cancel must not activate any account")
    }

    func test_plainLogin_withoutAccount_offersNoCancel() {
        let repo = MockAccountRepository()
        let sut = AppRootViewModel(accountRepository: repo)
        sut.checkSession()

        XCTAssertEqual(sut.launchState, .login)
        XCTAssertFalse(sut.canCancelAddAccount, "first-run login has nothing to go back to")

        sut.cancelAddAccount()
        XCTAssertEqual(sut.launchState, .login, "cancel is a no-op when there is no account")
    }

    func test_cancelAddAccount_afterActiveAccountVanished_staysOnLogin() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = account()
        let sut = AppRootViewModel(accountRepository: repo)
        sut.checkSession()
        sut.beginAddAccount()
        repo.stubbedActiveAccount = nil

        sut.cancelAddAccount()

        XCTAssertEqual(sut.launchState, .login, "never show main content without an active account")
        XCTAssertFalse(sut.canCancelAddAccount)
    }

    func test_loginSuccess_clearsCancelOffer() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = account()
        let sut = AppRootViewModel(accountRepository: repo)
        sut.checkSession()
        sut.beginAddAccount()

        sut.onLoginSuccess()

        XCTAssertFalse(sut.canCancelAddAccount)
    }

    func test_sessionExpiryLogin_clearsCancelOffer() async {
        let repo = MockAccountRepository()
        let sut = AppRootViewModel(accountRepository: repo)
        repo.stubbedActiveAccount = account()
        sut.checkSession()
        sut.beginAddAccount()
        repo.stubbedActiveAccount = nil

        await sut.attemptSelfHealOrLogin()

        XCTAssertEqual(sut.launchState, .login)
        XCTAssertFalse(sut.canCancelAddAccount, "a forced re-login is not an add-account form")
    }

    /// App Lock: the add-account form sits in front of a signed-in account, so a background must
    /// re-lock exactly as it would on the main screen; the plain first-run login need not.
    func test_relockOnBackground_coversAddAccountFormButNotFirstRunLogin() {
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = account()
        let sut = AppRootViewModel(accountRepository: repo)
        sut.checkSession()
        XCTAssertTrue(sut.shouldRelockOnBackground, "main screen")

        sut.beginAddAccount()
        XCTAssertTrue(sut.shouldRelockOnBackground, "add-account form in front of a signed-in account")

        let firstRun = AppRootViewModel(accountRepository: MockAccountRepository())
        firstRun.checkSession()
        XCTAssertFalse(firstRun.shouldRelockOnBackground, "first-run login has no content to protect")
    }
}
