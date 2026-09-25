import XCTest
@testable import odoo

@MainActor
final class MockPushTokenRepositoryConcurrencyTests: XCTestCase {
    func test_concurrentRegistrations_preserveEveryRecordAndCallback() async {
        let count = 256
        let repository = MockPushTokenRepository()
        let callbacks = expectation(description: "one callback per recorded registration")
        callbacks.expectedFulfillmentCount = count
        repository.onRegister = { callbacks.fulfill() }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    await repository.registerTokenWithAllAccounts("fixture-\(index)")
                }
            }
        }
        await fulfillment(of: [callbacks], timeout: 2)
        XCTAssertEqual(repository.registeredTokens.count, count)
        XCTAssertEqual(Set(repository.registeredTokens), Set((0..<count).map { "fixture-\($0)" }))
    }

    func test_registrationCallback_canReenterAndObservePublishedRecord() async {
        let repository = MockPushTokenRepository(storedToken: "fixture-current")
        let callback = expectation(description: "callback can read and write without deadlock")
        repository.onRegister = {
            XCTAssertEqual(repository.registeredTokens, ["fixture-registration"])
            XCTAssertEqual(repository.getToken(), "fixture-current")
            repository.saveToken("fixture-updated")
            callback.fulfill()
        }

        await repository.registerTokenWithAllAccounts("fixture-registration")
        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(repository.getToken(), "fixture-updated")
    }
}
