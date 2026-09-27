import XCTest
import SwiftUI
import WebKit
@testable import odoo

/// LIVE-0927-1 — after the Odoo search keyboard is dismissed, the page kept a ~17.7pt residual
/// scroll: the Odoo navbar was clipped at the top and a strip of page background (#f8f9fa, i.e.
/// INSIDE the WebView, not SwiftUI chrome) showed at the bottom, still there 5 s later.
///
/// Root cause: the WebView deliberately ignores the SwiftUI keyboard safe area
/// (`.ignoresSafeArea(edges: .bottom)` covers the `.keyboard` region) so WebKit does its own
/// keyboard avoidance by scrolling `WKWebView.scrollView`. When the keyboard hides WebKit does
/// not scroll back, leaving `contentOffset.y` past the page's natural position.
///
/// These tests pin the restore rule (pure) and its wiring (notification-driven, then through the
/// real coordinator-owned WKWebView). Whether WebKit's own post-hide adjustments leave the fix in
/// place on a real keyboard can only be confirmed on a simulator/device run.
@MainActor
final class WebViewKeyboardScrollRestorerTests: XCTestCase {

    // MARK: - Pure policy

    /// The live defect: page had no scroll before the keyboard, 17.7pt after it hid.
    func test_restoredOffset_givenLiveResidual_returnsPreKeyboardOffset() {
        let target = WebViewKeyboardScrollPolicy.restoredOffset(
            preKeyboard: CGPoint(x: 0, y: 0),
            current: CGPoint(x: 0, y: 17.7),
            contentSize: CGSize(width: 402, height: 758),
            boundsSize: CGSize(width: 402, height: 758),
            adjustedInsets: .zero
        )
        XCTAssertEqual(target, CGPoint(x: 0, y: 0))
    }

    /// No recorded pre-keyboard offset (e.g. the show notification was missed): still clamp a
    /// residual that lies beyond the valid scroll range.
    func test_restoredOffset_givenNoPreOffsetAndResidualBeyondMax_clampsToMax() {
        let target = WebViewKeyboardScrollPolicy.restoredOffset(
            preKeyboard: nil,
            current: CGPoint(x: 0, y: 17.7),
            contentSize: CGSize(width: 402, height: 758),
            boundsSize: CGSize(width: 402, height: 758),
            adjustedInsets: .zero
        )
        XCTAssertEqual(target, CGPoint(x: 0, y: 0))
    }

    /// A page that was legitimately scrolled before the keyboard returns to THAT position,
    /// not to the top.
    func test_restoredOffset_givenScrolledPageBeforeKeyboard_restoresThatOffset() {
        let target = WebViewKeyboardScrollPolicy.restoredOffset(
            preKeyboard: CGPoint(x: 0, y: 120),
            current: CGPoint(x: 0, y: 300),
            contentSize: CGSize(width: 402, height: 2000),
            boundsSize: CGSize(width: 402, height: 758),
            adjustedInsets: .zero
        )
        XCTAssertEqual(target, CGPoint(x: 0, y: 120))
    }

    /// The document shrank while the keyboard was up: the recorded offset is clamped into the
    /// new valid range instead of scrolling past the end again.
    func test_restoredOffset_givenPreOffsetBeyondShrunkContent_clampsToNewMax() {
        let target = WebViewKeyboardScrollPolicy.restoredOffset(
            preKeyboard: CGPoint(x: 0, y: 500),
            current: CGPoint(x: 0, y: 500),
            contentSize: CGSize(width: 402, height: 958),
            boundsSize: CGSize(width: 402, height: 758),
            adjustedInsets: .zero
        )
        XCTAssertEqual(target, CGPoint(x: 0, y: 200))
    }

    /// Top/bottom adjusted insets widen the valid range the same way UIScrollView does.
    func test_verticalOffsetRange_givenInsets_matchesScrollViewBounds() {
        let range = WebViewKeyboardScrollPolicy.verticalOffsetRange(
            contentHeight: 1000,
            boundsHeight: 758,
            adjustedInsets: UIEdgeInsets(top: 10, left: 0, bottom: 34, right: 0)
        )
        XCTAssertEqual(range.lowerBound, -10)
        XCTAssertEqual(range.upperBound, 1000 - 758 + 34)
    }

    /// Nothing to do when the page already sits where it should — no redundant scroll writes.
    func test_restoredOffset_givenAlreadyAtTarget_returnsNil() {
        let target = WebViewKeyboardScrollPolicy.restoredOffset(
            preKeyboard: CGPoint(x: 0, y: 0),
            current: CGPoint(x: 0, y: 0),
            contentSize: CGSize(width: 402, height: 758),
            boundsSize: CGSize(width: 402, height: 758),
            adjustedInsets: .zero
        )
        XCTAssertNil(target)
    }

    // MARK: - Notification wiring

    private func makeScrollView(contentHeight: CGFloat = 758) -> UIScrollView {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 758))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: 402, height: contentHeight)
        return scrollView
    }

    func test_keyboardDidHide_afterWebKitScrolledForKeyboard_restoresPreKeyboardOffset() {
        let center = NotificationCenter()
        let scrollView = makeScrollView()
        let restorer = WebViewKeyboardScrollRestorer(notificationCenter: center) { scrollView }

        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        scrollView.contentOffset = CGPoint(x: 0, y: 17.7) // WebKit's keyboard avoidance
        center.post(name: UIResponder.keyboardDidHideNotification, object: nil)

        XCTAssertEqual(scrollView.contentOffset, .zero, "鍵盤收起後必須回到鍵盤出現前的位置")
        withExtendedLifetime(restorer) {}
    }

    /// keyboardWillShow fires again on every keyboard frame change (field switch, QuickType bar).
    /// Only the FIRST one of a keyboard session is the true pre-keyboard position.
    func test_repeatedKeyboardWillShow_recordsOnlyFirstOffset() {
        let center = NotificationCenter()
        let scrollView = makeScrollView(contentHeight: 2000)
        let restorer = WebViewKeyboardScrollRestorer(notificationCenter: center) { scrollView }

        scrollView.contentOffset = CGPoint(x: 0, y: 40)
        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        scrollView.contentOffset = CGPoint(x: 0, y: 260)
        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        center.post(name: UIResponder.keyboardDidHideNotification, object: nil)

        XCTAssertEqual(scrollView.contentOffset, CGPoint(x: 0, y: 40))
        withExtendedLifetime(restorer) {}
    }

    /// Each keyboard session starts fresh: the second session's pre-keyboard offset wins.
    func test_secondKeyboardSession_usesItsOwnPreKeyboardOffset() {
        let center = NotificationCenter()
        let scrollView = makeScrollView(contentHeight: 2000)
        let restorer = WebViewKeyboardScrollRestorer(notificationCenter: center) { scrollView }

        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        scrollView.contentOffset = CGPoint(x: 0, y: 90)
        center.post(name: UIResponder.keyboardDidHideNotification, object: nil)
        XCTAssertEqual(scrollView.contentOffset, .zero)

        scrollView.contentOffset = CGPoint(x: 0, y: 300)
        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        scrollView.contentOffset = CGPoint(x: 0, y: 420)
        center.post(name: UIResponder.keyboardDidHideNotification, object: nil)

        XCTAssertEqual(scrollView.contentOffset, CGPoint(x: 0, y: 300))
        withExtendedLifetime(restorer) {}
    }

    // MARK: - Coordinator wiring (real WKWebView)

    /// The coordinator must own a restorer bound to its CURRENT child WKWebView — the defect lives
    /// in production wiring, so testing the helper alone is not enough.
    func test_coordinator_keyboardDidHide_restoresChildWebViewScrollOffset() throws {
        final class LoadingBox { var value = false }
        let box = LoadingBox()
        let center = NotificationCenter()
        let coordinator = OdooWebViewCoordinator(
            serverUrl: "https://odoo.example.com",
            onSessionExpired: {},
            isLoading: Binding(get: { box.value }, set: { box.value = $0 }),
            openExternalURL: { _ in XCTFail("No Safari") },
            brand: .woowtech,
            websiteDataStore: { _ in .nonPersistent() },
            loadBaseRequest: { _, _ in },
            keyboardNotifications: center
        )
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 758))
        coordinator.attach(to: container)
        coordinator.apply(serverUrl: "https://odoo.example.com", database: "db",
                          accountId: UUID().uuidString, sessionId: nil, deepLink: nil)
        container.layoutIfNeeded()
        let webView = try XCTUnwrap(container.subviews.compactMap { $0 as? WKWebView }.first)

        center.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        webView.scrollView.contentOffset = CGPoint(x: 0, y: 17.7)
        center.post(name: UIResponder.keyboardDidHideNotification, object: nil)

        XCTAssertEqual(webView.scrollView.contentOffset.y, 0, accuracy: 0.01,
                       "coordinator 的 WKWebView 鍵盤收起後仍殘留偏移")
    }
}
