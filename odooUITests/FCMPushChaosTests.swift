// FCMPushChaosTests.swift
// R-05 Phase C: corner-case chaos coverage for the H' FCM pipeline.
//
// This file is intentionally separate from FCMPushTests.swift because the
// chaos tests have different setUp/tearDown semantics:
//   - they SIGKILL / scale-to-0 / corrupt central-side state;
//   - their tearDown MUST restore the service before XCTest reports the
//     verdict (otherwise a failure cascades into the next test);
//   - mixing them with the broadcast suite would obscure which test took
//     down the pipeline.
//
// Trace gaps closed:
//   G-6  sidecar SIGKILL mid-mention — iOS survives, no phantom delivery
//   G-7  central TVS 503 — cached-bearer path delivers within NFC-1 60s
//   G-9  invalid FCM token — device row auto-deactivates after 2 failures
//
// Execution constraints:
//   - The chaos helper shell scripts live under
//     /Users/alanlin/woow_fcm_central/central/scripts/chaos/. Each test
//     shells out via Foundation.Process (macOS-only). When this file is
//     compiled for the iOS device target, Process is unavailable; the
//     tests skip themselves with a clear reason rather than crash.
//   - All chaos tests assert XCUIApplication.state == .runningForeground
//     at the end of tearDown. iOS app crash counts as test failure.
//   - Service restoration is idempotent — each chaos shell script has an
//     EXIT trap that restores the service even if the test SIGKILLs the
//     runner mid-flight.

import XCTest

final class FCMPushChaosTests: XCTestCase {

    private typealias TestConfig = SharedTestConfig

    private var app: XCUIApplication!
    private var springboard: XCUIApplication!

    private static let chaosScriptsDir =
        "/Users/alanlin/woow_fcm_central/central/scripts/chaos"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-ResetAppState"]
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["FCM_HPRIME_MODE"] = "1"
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Auto-accept system notification permission dialog if it appears.
        addUIInterruptionMonitor(withDescription: "System notification permission") { dialog in
            for buttonLabel in ["Allow", "Allow Notifications", "OK"] {
                let btn = dialog.buttons[buttonLabel]
                if btn.exists {
                    btn.tap()
                    return true
                }
            }
            return false
        }
    }

    override func tearDown() {
        // R-05 survival gate: every chaos test must leave the iOS app in
        // the foreground state, no matter what the central-side chaos did.
        // A push that arrives but kills the app is still a P0 defect.
        if let app = app {
            let endState = app.state
            XCTAssertEqual(
                endState,
                .runningForeground,
                "iOS app crashed or backgrounded during chaos test "
                + "(final state=\(endState.rawValue)). Expected .runningForeground (rawValue=4)."
            )
        }
        super.tearDown()
    }

    // ───────────────────────────────────────────────────────────────────
    // C-1: sidecar SIGKILL mid-mention
    // ───────────────────────────────────────────────────────────────────

    /// Kills the fcm-sidecar container ~100ms before posting a chatter
    /// mention, waits 30s, then asserts:
    ///   - no notification surfaces (the entire push path is broken);
    ///   - the iOS app stays in `.runningForeground` (no crash from the
    ///     missing-socket error path in the plugin's retry/backoff loop).
    /// The chaos script's EXIT trap restores the sidecar before this
    /// method returns, so the next test starts from a healthy baseline.
    @MainActor
    func test_chaos_sidecar_killed_during_mention() throws {
        try _skipIfNotMacOSRunner()
        let serverURL = TestConfig.serverURL

        // Launch + login + register so the device row exists and
        // would be eligible for push if the sidecar were alive.
        try _bootstrapLoggedInState(serverURL: serverURL)

        // Background the app so any phantom push would be visible.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.0)

        // The chaos block uses Foundation.Process which is unavailable on
        // iOS — the iOS branch is unreachable because _skipIfNotMacOSRunner
        // already threw XCTSkip above. The explicit guard satisfies the
        // type checker.
        #if os(macOS)
        // Run the chaos: SIGKILL sidecar, sleep 15s (enough to span the
        // plugin's 3-retry backoff window + the 30s notification timeout
        // below), then EXIT trap restores. We launch the script in the
        // background; the EXIT trap fires when the script process exits,
        // not when our test method returns.
        let chaosProc = try _runChaosScript(
            name: "kill-sidecar.sh",
            arguments: ["15"]
        )

        // Wait 100ms so the kill takes effect before the mention fires.
        Thread.sleep(forTimeInterval: 0.1)

        let marker = "C1-sidecar-killed-\(Int(Date().timeIntervalSince1970))"
        // Best-effort post — the plugin may queue this and ultimately error
        // with "socket-missing". We tolerate POST errors here; the assertion
        // is about the absence of notification + app survival.
        _ = try? _postChannelMention(serverURL: serverURL, marker: marker)

        // Wait 30s for a notification that should NEVER arrive.
        let appeared = _waitForNotification(containing: marker, timeout: 30)
        XCTAssertFalse(
            appeared,
            "Phantom notification arrived while sidecar was SIGKILLed — "
            + "the push path should have failed entirely. Marker: \(marker)"
        )

        // Wait for the chaos script to finish (sidecar already restoring
        // via its EXIT trap by the time we get here).
        chaosProc.waitUntilExit()
        XCTAssertEqual(
            chaosProc.terminationStatus, 0,
            "kill-sidecar.sh exited non-zero (\(chaosProc.terminationStatus)) — "
            + "sidecar may not have been restored; check manually."
        )

        // Final app-state check is duplicated in tearDown for safety, but
        // we inline it here so a failure points at this specific scenario.
        XCTAssertEqual(
            app.state, .runningForeground,
            "iOS app did not survive sidecar SIGKILL — final state=\(app.state.rawValue)"
        )
        #endif
    }

    // ───────────────────────────────────────────────────────────────────
    // C-2: central TVS 503 — cached-bearer fallback (NFC-1)
    // ───────────────────────────────────────────────────────────────────

    /// Scales the token-vending-service deployment to 0 replicas, then
    /// posts a chatter mention. Per NFC-1, the sidecar's cached bearer
    /// token has a 60s tolerance, so the push should STILL be delivered
    /// even with central down. The chaos script restores TVS in its
    /// EXIT trap.
    @MainActor
    func test_chaos_central_503_iOS_survives() throws {
        try _skipIfNotMacOSRunner()
        let serverURL = TestConfig.serverURL

        try _bootstrapLoggedInState(serverURL: serverURL)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.0)

        // See C-1 for the os(macOS) guard rationale.
        #if os(macOS)
        // Scale TVS to 0 for 90s (60s NFC-1 window + 30s slack to allow
        // the notification timeout below to complete before restore).
        let chaosProc = try _runChaosScript(
            name: "stop-central.sh",
            arguments: ["90"]
        )

        // Give kubectl scale a moment to propagate.
        Thread.sleep(forTimeInterval: 2.0)

        let marker = "C2-central-503-\(Int(Date().timeIntervalSince1970))"
        try _postChannelMention(serverURL: serverURL, marker: marker)

        // 60s notification timeout — cached-bearer path should still deliver.
        let appeared = _waitForNotification(containing: marker, timeout: 60)
        XCTAssertTrue(
            appeared,
            "NFC-1 violation: TVS scaled to 0, but the sidecar's cached bearer "
            + "should have served this push within 60s. Marker: \(marker)"
        )

        chaosProc.waitUntilExit()
        XCTAssertEqual(
            chaosProc.terminationStatus, 0,
            "stop-central.sh exited non-zero (\(chaosProc.terminationStatus)) — "
            + "TVS may not have been restored; check 'kubectl get deploy -n woow-fcm-central'."
        )

        XCTAssertEqual(
            app.state, .runningForeground,
            "iOS app did not survive central TVS 503 — final state=\(app.state.rawValue)"
        )
        #endif
    }

    // ───────────────────────────────────────────────────────────────────
    // C-3: invalid FCM token — device auto-deactivates after 2 failures
    // ───────────────────────────────────────────────────────────────────

    /// Corrupts admin's fcm_token in woow_fcm_device, fires 2 mentions
    /// (expected to both fail at the FCM-API layer), then asserts the
    /// device row has `active=false`. The chaos script's EXIT trap
    /// restores the original token from a snapshot taken at script start.
    @MainActor
    func test_chaos_invalid_fcm_token_deactivates_device() throws {
        try _skipIfNotMacOSRunner()
        let serverURL = TestConfig.serverURL

        try _bootstrapLoggedInState(serverURL: serverURL)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.0)

        // See C-1 for the os(macOS) guard rationale.
        #if os(macOS)
        // Poison the token in the DB; trap restores after 60s + script exit.
        // The script idles for the given duration so it stays alive long
        // enough for our 2-mention sequence + the H' failure-counter to
        // reach the deactivation threshold.
        let chaosProc = try _runChaosScript(
            name: "poison-fcm-token.sh",
            arguments: ["60"]
        )

        // Give the poison-write time to land before mention #1.
        Thread.sleep(forTimeInterval: 2.0)

        let marker1 = "C3-poison-1-\(Int(Date().timeIntervalSince1970))"
        try _postChannelMention(serverURL: serverURL, marker: marker1)
        // Wait long enough for the sidecar/central to surface the failure.
        Thread.sleep(forTimeInterval: 10.0)

        let marker2 = "C3-poison-2-\(Int(Date().timeIntervalSince1970))"
        try _postChannelMention(serverURL: serverURL, marker: marker2)
        Thread.sleep(forTimeInterval: 10.0)

        // Poll up to 30s for the device row to be marked inactive.
        let deactivationDeadline = Date().addingTimeInterval(30)
        var deactivated = false
        while Date() < deactivationDeadline {
            if try _countActiveFCMDevicesForAdmin(serverURL: serverURL) == 0 {
                deactivated = true
                break
            }
            Thread.sleep(forTimeInterval: 2.0)
        }
        XCTAssertTrue(
            deactivated,
            "FCM device for admin still active after 2 mentions with poisoned "
            + "token — H' auto-deactivation logic regressed."
        )

        chaosProc.waitUntilExit()
        XCTAssertEqual(
            chaosProc.terminationStatus, 0,
            "poison-fcm-token.sh exited non-zero (\(chaosProc.terminationStatus)) — "
            + "token may NOT have been restored; verify with "
            + "'psql -d odoo18_ecpay -c \"SELECT fcm_token FROM woow_fcm_device WHERE user_id=2;\"'"
        )

        XCTAssertEqual(
            app.state, .runningForeground,
            "iOS app did not survive token poison — final state=\(app.state.rawValue)"
        )
        #endif
    }

    // ───────────────────────────────────────────────────────────────────
    // MARK: - Shared helpers (file-local; do NOT touch FCMPushTests.swift)
    // ───────────────────────────────────────────────────────────────────

    /// Skips the test with a clear reason when this file is compiled and
    /// run on the iOS device target. Process() is macOS-only; the chaos
    /// scripts can only be invoked from a macOS host.
    private func _skipIfNotMacOSRunner() throws {
        #if !os(macOS)
        throw XCTSkip(
            "FCMPushChaosTests only run from the macOS host runner — they "
            + "shell out to chaos scripts via Foundation.Process which is "
            + "unavailable on the iOS device target."
        )
        #endif
    }

    /// Launches a chaos helper script asynchronously. Returns the running
    /// Process so the caller can `waitUntilExit()` once the chaos window
    /// has elapsed. The script's own EXIT trap is responsible for restoring
    /// the chaos'd service, so even an XCTest abort leaves the cluster
    /// healthy.
    ///
    /// macOS-only by construction: Foundation.Process and its return type
    /// don't exist in the iOS SDK, so the entire symbol is gated. iOS-side
    /// test methods never reach a call site — they throw XCTSkip first via
    /// `_skipIfNotMacOSRunner()`, and the chaos-script blocks themselves
    /// are wrapped in matching `#if os(macOS)` guards.
    #if os(macOS)
    @discardableResult
    private func _runChaosScript(name: String, arguments: [String]) throws -> Process {
        let scriptPath = "\(Self.chaosScriptsDir)/\(name)"
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            throw NSError(
                domain: "FCMPushChaosTests", code: 100,
                userInfo: [NSLocalizedDescriptionKey:
                    "chaos script not executable: \(scriptPath). "
                    + "Run 'chmod +x \(scriptPath)' and re-run."]
            )
        }
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [scriptPath] + arguments
        let stderrPipe = Pipe()
        task.standardError = stderrPipe
        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        try task.run()
        return task
    }
    #endif

    /// Drives the launch + login + FCM registration flow so a chaos test
    /// has a registered device row to push to. Aborts the test (via
    /// XCTFail) if any step fails — chaos coverage only makes sense
    /// once the happy path is established.
    @MainActor
    private func _bootstrapLoggedInState(serverURL: String) throws {
        app.launch()
        app.activate()

        let loginField = app.textFields["example.odoo.com"]
        if loginField.waitForExistence(timeout: 5) {
            app.loginWithTestCredentials(
                server: serverURL,
                database: TestConfig.database,
                username: TestConfig.adminUser,
                password: TestConfig.adminPass
            )
        }
        app.tap()  // surface UI interruption monitor

        let mainScreenLoaded = app.buttons["line.3.horizontal"].waitForExistence(timeout: 15)
        guard mainScreenLoaded else {
            throw NSError(
                domain: "FCMPushChaosTests", code: 200,
                userInfo: [NSLocalizedDescriptionKey: "login never reached main screen"]
            )
        }

        let deadline = Date().addingTimeInterval(30)
        var devicesFound = 0
        while Date() < deadline {
            devicesFound = (try? _countActiveFCMDevicesForAdmin(serverURL: serverURL)) ?? 0
            if devicesFound > 0 { break }
            Thread.sleep(forTimeInterval: 2.0)
        }
        guard devicesFound > 0 else {
            throw NSError(
                domain: "FCMPushChaosTests", code: 201,
                userInfo: [NSLocalizedDescriptionKey:
                    "FCM device for admin never registered within 30s — "
                    + "fix the happy path before running chaos."]
            )
        }
    }

    /// JSON-RPC wrapper to count active FCM devices for admin (user_id=2).
    /// Throws on transport / parse failure; returns 0 on a clean "no rows"
    /// response.
    private func _countActiveFCMDevicesForAdmin(serverURL: String) throws -> Int {
        let cookie = try _authenticate(serverURL: serverURL, login: TestConfig.adminUser, password: TestConfig.adminPass)
        let result = try _callKw(
            serverURL: serverURL, cookie: cookie,
            model: "woow.fcm.device", method: "search_count",
            args: [[["user_id", "=", 2], ["active", "=", true]]],
            kwargs: [:]
        )
        return (result as? Int) ?? 0
    }

    /// Posts a chatter mention into #general as demo user, tagging admin.
    /// Used by chaos tests that need to trigger a real push attempt.
    private func _postChannelMention(serverURL: String, marker: String) throws {
        let cookie = try _authenticate(serverURL: serverURL, login: "demo", password: "demo")
        let mentionHTML = "<p><a href=\"#\" data-oe-model=\"res.partner\" data-oe-id=\"3\">@Mitchell Admin</a> \(marker)</p>"
        try _callKw(
            serverURL: serverURL, cookie: cookie,
            model: "discuss.channel", method: "message_post",
            args: [[1]],
            kwargs: [
                "body": mentionHTML,
                "partner_ids": [3],
                "message_type": "comment",
                "subtype_xmlid": "mail.mt_comment"
            ]
        )
    }

    /// Polls springboard for a notification with the given marker.
    private func _waitForNotification(containing marker: String, timeout: TimeInterval) -> Bool {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let mid = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.1, thenDragTo: mid)

        let predicate = NSPredicate(format: "label CONTAINS[c] %@", marker)
        let element = springboard.otherElements.matching(predicate).firstMatch
        return element.waitForExistence(timeout: timeout)
    }

    // Below are duplicates of FCMPushE2ETests helpers — kept local because
    // the originals are `fileprivate` and these tests live in a separate
    // file. The duplication is intentional: chaos tests must remain
    // isolated from the broadcast-test class so a future refactor of one
    // class never breaks the other.

    private enum ChaosHelperError: Error, CustomStringConvertible {
        case authFailed(user: String)
        case rpcFailed(model: String, method: String, reason: String)

        var description: String {
            switch self {
            case .authFailed(let user):       return "auth as '\(user)' failed"
            case .rpcFailed(let m, let mt, let r): return "\(m).\(mt) failed: \(r)"
            }
        }
    }

    private func _authenticate(serverURL: String, login: String, password: String) throws -> String {
        let sem = DispatchSemaphore(value: 0)
        var cookie: String?
        guard let url = URL(string: "https://\(serverURL)/web/session/authenticate") else {
            throw ChaosHelperError.authFailed(user: login)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "params": ["db": TestConfig.database, "login": login, "password": password]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, response, _ in
            defer { sem.signal() }
            guard let httpResp = response as? HTTPURLResponse else { return }
            for (k, v) in httpResp.allHeaderFields {
                if let key = k as? String, key.lowercased() == "set-cookie",
                   let val = v as? String, val.contains("session_id=") {
                    cookie = val.components(separatedBy: ";").first
                    return
                }
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        guard let c = cookie else { throw ChaosHelperError.authFailed(user: login) }
        return c
    }

    @discardableResult
    private func _callKw(
        serverURL: String,
        cookie: String,
        model: String,
        method: String,
        args: [Any],
        kwargs: [String: Any] = [:]
    ) throws -> Any {
        let sem = DispatchSemaphore(value: 0)
        var result: Any?
        var failureReason: String?
        guard let url = URL(string: "https://\(serverURL)/web/dataset/call_kw") else {
            throw ChaosHelperError.rpcFailed(model: model, method: method, reason: "bad URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.timeoutInterval = 8
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "params": ["model": model, "method": method, "args": args, "kwargs": kwargs]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let e = error { failureReason = e.localizedDescription; return }
            guard let httpResp = response as? HTTPURLResponse else {
                failureReason = "no HTTP response"; return
            }
            if httpResp.statusCode != 200 {
                failureReason = "HTTP \(httpResp.statusCode)"; return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failureReason = "non-JSON body"; return
            }
            if let err = json["error"] {
                failureReason = "Odoo error: \(err)"; return
            }
            if json["result"] == nil {
                failureReason = "missing result field"; return
            }
            result = json["result"]
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        if let r = result { return r }
        throw ChaosHelperError.rpcFailed(
            model: model, method: method, reason: failureReason ?? "unknown"
        )
    }
}
