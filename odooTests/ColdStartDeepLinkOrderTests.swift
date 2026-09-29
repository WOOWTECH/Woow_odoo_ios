//
//  ColdStartDeepLinkOrderTests.swift
//  odooTests
//
//  demo111 live run 2026-09-29 (D4): `apporoodoo-dev://open?url=/web#action=calendar…` opened
//  while the app was NOT running restored the account but stayed on the Discuss inbox; the same
//  link worked while the app was in the foreground.
//
//  Root cause: on cold start the coordinator builds the WebView first (deep link still nil),
//  injects the session cookie asynchronously and only loads the base page in the cookie-store
//  completion. The URL arrives a moment later through the "warm" branch, which applied it at
//  once and consumed it — before the base load had even been issued. The base load then
//  replaced the deep link, and the link was gone.
//
//  A link that arrives before the account's first page has finished must be queued and applied
//  load-gated (exactly like a link captured on an account switch); once the page is up, a new
//  link still applies immediately.
//

import XCTest
import WebKit
import SwiftUI
@testable import odoo

@MainActor
final class ColdStartDeepLinkOrderTests: XCTestCase {

    private let serverUrl = "https://cold.example.com"
    private var events: [String] = []

    /// Real coordinator + real child WKWebView with a non-persistent store: the session cookie is
    /// set through the real cookie store (whose completion issues the base load), but both loads
    /// are intercepted and only recorded — no request is ever issued. `didFinish` is driven through
    /// `accountPageDidFinish(loadedHost:)`, the same gate the WebKit delegate calls.
    private func makeCoordinator() -> OdooWebViewCoordinator {
        OdooWebViewCoordinator(
            serverUrl: serverUrl,
            onSessionExpired: {}, isLoading: .constant(false),
            openExternalURL: { _ in XCTFail("No Safari") },
            brand: .woowtech,
            websiteDataStore: { _ in .nonPersistent() },
            loadBaseRequest: { [weak self] _, _ in self?.events.append("base") },
            loadDeepLinkRequest: { [weak self] _, request in
                self?.events.append("deeplink:\(request.url?.fragment ?? "")")
            }
        )
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_linkArrivingBeforeFirstPageFinished_isAppliedAfterBaseLoad() async {
        let sut = makeCoordinator()
        let id = UUID().uuidString
        // Cold start: MainView appears before the URL is delivered.
        sut.apply(serverUrl: serverUrl, database: "db", accountId: id, sessionId: "sess", deepLink: nil)
        // onOpenURL → DeepLinkManager → MainViewModel → updateUIView, before the cookie callback.
        sut.apply(serverUrl: serverUrl, database: "db", accountId: id, sessionId: "sess",
                  deepLink: "/web#action=calendar.action_calendar_event")

        await waitUntil(self.events.contains("base"))
        sut.accountPageDidFinish(loadedHost: "cold.example.com")

        XCTAssertEqual(events.first, "base", "the base page must be requested first: \(events)")
        XCTAssertEqual(events.filter { $0 == "base" }.count, 1, "\(events)")
        XCTAssertEqual(events.last, "deeplink:action=calendar.action_calendar_event",
                       "the deep link must be applied after (not before) the base load: \(events)")
    }

    func test_linkArrivingAfterFirstPageFinished_isAppliedImmediately() async {
        let sut = makeCoordinator()
        let id = UUID().uuidString
        sut.apply(serverUrl: serverUrl, database: "db", accountId: id, sessionId: "sess", deepLink: nil)
        await waitUntil(self.events == ["base"])
        sut.accountPageDidFinish(loadedHost: "cold.example.com")
        XCTAssertTrue(sut.hasFinishedAccountLoad, "precondition: the base page finished")

        sut.apply(serverUrl: serverUrl, database: "db", accountId: id, sessionId: "sess",
                  deepLink: "/web#action=contacts.action_contacts")

        XCTAssertEqual(events, ["base", "deeplink:action=contacts.action_contacts"])
    }
}
