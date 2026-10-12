import XCTest
@testable import odoo

@MainActor
final class RepeatedPushEventTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "RepeatedPushEventTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func test_newSameURL_eventIdentityReachesViewModel_andOldConsumeCannotClearIt() throws {
        let manager = DeepLinkManager(defaults: defaults)
        let repo = MockAccountRepository()
        let account = OdooAccount(serverUrl: "https://push.example.com", database: "db",
                                  username: "push-user", displayName: "Push User")
        repo.stubbedActiveAccount = account
        let vm = MainViewModel(accountRepository: repo, deepLinkManager: manager)
        let link = "/web#active_id=discuss.channel_42"
        manager.setPending(link, accountId: account.id)
        vm.loadActiveAccount()
        let first = try XCTUnwrap(vm.pendingDeepLinkEvent)
        manager.setPending(link, accountId: account.id)
        vm.loadActiveAccount()
        let second = try XCTUnwrap(vm.pendingDeepLinkEvent)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(vm.pendingDeepLink, link)
        XCTAssertNil(manager.consume(for: account.id, eventId: first.id))
        XCTAssertEqual(manager.pending?.id, second.id)
        XCTAssertNil(manager.consume(for: "foreign-account", eventId: second.id))
        XCTAssertEqual(manager.consume(for: account.id, eventId: second.id), link)
        XCTAssertNil(manager.consume(for: account.id, eventId: second.id))
        vm.loadActiveAccount()
        XCTAssertNil(vm.pendingDeepLinkEvent)
        XCTAssertNil(vm.pendingDeepLink)
    }
}
