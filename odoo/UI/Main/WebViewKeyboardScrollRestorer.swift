import UIKit

// MARK: - Policy (pure)

/// Where a `WKWebView`'s scroll view must sit once the software keyboard has gone away.
///
/// Why this exists: `MainView` lays the WebView out with `.ignoresSafeArea(edges: .bottom)`, whose
/// default regions include `.keyboard`. That is deliberate — WebKit performs its own keyboard
/// avoidance (it scrolls `scrollView` to keep the focused field visible), and letting SwiftUI ALSO
/// shrink the frame would double-adjust and resize Odoo's viewport (a relayout of the whole OWL
/// client) on every focus change. The cost is that WebKit does not scroll back when the keyboard
/// hides: after the Odoo search field was used, the page kept a ~17.7pt offset — navbar clipped at
/// the top, a strip of page background at the bottom — indefinitely (live run 2026-09-27, 21/22).
enum WebViewKeyboardScrollPolicy {

    /// The valid `contentOffset.y` range of a scroll view, as `UIScrollView` itself bounds it:
    /// from `-top` inset down to the point where the content's bottom (plus bottom inset) meets
    /// the bottom edge. Never inverted for content shorter than the viewport.
    static func verticalOffsetRange(contentHeight: CGFloat, boundsHeight: CGFloat,
                                    adjustedInsets: UIEdgeInsets) -> ClosedRange<CGFloat> {
        let minY = -adjustedInsets.top
        let maxY = max(minY, contentHeight - boundsHeight + adjustedInsets.bottom)
        return minY...maxY
    }

    /// The offset to apply after the keyboard hid, or `nil` when the page is already there.
    ///
    /// - The recorded pre-keyboard offset wins (clamped into the current range, the document may
    ///   have changed height meanwhile).
    /// - Without one, only an out-of-range residual is clamped.
    /// - Only `y` is restored; `x` is left as the page has it.
    ///
    /// Trade-off: a user who scrolls the DOCUMENT itself while the keyboard is up is returned to
    /// the pre-keyboard position. Odoo scrolls inside `.o_action_manager`, not the document, so
    /// this practically only undoes WebKit's own keyboard avoidance.
    static func restoredOffset(preKeyboard: CGPoint?, current: CGPoint, contentSize: CGSize,
                               boundsSize: CGSize, adjustedInsets: UIEdgeInsets) -> CGPoint? {
        let range = verticalOffsetRange(contentHeight: contentSize.height,
                                        boundsHeight: boundsSize.height,
                                        adjustedInsets: adjustedInsets)
        let desiredY = preKeyboard?.y ?? current.y
        let targetY = min(max(desiredY, range.lowerBound), range.upperBound)
        guard abs(targetY - current.y) > 0.5 else { return nil }
        return CGPoint(x: current.x, y: targetY)
    }
}

// MARK: - Restorer (notification wiring)

/// Records the WebView's scroll offset when a keyboard session starts and puts it back (via
/// `WebViewKeyboardScrollPolicy`) once the keyboard has fully hidden.
///
/// - `keyboardWillShowNotification` is re-posted on every keyboard frame change (switching fields,
///   the QuickType bar), so only the first one of a session is recorded.
/// - The restore runs on `keyboardDidHideNotification`, after WebKit's own hide animation, so it
///   is not overwritten by it.
/// - The scroll view is resolved through a closure at event time because the coordinator swaps
///   its child `WKWebView` on every account switch.
final class WebViewKeyboardScrollRestorer {
    private let scrollView: () -> UIScrollView?
    private var preKeyboardOffset: CGPoint?
    private var observers: [NSObjectProtocol] = []
    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default, scrollView: @escaping () -> UIScrollView?) {
        self.notificationCenter = notificationCenter
        self.scrollView = scrollView
        // UIKit posts keyboard notifications on the main thread; queue nil delivers synchronously.
        observers.append(notificationCenter.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.keyboardWillShow()
        })
        observers.append(notificationCenter.addObserver(
            forName: UIResponder.keyboardDidHideNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.keyboardDidHide()
        })
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }

    private func keyboardWillShow() {
        guard preKeyboardOffset == nil, let scrollView = scrollView() else { return }
        preKeyboardOffset = scrollView.contentOffset
    }

    private func keyboardDidHide() {
        defer { preKeyboardOffset = nil }
        guard let scrollView = scrollView(),
              let target = WebViewKeyboardScrollPolicy.restoredOffset(
                preKeyboard: preKeyboardOffset,
                current: scrollView.contentOffset,
                contentSize: scrollView.contentSize,
                boundsSize: scrollView.bounds.size,
                adjustedInsets: scrollView.adjustedContentInset
              ) else { return }
        scrollView.setContentOffset(target, animated: false)
    }
}
