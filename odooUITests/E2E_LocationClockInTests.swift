//
//  E2E_LocationClockInTests.swift
//  odooUITests
//
//  End-to-end test for the Location Clock-In feature.
//  Design specification: docs/2026-04-26-xcuitest-e2e-clockin-design.md §4.3
//
//  ARCHITECTURE DECISION — WKWebView accessibility vs JS injection
//  ---------------------------------------------------------------
//  OWL renders the Attendance systray as a JS popover that is NOT surfaced in the
//  WKWebView AX tree. The AX nav-bar "Attendance" button IS visible, but tapping it
//  navigates to /odoo/discuss rather than opening a dropdown (OWL internal routing).
//
//  Primary strategy: `WOOW_TEST_AUTOTAP` launch-environment variable. The production
//  `OdooWebViewCoordinator.injectTestAutoTapIfRequested` (DEBUG-only) injects JS after
//  each page load to click the systray and the clock action. The test then polls
//  OdooHelper.latestAttendance to verify the GPS coordinates were recorded server-side.
//
//  AX selectors (buttons["Check in"] etc.) are kept as a secondary attempt after
//  WOOW_TEST_AUTOTAP fires, in case a future OWL version does surface the popover in AX.
//
//  SKIP POLICY
//  -----------
//  Requires `RUN_LOCATION_E2E=1` in the test-process environment to opt in.
//  All other invocations skip cleanly. (The bundled `LocationE2E.xctestplan`
//  sets this for you.)
//
//  PREREQUISITES
//  -------------
//  1. Odoo 18 reachable at the URL configured in `TestConfig.plist` (key
//     `ServerURL`) with `hr_attendance` installed. CI may override via the
//     `TEST_SERVER_URL` env var (see `SharedTestConfig`).
//  2. Admin credentials in `TestConfig.plist` (`AdminUser` / `AdminPass`)
//     valid on the configured database (`Database`).
//  3. Location permission must be in a state the test can grant:
//       SIMULATOR — automatic via:
//         xcrun simctl privacy <SIMCTL_UDID> grant location-always io.woowtech.odoo.debug
//         (run by the CI workflow before xcodebuild test)
//       REAL DEVICE — the test relies on `addUIInterruptionMonitor` to auto-tap
//         "Allow While Using App" when iOS surfaces the permission dialog.
//         The dialog only appears when CLAuthorizationStatus == .notDetermined.
//         If a previous run set it to .denied or .authorizedWhenInUse, the dialog
//         WILL NOT appear and the monitor cannot grant. Reset on real device:
//             Settings → General → Transfer or Reset iPhone → Reset → Reset Location & Privacy
//         OR for a single app:
//             Settings → Privacy & Security → Location Services → WoowTech Odoo → Ask Next Time
//         This is intentional Apple behavior — a third-party tool cannot toggle
//         CLLocation permission without the user's involvement (privacy-by-design).
//  4. DEBUG build of the app target (JSBridge + TestHooks require `#if DEBUG`).
//
//  LOCATION PERMISSION MODEL — DESIGN INTENT
//  -----------------------------------------
//  The permission state is something the TEST sets up, NOT something the user is
//  expected to configure manually before each run. On simulator, simctl handles it
//  100% deterministically. On real device, iOS gives apps no API to set permission
//  programmatically — the only paths are:
//    (a) First-launch dialog → addUIInterruptionMonitor taps Allow
//    (b) Settings.app re-grant by the user (one-time, then persists)
//    (c) Reset Location & Privacy (factory wipe of all permission decisions)
//  If you see "in_latitude=0" failures on a real device, FIRST verify
//  CLAuthorizationStatus is `.notDetermined` (so the dialog appears and the
//  monitor can grant) or `.authorizedWhenInUse` (so no dialog is needed and
//  the gate grants directly). XCUITest runs in a separate process from the
//  app under test, so it cannot query the app's CLAuthorizationStatus
//  programmatically — this is a manual / one-time-setup check.
//

import XCTest

// MARK: - E2E_LocationClockInTests

@MainActor
final class E2E_LocationClockInTests: XCTestCase {

    // MARK: - State

    var app: XCUIApplication!
    var sessionCookie: String!
    var uid: Int!
    var employeeID: Int!

    // MARK: - setUp (shared for both tests)

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_LOCATION_E2E"] == "1",
            "Location E2E disabled by default. Run via LocationE2E.xctestplan, or set RUN_LOCATION_E2E=1."
        )
        continueAfterFailure = false

        // 1. Authenticate with Odoo and resolve employee id.
        let (cookie, uidValue) = try await OdooHelper.authenticate()
        sessionCookie = cookie
        uid = uidValue
        employeeID = try await OdooHelper.employeeID(forUserId: uidValue, cookie: cookie)
    }

    // MARK: - test_clockIn_recordsNonZeroGPS_via_systray

    /// Performs one clock toggle (in or out depending on current server state) via the JS
    /// auto-tap hook, then asserts that the relevant lat/lon column is non-zero on the
    /// latest hr.attendance record.
    ///
    /// Satisfies design §3 `test_clockIn_recordsNonZeroGPS_via_systray`.
    func test_clockIn_recordsNonZeroGPS_via_systray() async throws {
        // PERMISSION CONTRACT (see file header "LOCATION PERMISSION MODEL"):
        // The TEST owns the permission state, not the human running the test.
        //   - Simulator: pre-granted via `xcrun simctl privacy ... grant location-always`.
        //   - Real device: the monitor below taps "Allow While Using App" if the OS
        //     surfaces the dialog. The dialog only appears when status is
        //     `.notDetermined`; if a previous run left it `.denied`, reset via
        //     Settings → Privacy & Security → Location Services → WoowTech Odoo → Ask Next Time.

        // Snapshot current state to determine which action will fire.
        let before = try await OdooHelper.latestAttendance(forEmployeeID: employeeID, cookie: sessionCookie)
        let isCurrentlyCheckedIn = before != nil && before!.check_out == nil

        // Choose the auto-tap action: if checked-in → check out; if checked-out → check in.
        let autoTapAction = isCurrentlyCheckedIn ? "clock-checkout" : "clock-checkin"

        app = XCUIApplication()
        app.launchArguments += ["-ResetAppState", "-LocationEnabled"]
        app.launchEnvironment["WOOW_TEST_AUTOTAP"] = autoTapAction
        if let json = TestAccountSeeder.seedJSON(
            serverURL: OdooHelper.tunnelURL,
            database: OdooHelper.db,
            username: OdooHelper.user,
            sessionCookie: sessionCookie
        ) {
            app.launchEnvironment["WOOW_SEED_ACCOUNT"] = json
        }

        addUIInterruptionMonitor(withDescription: "Location permission dialog") { dialog in
            for label in ["Allow While Using App", "Allow Once", "Allow"] {
                let btn = dialog.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }

        app.launch()

        // Wait for the WebView to appear.
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "WebView did not appear within 30s")

        // Trigger UIInterruptionMonitor (surfaces any pending location dialog).
        app.tap()

        // WOOW_TEST_AUTOTAP fires 2s after page load:
        //   systray click → 1.2s wait → action button click → GPS → Odoo RPC.
        // Total expected delay: 2s + 1.2s + ~8s for GPS fix + RPC = ~12s.
        // We poll for up to 25s (5 attempts × 5s) to handle slow tunnel latency.
        let isCheckIn = !isCurrentlyCheckedIn
        var verified = false

        for attempt in 1...5 {
            try await Task.sleep(for: .seconds(5))
            app.tap() // re-trigger interruption monitor in case GPS dialog surfaces late

            let after = try await OdooHelper.latestAttendance(forEmployeeID: employeeID, cookie: sessionCookie)
            let lat: Double
            let lon: Double

            if isCheckIn {
                // A new attendance record should have appeared.
                guard let rec = after, rec.id != before?.id || before == nil else {
                    print("[E2E] Attempt \(attempt)/5: check-in record not yet created (id=\(after?.id ?? -1) before=\(before?.id ?? -1))")
                    continue
                }
                lat = rec.in_latitude
                lon = rec.in_longitude
            } else {
                // The existing record should now have a check_out.
                guard let rec = after, rec.id == before?.id, rec.check_out != nil else {
                    print("[E2E] Attempt \(attempt)/5: check-out not yet written (id=\(after?.id ?? -1))")
                    continue
                }
                lat = rec.out_latitude
                lon = rec.out_longitude
            }

            if lat != 0.0 || lon != 0.0 {
                print("[E2E] Attempt \(attempt)/5: GPS recorded lat=\(lat) lon=\(lon) — PASS")
                verified = true
                break
            } else {
                print("[E2E] Attempt \(attempt)/5: coords still 0 — waiting")
            }
        }

        if !verified {
            // Dump the AX tree for diagnostics.
            XCTContext.runActivity(named: "Dump WebView AX tree — GPS not recorded") { _ in
                print("=== WebView AX tree at failure ===")
                print(webView.debugDescription)
            }
            attachFailureScreenshot(named: "gps_not_recorded_single_action")
        }

        let finalRecord = try await OdooHelper.latestAttendance(forEmployeeID: employeeID, cookie: sessionCookie)
        let permissionHint = "If on real device, verify Location permission for WoowTech Odoo " +
            "is .notDetermined or .authorizedWhenInUse — see file header LOCATION PERMISSION MODEL section."
        if isCheckIn {
            XCTAssertNotNil(finalRecord, "No hr.attendance row exists for employee \(employeeID!)")
            XCTAssertNotEqual(
                finalRecord?.in_latitude ?? 0, 0.0,
                "in_latitude is 0 — location fix did not reach Odoo after clock-in. \(permissionHint)"
            )
            XCTAssertNotEqual(
                finalRecord?.in_longitude ?? 0, 0.0,
                "in_longitude is 0 — location fix did not reach Odoo after clock-in. \(permissionHint)"
            )
        } else {
            XCTAssertNotEqual(
                finalRecord?.out_latitude ?? 0, 0.0,
                "out_latitude is 0 — location fix did not reach Odoo after clock-out. \(permissionHint)"
            )
            XCTAssertNotEqual(
                finalRecord?.out_longitude ?? 0, 0.0,
                "out_longitude is 0 — location fix did not reach Odoo after clock-out. \(permissionHint)"
            )
        }
    }

    // MARK: - test_clockOutThenIn_populatesBothGPSColumns

    /// Forces the employee into a checked-out state, then performs a full clock-in → clock-out
    /// cycle via WOOW_TEST_AUTOTAP JS injection. Asserts that both `in_latitude` and
    /// `out_latitude` are non-zero on the resulting hr.attendance record.
    ///
    /// This test catches a class of bugs where one direction (in OR out) works but the other does not.
    /// Satisfies design §3 `test_clockOutThenIn_populatesBothGPSColumns`.
    func test_clockOutThenIn_populatesBothGPSColumns() async throws {
        // PERMISSION CONTRACT — same as test_clockIn_recordsNonZeroGPS_via_systray.
        // The test orchestrates the permission state via simctl (simulator) or
        // addUIInterruptionMonitor (real device). See file header
        // "LOCATION PERMISSION MODEL — DESIGN INTENT" for the three permission paths.

        // Normalise server state: ensure the employee is checked out before starting.
        try await OdooHelper.ensureCheckedOut(forEmployeeID: employeeID, cookie: sessionCookie)

        // === PHASE 1: CLOCK IN ===
        let attendanceIDAfterCheckIn = try await performAutoTap(
            action: "clock-checkin",
            expectNewRecord: true,
            previousRecordID: nil,
            validateCoord: { rec in rec.in_latitude != 0.0 || rec.in_longitude != 0.0 },
            failMessage: "in_latitude and in_longitude are both 0 after clock-in"
        )

        // === PHASE 2: CLOCK OUT ===
        // Relaunch the app with clock-checkout auto-tap (new launch = fresh page load = JS fires).
        try await performAutoTap(
            action: "clock-checkout",
            expectNewRecord: false,
            previousRecordID: attendanceIDAfterCheckIn,
            validateCoord: { rec in rec.out_latitude != 0.0 || rec.out_longitude != 0.0 },
            failMessage: "out_latitude and out_longitude are both 0 after clock-out"
        )
    }

    // MARK: - Shared auto-tap runner

    /// Launches the app with a given WOOW_TEST_AUTOTAP action, polls Odoo until the expected
    /// attendance record change appears or the coord becomes non-zero, then asserts the result.
    ///
    /// - Parameters:
    ///   - action: The WOOW_TEST_AUTOTAP value (`"clock-checkin"` or `"clock-checkout"`).
    ///   - expectNewRecord: `true` if a new hr.attendance row should be created (clock-in from
    ///     checked-out state), `false` if the existing row should be updated (clock-out).
    ///   - previousRecordID: The id of the attendance row before the action (nil on first check-in).
    ///   - validateCoord: Closure returning `true` when the relevant coord is non-zero.
    ///   - failMessage: XCTFail message if the coord remains 0 after all retries.
    /// - Returns: The id of the resulting attendance record (for chaining clock-in → clock-out).
    @discardableResult
    private func performAutoTap(
        action: String,
        expectNewRecord: Bool,
        previousRecordID: Int?,
        validateCoord: @escaping (OdooHelper.Attendance) -> Bool,
        failMessage: String
    ) async throws -> Int? {
        app = XCUIApplication()
        app.launchArguments += ["-LocationEnabled"]
        // Note: -ResetAppState would clear the seeded account; omit it on the second phase.
        // If this is the first phase, include it to start clean.
        if previousRecordID == nil {
            app.launchArguments += ["-ResetAppState"]
        }
        app.launchEnvironment["WOOW_TEST_AUTOTAP"] = action
        if let json = TestAccountSeeder.seedJSON(
            serverURL: OdooHelper.tunnelURL,
            database: OdooHelper.db,
            username: OdooHelper.user,
            sessionCookie: sessionCookie
        ) {
            app.launchEnvironment["WOOW_SEED_ACCOUNT"] = json
        }

        addUIInterruptionMonitor(withDescription: "Location permission dialog") { dialog in
            for label in ["Allow While Using App", "Allow Once", "Allow"] {
                let btn = dialog.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }

        app.launch()

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30), "WebView did not appear for action=\(action)")
        app.tap()

        // Poll Odoo for up to 25s (5 × 5s).
        var resultID: Int?
        for attempt in 1...5 {
            try await Task.sleep(for: .seconds(5))
            app.tap()

            let latest = try await OdooHelper.latestAttendance(forEmployeeID: employeeID, cookie: sessionCookie)
            guard let rec = latest else {
                print("[E2E] Attempt \(attempt)/5 (\(action)): no attendance record yet")
                continue
            }

            if expectNewRecord {
                guard rec.id != previousRecordID ?? -1 else {
                    print("[E2E] Attempt \(attempt)/5 (\(action)): same record id=\(rec.id), waiting for new row")
                    continue
                }
            } else {
                guard rec.id == previousRecordID else {
                    print("[E2E] Attempt \(attempt)/5 (\(action)): wrong record id=\(rec.id), expected \(previousRecordID ?? -1)")
                    continue
                }
            }

            if validateCoord(rec) {
                print("[E2E] Attempt \(attempt)/5 (\(action)): PASS")
                resultID = rec.id
                break
            } else {
                print("[E2E] Attempt \(attempt)/5 (\(action)): coords still 0 — waiting")
            }
        }

        let finalRecord = try await OdooHelper.latestAttendance(forEmployeeID: employeeID, cookie: sessionCookie)

        if let rec = finalRecord {
            let permissionHint = " If on real device, verify Location permission for WoowTech Odoo " +
                "is .notDetermined or .authorizedWhenInUse — see file header LOCATION PERMISSION MODEL section."
            XCTAssertTrue(validateCoord(rec), failMessage + permissionHint)
        } else {
            if expectNewRecord {
                XCTFail("No hr.attendance record found after \(action)")
            } else {
                XCTFail("Expected existing attendance record to be updated by \(action), but found nil")
            }
        }

        if resultID == nil {
            attachFailureScreenshot(named: "gps_zero_after_\(action)")
            XCTContext.runActivity(named: "Dump WebView AX tree — \(action) GPS zero") { _ in
                print("=== WebView AX tree at \(action) failure ===")
                print(webView.debugDescription)
            }
        }

        return finalRecord?.id
    }

    // MARK: - Attendance systray tap helper (kept as secondary AX strategy)

    /// Attempts to tap the Attendance systray button using three AX selector strategies.
    /// Returns `true` if any strategy succeeded. On failure, dumps the AX tree.
    ///
    /// NOTE: In OWL 18 the dropdown content is a JS popover not exposed to AX. This helper
    /// will find the nav-bar button, but tapping it navigates to /odoo/discuss rather than
    /// opening a "Check in / Check out" menu. Kept for future AX improvements and diagnostics.
    @discardableResult
    private func tapAttendanceSystray(_ webView: XCUIElement) -> Bool {
        let strategies: [(String, () -> XCUIElement)] = [
            ("button[Attendance]", { webView.buttons["Attendance"] }),
            ("image[Attendance]",  { webView.images["Attendance"] }),
            ("any[Attendance]", {
                webView.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@", "Attendance"))
                    .firstMatch
            }),
        ]
        for (name, get) in strategies {
            let el = get()
            if el.waitForExistence(timeout: 3) {
                print("[E2E] Attendance found via \(name)")
                el.tap()
                return true
            }
        }
        print("[E2E] Attendance not found by any AX selector. WebView AX dump:")
        print(webView.debugDescription)
        return false
    }

    // MARK: - Failure screenshot helper

    private func attachFailureScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[E2E] Screenshot attached: \(name)")
    }
}
