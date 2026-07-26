import XCTest
@testable import odoo

/// Controllable fake so the auth flow is deterministic (no real LAContext / OS sheet).
final class FakeBiometricAuthenticator: BiometricAuthenticator {
    var canEval = true
    var kind: BiometryKind = .faceID
    func canEvaluate() -> Bool { canEval }
    var biometryKind: BiometryKind { kind }
    // The async prompt paths are exercised via the sync seams (applyBiometricOutcome /
    // applyDevicePasscodeOutcome), so these just record and return a preset.
    var nextOutcome: BiometricOutcome = .success
    var nextDeviceOwnerResult = true
    private(set) var evaluateCount = 0
    private(set) var deviceOwnerCount = 0
    func evaluateBiometrics(reason: String) async -> BiometricOutcome { evaluateCount += 1; return nextOutcome }
    func evaluateDeviceOwnerAuth(reason: String) async -> Bool { deviceOwnerCount += 1; return nextDeviceOwnerResult }
}

@MainActor
final class AppLockViewModelTests: XCTestCase {

    private var repo: SettingsRepository!
    private var fake: FakeBiometricAuthenticator!

    override func setUp() {
        super.setUp()
        repo = SettingsRepository()
        repo.resetFailedAttempts()
        repo.removePin()
        repo.setAppLock(true)
        repo.setBiometric(false)
        fake = FakeBiometricAuthenticator()
    }

    override func tearDown() {
        repo.setAppLock(false)
        repo.setBiometric(false)
        repo.removePin()
        repo.resetFailedAttempts()
        super.tearDown()
    }

    private func makeVM() -> AuthViewModel {
        AuthViewModel(settingsRepository: repo, authenticator: fake)
    }

    // MARK: - State selection (synchronous, from init recompute)

    func test_stateSelection_biometricOnly() {
        repo.setBiometric(true); fake.canEval = true; fake.kind = .faceID // no PIN
        let vm = makeVM()
        XCTAssertEqual(vm.uiState, .biometric(prompting: false, error: nil, kind: .faceID, showUsePin: false))
    }

    func test_stateSelection_pinOnly_whenBiometricUnusable() {
        repo.setBiometric(false); _ = repo.setPin("123456")
        let vm = makeVM()
        XCTAssertEqual(vm.uiState, .pin(showBack: false))
    }

    func test_stateSelection_biometricAndPin() {
        repo.setBiometric(true); fake.canEval = true; _ = repo.setPin("123456")
        let vm = makeVM()
        XCTAssertEqual(vm.uiState, .biometric(prompting: false, error: nil, kind: .faceID, showUsePin: true))
    }

    func test_stateSelection_setupRequired_whenAppLockOnButNoMethod() {
        repo.setBiometric(false); repo.removePin() // App Lock on, nothing usable
        let vm = makeVM()
        XCTAssertEqual(vm.uiState, .setupRequired(prompting: false, error: nil))
    }

    func test_stateSelection_unlocked_whenAppLockOff() {
        repo.setAppLock(false)
        let vm = makeVM()
        XCTAssertEqual(vm.uiState, .unlocked)
    }

    // MARK: - Auto-prompt + loop guard (AC1 / AC7)

    func test_appDidBecomeActive_biometric_startsPromptingOnce_andGuardBlocksReprompt() {
        repo.setBiometric(true); fake.canEval = true
        let vm = makeVM()

        vm.appDidBecomeActive()
        XCTAssertEqual(vm.uiState, .biometric(prompting: true, error: nil, kind: .faceID, showUsePin: false))

        // Simulate the prompt completing with a cancel (generation 0, unchanged).
        vm.applyBiometricOutcome(.userCancel, generation: 0)
        XCTAssertEqual(vm.uiState, .biometric(prompting: false, error: nil, kind: .faceID, showUsePin: false))

        // The Face sheet's .inactive→.active bounce: a second active must NOT re-prompt (AC7).
        vm.appDidBecomeActive()
        XCTAssertEqual(vm.uiState, .biometric(prompting: false, error: nil, kind: .faceID, showUsePin: false),
                       "auto-prompt must not re-fire after a cancel without a true re-lock")

        // A true re-lock re-arms it.
        vm.relock()
        vm.appDidBecomeActive()
        XCTAssertEqual(vm.uiState, .biometric(prompting: true, error: nil, kind: .faceID, showUsePin: false))
    }

    // MARK: - Stale-success security race (AC8)

    func test_staleBiometricSuccess_afterRelock_isDiscarded() {
        repo.setBiometric(true); fake.canEval = true
        let vm = makeVM()
        // Prompt captured generation 0; a re-lock bumps it to 1.
        vm.appDidBecomeActive()
        vm.relock() // generation 0 -> 1

        // A late success carrying the stale generation 0 must be ignored.
        vm.applyBiometricOutcome(.success, generation: 0)
        XCTAssertFalse(vm.isAuthenticated, "a biometric success delivered after re-lock must NOT unlock")

        // The current-generation success unlocks.
        vm.applyBiometricOutcome(.success, generation: 1)
        XCTAssertTrue(vm.isAuthenticated)
        XCTAssertEqual(vm.uiState, .unlocked)
    }

    // MARK: - External re-lock (AC9)

    func test_setAuthenticatedFalse_reLocks_andReArmsPrompt() {
        repo.setBiometric(true); fake.canEval = true
        let vm = makeVM()
        vm.setAuthenticated(true)
        XCTAssertEqual(vm.uiState, .unlocked)
        // Session expiry / logout path.
        vm.setAuthenticated(false)
        XCTAssertFalse(vm.isAuthenticated)
        XCTAssertEqual(vm.uiState, .biometric(prompting: false, error: nil, kind: .faceID, showUsePin: false))
    }

    // MARK: - usePin + fallback

    func test_usePin_switchesToPinKeypad_withBackButton() {
        repo.setBiometric(true); fake.canEval = true; _ = repo.setPin("123456")
        let vm = makeVM()
        vm.usePin()
        XCTAssertEqual(vm.uiState, .pin(showBack: true))
    }

    func test_biometricUserFallback_withPin_routesToPin() {
        repo.setBiometric(true); fake.canEval = true; _ = repo.setPin("123456")
        let vm = makeVM()
        vm.appDidBecomeActive()
        vm.applyBiometricOutcome(.userFallback, generation: 0)
        XCTAssertEqual(vm.uiState, .pin(showBack: true))
    }

    // MARK: - Device passcode (setup-required)

    func test_devicePasscodeSuccess_unlocks_butStaleIsDiscarded() {
        // App Lock on, no method → setupRequired.
        let vm = makeVM()
        XCTAssertEqual(vm.uiState, .setupRequired(prompting: false, error: nil))
        vm.relock() // gen -> 1
        vm.applyDevicePasscodeOutcome(success: true, generation: 0) // stale
        XCTAssertFalse(vm.isAuthenticated)
        vm.applyDevicePasscodeOutcome(success: true, generation: 1)
        XCTAssertTrue(vm.isAuthenticated)
    }
}
