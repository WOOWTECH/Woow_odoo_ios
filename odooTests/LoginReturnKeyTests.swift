import XCTest
@testable import odoo

/// LIVE-0927-3 — on the credentials step the keyboard covered the Login button and Return in the
/// password field did nothing (live run 2026-09-27, 13-after-login; the first Login tap landed on
/// the keyboard). Return must perform the SAME action as the button, with the SAME validation, and
/// the focused field decides which action button the screen scrolls into view.
///
/// Only the decision logic is unit-testable; that the ScrollView actually brings the Login button
/// above a real keyboard needs a simulator/device run.
@MainActor
final class LoginReturnKeyTests: XCTestCase {

    private func makeCredentialsVM(username: String, password: String,
                                   result: AuthResult = .error("stub", .unknown)) -> (LoginViewModel, MockAccountRepository) {
        let repo = MockAccountRepository()
        repo.stubbedAuthResult = result
        let vm = LoginViewModel(addingAccount: true, repository: repo, secureStorage: MockSecureStorage())
        vm.serverUrl = "https://odoo.example.com"
        vm.database = "db"
        vm.step = .credentials
        vm.username = username
        vm.password = password
        return (vm, repo)
    }

    // MARK: - Password field: Return == Login button

    func test_returnInPassword_givenFilledCredentials_submitsLoginLikeTheButton() async {
        let (vm, _) = makeCredentialsVM(username: "admin", password: "secret", result: .success(.init(
            userId: 2, sessionId: "sid", username: "admin", displayName: "Admin")))
        let succeeded = expectation(description: "onLoginSuccess")

        let next = vm.handleReturnKey(in: .password) { succeeded.fulfill() }

        XCTAssertNil(next, "送出後不應再把焦點移到其他欄位")
        XCTAssertTrue(vm.isLoading, "Return 必須與 Login 鍵一樣立即開始登入")
        // Generous: in the full suite a WebKit GPU-process launch has blocked the main actor for
        // >2 s (live0927 full run). isLoading above already proves the synchronous submission.
        await fulfillment(of: [succeeded], timeout: 10)
    }

    func test_returnInPassword_givenEmptyPassword_doesNotSubmit() {
        let (vm, _) = makeCredentialsVM(username: "admin", password: "   ")

        _ = vm.handleReturnKey(in: .password) { XCTFail("空密碼不可送出") }

        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.error, String(localized: "error_password_required"))
    }

    func test_returnInPassword_givenEmptyUsername_doesNotSubmit() {
        let (vm, _) = makeCredentialsVM(username: "", password: "secret")

        _ = vm.handleReturnKey(in: .password) { XCTFail("空帳號不可送出") }

        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.error, String(localized: "error_username_required"))
    }

    // MARK: - Other fields move forward

    func test_returnInUsername_movesFocusToPassword_withoutSubmitting() {
        let (vm, _) = makeCredentialsVM(username: "admin", password: "secret")

        let next = vm.handleReturnKey(in: .username) { XCTFail("帳號欄 Return 不應送出") }

        XCTAssertEqual(next, .password)
        XCTAssertFalse(vm.isLoading)
    }

    func test_returnInServerUrl_movesFocusToDatabase() {
        let vm = LoginViewModel(addingAccount: true, repository: MockAccountRepository(),
                                secureStorage: MockSecureStorage())

        XCTAssertEqual(vm.handleReturnKey(in: .serverUrl) {}, .database)
        XCTAssertEqual(vm.step, .serverInfo)
    }

    func test_returnInDatabase_givenValidServerInfo_advancesToCredentialsAndFocusesUsername() {
        let vm = LoginViewModel(addingAccount: true, repository: MockAccountRepository(),
                                secureStorage: MockSecureStorage())
        vm.serverUrl = "odoo.example.com"
        vm.database = "db"

        let next = vm.handleReturnKey(in: .database) {}

        XCTAssertEqual(vm.step, .credentials)
        XCTAssertEqual(next, .username)
    }

    func test_returnInDatabase_givenMissingDatabase_staysOnServerStep() {
        let vm = LoginViewModel(addingAccount: true, repository: MockAccountRepository(),
                                secureStorage: MockSecureStorage())
        vm.serverUrl = "odoo.example.com"
        vm.database = ""

        let next = vm.handleReturnKey(in: .database) {}

        XCTAssertEqual(vm.step, .serverInfo)
        XCTAssertNil(next)
        XCTAssertEqual(vm.error, String(localized: "error_database_required"))
    }

    // MARK: - Which button must stay visible above the keyboard

    func test_actionButton_forCredentialFields_isLogin() {
        XCTAssertEqual(LoginViewModel.actionButton(revealedFor: .username), .login)
        XCTAssertEqual(LoginViewModel.actionButton(revealedFor: .password), .login)
    }

    func test_actionButton_forServerFields_isNext() {
        XCTAssertEqual(LoginViewModel.actionButton(revealedFor: .serverUrl), .next)
        XCTAssertEqual(LoginViewModel.actionButton(revealedFor: .database), .next)
    }
}
