// FCMSoakVerifyTests.swift
// Long-run SOAK verifier: pure OBSERVER of the iOS notification center.
//
// Purpose: one xcodebuild run == one soak cycle's iOS check. The HOST script
// fires a real Odoo @mention (marker in the body) a few seconds BEFORE this
// test runs, then invokes:
//
//   SOAK_MARKER=<marker> SOAK_TIMEOUT=120 \
//   xcodebuild test-without-building -only-testing:odooUITests/FCMSoakVerifyTests/test_SOAK_verifyAndClear ...
//
// This class deliberately does NOT reset app state and does NOT launch the
// main odoo app: the app is already installed, logged into fcm-e2e, and
// receiving pushes. Relaunching / resetting would log it out and destroy the
// registered device row. We only drive SpringBoard (the notification center).
//
// After each verify we CLEAR the notification center so the next cycle never
// accumulates a folded notification stack — accumulation is what makes the
// 4-strategy matcher flaky (the "parsing error" the operator flagged).
//
// Exit semantics: XCTAssert fails the test (xcodebuild exit != 0) when the
// marker does not surface within SOAK_TIMEOUT — the host reads that as the
// iOS-side FAIL for the cycle.

import XCTest

final class FCMSoakVerifyTests: XCTestCase {

    private var springboard: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Auto-dismiss a system dialog if one happens to be up (harmless here).
        addUIInterruptionMonitor(withDescription: "System dialog") { dialog in
            for label in ["Allow", "Allow Notifications", "OK", "Dismiss"] {
                let btn = dialog.buttons[label]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }
    }

    /// Opens the notification center and asserts a FRESH ODOO push notification
    /// appears within SOAK_TIMEOUT seconds, then clears the center (pass OR fail)
    /// so the next cycle starts empty.
    ///
    /// Marker-agnostic by design: the host clears this center at the END of every
    /// cycle, then fires exactly ONE @mention (author = the `demo` user, so the
    /// banner title is "Marc Demo"). Therefore any ODOO/"Marc Demo" notification
    /// present here can only be THIS cycle's push — no need to smuggle a per-cycle
    /// marker into the on-device runner's environment (host env vars do not reach
    /// the device runner's ProcessInfo). If SOAK_MARKER *is* injected via the
    /// xctestrun it tightens the match; otherwise the sender-name match is used.
    @MainActor
    func test_SOAK_verifyAndClear() {
        let env = ProcessInfo.processInfo.environment
        let timeout = TimeInterval(env["SOAK_TIMEOUT"] ?? "") ?? 120
        // Optional tightening if the harness manages to inject it; falls back to
        // the sender-name signal which is what actually reaches this device.
        let target = env["SOAK_MARKER"].flatMap { $0.isEmpty ? nil : $0 } ?? SENDER_TITLE

        let appeared = _waitForNotification(containing: target, timeout: timeout)

        // Visual evidence regardless of outcome.
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = "SOAK-\(appeared ? "PASS" : "FAIL")-\(Int(Date().timeIntervalSince1970))"
        att.lifetime = .keepAlways
        add(att)

        // Always clear so notifications never pile up across cycles (this is the
        // periodic notification-bar cleanup that keeps the matcher from choking
        // on an ever-growing folded group).
        _clearNotificationCenter()

        XCTAssertTrue(
            appeared,
            "SOAK iOS FAIL: no fresh ODOO notification (matching '\(target)') appeared "
            + "in the notification center within \(Int(timeout))s. The device row may "
            + "hold a stale APNs token, or APNs silently dropped the push."
        )
    }

    /// The banner title of every soak mention — the `demo` user (Marc Demo) is
    /// the author, so iOS renders "Marc Demo" as the notification title.
    private let SENDER_TITLE = "Marc Demo"

    // MARK: - SpringBoard helpers (ported; kept file-local by design)

    /// Opens the notification center and polls for a notification whose label
    /// contains `marker`, using the proven 4-strategy expand-and-search that
    /// handles iOS folding all ODOO notifications into one collapsed group.
    /// dx=0.15 (top-LEFT) is used to open NC — the center top hits the
    /// iPhone 16 Dynamic Island and never opens the center.
    private func _waitForNotification(containing marker: String, timeout: TimeInterval) -> Bool {
        springboard.activate()
        Thread.sleep(forTimeInterval: 0.3)
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.01))
        let mid = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6))
        top.press(forDuration: 0.1, thenDragTo: mid)
        Thread.sleep(forTimeInterval: 1.0)

        let markerPredicate = NSPredicate(format: "label CONTAINS[c] %@", marker)
        let appPredicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "ODOO", "Odoo"
        )

        func findNotification() -> Bool {
            springboard.scrollViews.matching(markerPredicate).count > 0
                || springboard.buttons.matching(markerPredicate).count > 0
                || springboard.otherElements.matching(markerPredicate).count > 0
                || springboard.staticTexts.matching(markerPredicate).count > 0
                || springboard.cells.matching(markerPredicate).count > 0
        }

        func findAppGroup() -> XCUIElement? {
            let scrollGroups = springboard.scrollViews.matching(appPredicate)
            if scrollGroups.count > 0 { return scrollGroups.firstMatch }
            let buttonGroups = springboard.buttons.matching(appPredicate)
            if buttonGroups.count > 0 { return buttonGroups.firstMatch }
            let cellGroups = springboard.cells.matching(appPredicate)
            if cellGroups.count > 0 { return cellGroups.firstMatch }
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if findNotification() { return true }
            if let group = findAppGroup() {
                group.tap()
                Thread.sleep(forTimeInterval: 1.5)
                if findNotification() { return true }
            }
            let focusPredicate = NSPredicate(
                format: "label CONTAINS '睡眠' OR label CONTAINS 'Sleep' OR label CONTAINS '專注' OR label CONTAINS 'Focus' OR label CONTAINS '勿擾'"
            )
            let focusScroll = springboard.scrollViews.matching(focusPredicate)
            let focusBtn = springboard.buttons.matching(focusPredicate)
            let focusElement: XCUIElement? = focusScroll.count > 0
                ? focusScroll.firstMatch
                : (focusBtn.count > 0 ? focusBtn.firstMatch : nil)
            if let focus = focusElement {
                focus.tap()
                Thread.sleep(forTimeInterval: 1.0)
                if let group = findAppGroup() {
                    group.tap()
                    Thread.sleep(forTimeInterval: 1.0)
                }
                if findNotification() { return true }
            }
            let swipeFrom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            let swipeTo = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            swipeFrom.press(forDuration: 0.1, thenDragTo: swipeTo)
            Thread.sleep(forTimeInterval: 1.5)
            if let group = findAppGroup() {
                group.tap()
                Thread.sleep(forTimeInterval: 1.0)
            }
            if findNotification() { return true }
            Thread.sleep(forTimeInterval: 2.0)
        }
        return findNotification()
    }

    /// Clears every notification group from the center so the next cycle starts
    /// clean. Matches by the 'clear-button' identifier first (locale-stable),
    /// then falls back to zh-TW / English labels. Best-effort: an already-empty
    /// center is the desired end state, so a missing clear affordance is fine.
    private func _clearNotificationCenter() {
        springboard.activate()
        Thread.sleep(forTimeInterval: 0.3)
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.01))
        let mid = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.6))
        top.press(forDuration: 0.1, thenDragTo: mid)
        Thread.sleep(forTimeInterval: 1.0)

        let clearButtons = springboard.buttons.matching(identifier: "clear-button")
        let clearCount = clearButtons.count
        if clearCount > 0 {
            for i in (0..<clearCount).reversed() {
                let btn = clearButtons.element(boundBy: i)
                if btn.exists {
                    btn.tap()
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        } else {
            let clearLabels = [
                "確認清除", "Clear All Notifications", "Clear All", "Clear", "全部清除", "清除",
            ]
            for label in clearLabels {
                let btn = springboard.buttons[label]
                if btn.waitForExistence(timeout: 1) {
                    btn.tap()
                    Thread.sleep(forTimeInterval: 0.3)
                    let confirm = springboard.buttons["Clear"]
                    if confirm.waitForExistence(timeout: 0.5) { confirm.tap() }
                    break
                }
            }
        }
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 0.5)
    }
}
