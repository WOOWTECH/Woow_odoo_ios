//
//  ExternalLinkIntakeTests.swift
//  odooTests
//
//  F3 (0930): an external `<scheme>://open?url=…` link was queued UNBOUND (empty account id), so
//  after an account switch a relative `/web#…` path was applied to whichever account was active by
//  then — a link opened for account A landed in account B. It was also queued with no signed-in
//  account at all. Android's `ExternalLinkIntake` binds the link to the account that was active
//  when it arrived and ignores it when nobody is signed in; iOS now does the same, and a plain
//  account switch drops a link bound to another account.
//

import XCTest
@testable import odoo

@MainActor
final class ExternalLinkIntakeTests: XCTestCase {

    private var defaults: UserDefaults!
    private var manager: DeepLinkManager!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: "ExternalLinkIntakeTests-\(UUID().uuidString)")
        manager = DeepLinkManager(defaults: defaults)
    }

    private func account(_ username: String, server: String = "https://same.example.com") -> OdooAccount {
        OdooAccount(serverUrl: server, database: "db", username: username, displayName: username, isActive: true)
    }

    private func link(_ path: String) -> URL {
        var components = URLComponents()
        components.scheme = AppBrand.current.urlScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: path)]
        return components.url!
    }

    func test_accept_bindsLinkToTheActiveAccount() {
        let a = account("tester")

        let queued = ExternalLinkIntake.accept(link("/web#action=contacts"), activeAccount: a, manager: manager)

        XCTAssertTrue(queued)
        XCTAssertEqual(manager.pending?.url, "/web#action=contacts")
        XCTAssertEqual(manager.pending?.accountId, a.id, "the link belongs to the account active on arrival")
    }

    func test_accept_withoutSignedInAccount_ignoresTheLink() {
        let queued = ExternalLinkIntake.accept(link("/web#action=contacts"), activeAccount: nil, manager: manager)

        XCTAssertFalse(queued)
        XCTAssertNil(manager.pending, "no signed-in account → nothing to apply it to")
    }

    func test_accept_absoluteLinkOnAnotherHost_isRejected() {
        let queued = ExternalLinkIntake.accept(link("https://evil.example.org/web"), activeAccount: account("tester"),
                                               manager: manager)
        XCTAssertFalse(queued)
        XCTAssertNil(manager.pending)
    }

    /// A→B switch: a link bound to A never reaches B and is dropped.
    func test_switchToAnotherAccount_dropsLinkBoundToThePreviousAccount() async {
        let a = account("tester"), b = account("mate")
        ExternalLinkIntake.accept(link("/web#action=contacts"), activeAccount: a, manager: manager)
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = b
        let vm = MainViewModel(accountRepository: repo, deepLinkManager: manager)
        XCTAssertNil(vm.pendingDeepLink, "A's link is never exposed to B")

        NotificationCenter.default.post(name: .activeAccountDidChange, object: nil)
        for _ in 0..<100 where manager.pending != nil { try? await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertNil(manager.pending, "a link bound to the previous account is dropped on switch")
        withExtendedLifetime(vm) {}
    }

    /// Push-tap order: the switch happens first, then the link is bound to the NEW active account —
    /// the switch notification must not drop it.
    func test_switchNotification_keepsLinkBoundToTheNewActiveAccount() async {
        let b = account("mate")
        let repo = MockAccountRepository()
        repo.stubbedActiveAccount = b
        let vm = MainViewModel(accountRepository: repo, deepLinkManager: manager)
        manager.setPending("/web#action=calendar", accountId: b.id)

        NotificationCenter.default.post(name: .activeAccountDidChange, object: nil)
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(manager.pending?.accountId, b.id)
        XCTAssertEqual(vm.pendingDeepLink, "/web#action=calendar")
    }
}
