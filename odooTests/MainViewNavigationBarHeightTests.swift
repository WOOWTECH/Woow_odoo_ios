//
//  MainViewNavigationBarHeightTests.swift
//  odooTests
//
//  demo111 live run 2026-09-29 run3 (D6): the main screen's native bar was sometimes 106 pt instead
//  of 54 pt — always on iPhone SE, and on iPhone 17 after some account switches — pushing the Odoo
//  page down ~52 pt (the avatar in Odoo's top-right became untappable once).
//
//  Cause: `MainView`'s root `NavigationStack` never sets a title display mode, so it is
//  `.automatic`, which on a stack's root means a LARGE title bar. There is no title text (the brand
//  name is a `.principal` item), so what shows is an empty large-title strip: expanded while the
//  tracked scroll view is at the top (a freshly built WebView after a switch; always when there is
//  no scroll view to collapse it), collapsed after scrolling. The bar must always be the inline one.
//

import XCTest
import SwiftUI
@testable import odoo

@MainActor
final class MainViewNavigationBarHeightTests: XCTestCase {

    private func navigationBars(in view: UIView) -> [UINavigationBar] {
        (view as? UINavigationBar).map { [$0] } ?? view.subviews.flatMap { navigationBars(in: $0) }
    }

    func test_mainView_navigationBar_isInlineHeight() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the unit-test host has a window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 667) // iPhone SE (3rd gen) points
        window.rootViewController = UIHostingController(rootView: MainView(onMenuClick: {}, onSessionExpired: {}))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        var bars: [UINavigationBar] = []
        for _ in 0..<50 {
            window.layoutIfNeeded()
            bars = navigationBars(in: window)
            if let bar = bars.first, bar.frame.height > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let bar = try XCTUnwrap(bars.first, "MainView must host a navigation bar")

        XCTAssertLessThanOrEqual(bar.frame.height, 60, "large-title strip present: \(bar.frame.height) pt")
        XCTAssertEqual(bar.topItem?.largeTitleDisplayMode, .never, "the main screen must never use a large title")
    }
}
