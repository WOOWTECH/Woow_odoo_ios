import XCTest
import WebKit
@testable import odoo

/// W1-10: "Clear Cache" must clear the WKWebView HTTP cache and site storage in
/// every store the app uses (default + per-account on iOS 17+), and must never
/// clear cookies (the Odoo session) or remove accounts.
@MainActor
final class CacheServiceClearTests: XCTestCase {

    private final class FakeStore: WebsiteDataRemoving {
        private(set) var calls: [(types: Set<String>, since: Date)] = []
        func removeData(ofTypes dataTypes: Set<String>, modifiedSince date: Date) async {
            calls.append((dataTypes, date))
        }
    }

    func test_webViewDataTypes_includeHTTPCacheAndSiteStorage_excludeCookies() {
        let types = CacheService.webViewDataTypes
        for required in [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache,
                         WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                         WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases,
                         WKWebsiteDataTypeServiceWorkerRegistrations] {
            XCTAssertTrue(types.contains(required), required)
        }
        XCTAssertFalse(types.contains(WKWebsiteDataTypeCookies))
    }

    func test_clearWebViewCache_givenDefaultAndAccountStores_clearsEveryStoreOnceWithAllData() async {
        let stores = [FakeStore(), FakeStore(), FakeStore()]
        let service = CacheService(webViewDataStores: { stores })

        await service.clearWebViewCache()

        for store in stores {
            XCTAssertEqual(store.calls.count, 1)
            XCTAssertEqual(store.calls.first?.types, CacheService.webViewDataTypes)
            XCTAssertEqual(store.calls.first?.since, .distantPast)
        }
    }

    func test_dataStores_givenIsolatedAccountStores_returnsDefaultPlusEachAccount() {
        let defaultStore = FakeStore()
        let perAccount = ["a": FakeStore(), "b": FakeStore()]

        let stores = CacheService.dataStores(accountIds: ["a", "b"], defaultStore: defaultStore,
                                             storeForAccount: { perAccount[$0]! })

        XCTAssertEqual(stores.map(ObjectIdentifier.init),
                       [defaultStore, perAccount["a"]!, perAccount["b"]!].map(ObjectIdentifier.init))
    }

    func test_dataStores_givenAccountsSharingDefaultStore_listsDefaultOnce() {
        // Below iOS 17 (or a non-UUID id) every account uses `.default()`.
        let defaultStore = FakeStore()

        let stores = CacheService.dataStores(accountIds: ["a", "b"], defaultStore: defaultStore,
                                             storeForAccount: { _ in defaultStore })

        XCTAssertEqual(stores.map(ObjectIdentifier.init), [ObjectIdentifier(defaultStore)])
    }

    func test_clearWebViewCache_givenRealStoreWithSessionCookie_keepsCookie() async throws {
        // Real WebKit store (in-memory, so nothing on disk is touched).
        let store = WKWebsiteDataStore.nonPersistent()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "cache-clear.invalid", .path: "/", .name: "session_id", .value: "fixture",
            .expires: Date(timeIntervalSinceNow: 3600),
        ]))
        await store.httpCookieStore.setCookie(cookie)
        let service = CacheService(webViewDataStores: { [store] })

        await service.clearWebViewCache()

        let cookies = await store.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.contains { $0.name == "session_id" && $0.domain.contains("cache-clear.invalid") })
    }

    func test_settingsClearCache_givenInjectedService_clearsWebViewStores() async throws {
        let store = FakeStore()
        let vm = SettingsViewModel(cacheService: CacheService(webViewDataStores: { [store] }))

        vm.clearCache()

        // clearCache launches its own Task; poll with a bound instead of a fixed sleep.
        for _ in 0..<100 where store.calls.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.calls.count, 1)
        XCTAssertEqual(store.calls.first?.types, CacheService.webViewDataTypes)
    }
}
