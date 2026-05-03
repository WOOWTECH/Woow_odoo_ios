import Combine
import SwiftUI
import XCTest
@testable import odoo

/// Reactivity contract for `WoowTheme.shared.primaryColor`.
///
/// **The bug this guards**: when `WoowTheme.setPrimaryColor(hex:)` was called,
/// the published `primaryColor` updated locally but no SwiftUI view actually
/// observed it (everything hardcoded `WoowColors.primaryBlue`). The user
/// picked a color, the persistence ran, but the UI didn't change.
///
/// This unit test does NOT verify any rendered pixel — that's
/// `E2E_ThemeColorTests`'s job. It verifies the technical contract that
/// `setPrimaryColor` actually publishes via the `@Published` property
/// wrapper, so any SwiftUI view that declares
/// `@ObservedObject var theme = WoowTheme.shared` will be notified.
@MainActor
final class WoowThemeReactivityTest: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    /// Default theme color — matches `AppSettings.themeColor`'s default.
    /// Test tearDown forces SecureStorage back to this so other tests
    /// (e.g. `SettingsViewModelTests.test_initialState_loadsSettings`)
    /// see a clean state. The "save current, restore current" pattern
    /// fails here because a prior failed run can leave SecureStorage
    /// polluted, so the captured "original" is already wrong.
    /// CLAUDE.md "Test Independence" rule.
    private static let defaultThemeColor = "#6183FC"

    override func setUp() async throws {
        try await super.setUp()
        cancellables.removeAll()
        // Defensive: reset before each test in case a prior test polluted.
        WoowTheme.shared.setPrimaryColor(hex: Self.defaultThemeColor)
    }

    override func tearDown() async throws {
        WoowTheme.shared.setPrimaryColor(hex: Self.defaultThemeColor)
        cancellables.removeAll()
        try await super.tearDown()
    }

    func test_setPrimaryColor_publishesChange() async throws {
        let theme = WoowTheme.shared
        let expectation = XCTestExpectation(description: "primaryColor publishes")
        var observedCount = 0

        theme.$primaryColor
            .dropFirst() // skip the initial subscribed-now value
            .sink { _ in
                observedCount += 1
                if observedCount == 1 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        theme.setPrimaryColor(hex: "#FF0000")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(observedCount, 1, "Expected exactly one publish; got \(observedCount)")
    }

    func test_setPrimaryColor_storesValue() {
        let theme = WoowTheme.shared
        theme.setPrimaryColor(hex: "#00C853")

        // Color equality in SwiftUI is approximate — assert via the underlying
        // hex by re-reading from settings storage.
        let stored = SecureStorage.shared.getSettings()
        XCTAssertEqual(
            stored.themeColor.uppercased(),
            "#00C853",
            "setPrimaryColor must persist the hex so app restart re-applies it",
        )
    }

    func test_setPrimaryColor_multipleChanges_eachPublishes() async throws {
        let theme = WoowTheme.shared
        let expectation = XCTestExpectation(description: "three publishes")
        var observedCount = 0

        theme.$primaryColor
            .dropFirst()
            .sink { _ in
                observedCount += 1
                if observedCount == 3 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        theme.setPrimaryColor(hex: "#FF0000")
        theme.setPrimaryColor(hex: "#00C853")
        theme.setPrimaryColor(hex: "#FF6F00")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(observedCount, 3)
    }
}
