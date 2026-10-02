//
//  SwitchSignInRequiredTests.swift
//  odooTests
//
//  pi 1001e (P1): a switch the repository refuses because the target must sign in again (no
//  password and no valid stored session) must not fail silently — the Config screen offers that
//  account's sign-in, and the login form opens pre-filled for it.
//

import XCTest
@testable import odoo

@MainActor
final class SwitchSignInRequiredTests: XCTestCase {

    private func account(_ id: String) -> OdooAccount {
        OdooAccount(id: id, serverUrl: "https://shared.example.com", database: "db2",
                    username: "tester", displayName: "Tester (db2)")
    }

    func test_switchAccount_givenRefusedForSignIn_offersThatAccountsSignIn() async {
        let target = account("acct-b")
        let repo = MockAccountRepository()
        repo.stubbedAccounts = [target]
        repo.stubbedSwitchResult = false
        repo.onSwitch = { id in ReloginSignal.shared.requestRelogin(accountId: id) }
        let viewModel = ConfigViewModel(accountRepository: repo, pushTokenRepository: MockPushTokenRepository())

        let switched = await viewModel.switchAccount(id: target.id)

        XCTAssertFalse(switched)
        XCTAssertEqual(viewModel.signInRequiredAccount?.id, target.id)
    }

    func test_switchAccount_givenRefusedForAnotherReason_offersNoSignIn() async {
        let target = account("acct-c")
        let repo = MockAccountRepository()
        repo.stubbedAccounts = [target]
        repo.stubbedSwitchResult = false
        let viewModel = ConfigViewModel(accountRepository: repo, pushTokenRepository: MockPushTokenRepository())

        let switched = await viewModel.switchAccount(id: target.id)

        XCTAssertFalse(switched)
        XCTAssertNil(viewModel.signInRequiredAccount)
    }

    func test_loginViewModel_givenSignInAccount_prefillsItsIdentityOnTheCredentialsStep() {
        let target = account("acct-d")
        let vm = LoginViewModel(signInAccount: target, repository: MockAccountRepository(),
                                secureStorage: MockSecureStorage())

        XCTAssertEqual(vm.serverUrl, target.serverUrl)
        XCTAssertEqual(vm.database, "db2")
        XCTAssertEqual(vm.username, "tester")
        XCTAssertEqual(vm.password, "", "the password is entered by the user")
        XCTAssertEqual(vm.step, .credentials)
    }
}
