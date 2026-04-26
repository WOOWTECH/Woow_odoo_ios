//
//  SettingsRepositoryLocationTests.swift
//  odooTests
//
//  Tier 1 unit tests for the locationEnabled persistence path
//  (v2 plan §3 Cycle 4).
//
//  These tests run against the real SecureStorage (Keychain) because there is
//  no factory hook in SettingsRepository for injecting a fake. To avoid
//  polluting the developer keychain, we restore the prior locationEnabled
//  value (and the standalone storage flag) in tearDown.
//

import XCTest
@testable import odoo

final class SettingsRepositoryLocationTests: XCTestCase {

    private var repo: SettingsRepository!
    private var originalLocationEnabled: Bool = true

    override func setUp() {
        super.setUp()
        repo = SettingsRepository()
        // Snapshot the existing value so tearDown can restore it.
        originalLocationEnabled = SecureStorage.shared.getSettings().locationEnabled
    }

    override func tearDown() {
        super.tearDown()
        // Restore the prior value via the public API so the standalone
        // location_enabled keychain entry stays in sync with the JSON blob.
        repo.updateLocationEnabled(originalLocationEnabled)
    }

    // MARK: - Cycle 4 — defaults

    func test_locationEnabled_defaultsTrue() {
        // A fresh in-memory AppSettings (no Keychain involved) must default to true,
        // matching the v2 spec opt-in default.
        let settings = AppSettings()
        XCTAssertTrue(settings.locationEnabled)
    }

    // MARK: - Cycle 4 — persistence

    /// Calling updateLocationEnabled(false) must:
    ///   1. Update the AppSettings JSON blob in Keychain.
    ///   2. Update the standalone "location_enabled" Keychain entry.
    /// Both reads must round-trip correctly.
    func test_updateLocationEnabled_persistsAndPublishes() {
        // Arrange — ensure a known starting state.
        repo.updateLocationEnabled(true)
        XCTAssertTrue(repo.getSettings().locationEnabled, "precondition: starts true")
        XCTAssertTrue(
            SecureStorage.shared.getLocationEnabled(),
            "precondition: standalone flag starts true"
        )

        // Act — toggle off via the repository's public API.
        repo.updateLocationEnabled(false)

        // Assert — both storage paths reflect the new value.
        XCTAssertFalse(
            repo.getSettings().locationEnabled,
            "AppSettings JSON blob must reflect locationEnabled=false"
        )
        XCTAssertFalse(
            SecureStorage.shared.getLocationEnabled(),
            "Standalone location_enabled keychain entry must reflect false"
        )

        // Toggle back on and re-verify both paths.
        repo.updateLocationEnabled(true)
        XCTAssertTrue(repo.getSettings().locationEnabled)
        XCTAssertTrue(SecureStorage.shared.getLocationEnabled())
    }
}
