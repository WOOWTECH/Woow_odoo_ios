import Foundation
import WebKit

/// Seam over `WKWebsiteDataStore` data removal, so tests can verify which
/// stores and data types "Clear Cache" touches without real WebKit I/O.
@MainActor
protocol WebsiteDataRemoving: AnyObject {
    func removeData(ofTypes dataTypes: Set<String>, modifiedSince date: Date) async
}

extension WKWebsiteDataStore: WebsiteDataRemoving {}

/// Manages cache clearing operations.
/// Ported from Android: CacheRepository.kt
final class CacheService {

    private let bytesPerKB: Int64 = 1024
    private let bytesPerMB: Int64 = 1024 * 1024

    /// Website data removed by "Clear Cache": WebKit HTTP caches plus site storage
    /// (same scope as Android `CacheRepository`: HTTP cache + WebStorage).
    /// Cookies are deliberately NOT included — the Odoo session lives in a cookie
    /// and clearing the cache must never sign the user out. Accounts, Keychain
    /// credentials and app settings are never touched here either.
    static let webViewDataTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeServiceWorkerRegistrations,
    ]

    /// Every WebKit data store the app's WebViews use. On iOS 17+ each account has
    /// an isolated `WKWebsiteDataStore(forIdentifier:)` (see `OdooWebViewCoordinator`),
    /// so clearing only `.default()` would miss every real account's cache.
    private let webViewDataStores: @MainActor () -> [WebsiteDataRemoving]

    init(webViewDataStores: @escaping @MainActor () -> [WebsiteDataRemoving] = {
        CacheService.dataStores(
            accountIds: AccountRepository().getAllAccounts().map(\.id),
            defaultStore: WKWebsiteDataStore.default(),
            storeForAccount: { OdooWebViewCoordinator.dataStore(forAccountId: $0) }
        )
    }) {
        self.webViewDataStores = webViewDataStores
    }

    /// The default store plus each account's store, each listed once (below
    /// iOS 17 every account shares `.default()`).
    @MainActor
    static func dataStores(
        accountIds: [String],
        defaultStore: WebsiteDataRemoving,
        storeForAccount: (String) -> WebsiteDataRemoving
    ) -> [WebsiteDataRemoving] {
        var stores: [WebsiteDataRemoving] = [defaultStore]
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(defaultStore)]
        for id in accountIds {
            let store = storeForAccount(id)
            if seen.insert(ObjectIdentifier(store)).inserted {
                stores.append(store)
            }
        }
        return stores
    }

    /// Clears app cache directory.
    func clearAppCache() {
        if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }

    /// Clears the WKWebView HTTP cache and site storage in every store the app's
    /// WebViews use (cookies excluded to preserve login; no account is removed).
    @MainActor
    func clearWebViewCache() async {
        for store in webViewDataStores() {
            await store.removeData(ofTypes: Self.webViewDataTypes, modifiedSince: .distantPast)
        }
    }

    /// Walks the app's `Caches` directory and sums the file sizes of all contained files.
    /// Returns the total size in bytes, or 0 if the directory cannot be located.
    func calculateCacheSize() -> Int64 {
        guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let enumerator = FileManager.default.enumerator(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Converts a byte count into a human-readable string using binary units (B, KB, MB).
    /// Rounds down to the nearest whole unit for KB and MB.
    func formatSize(_ bytes: Int64) -> String {
        switch bytes {
        case ..<bytesPerKB: return "\(bytes) B"
        case ..<bytesPerMB: return "\(bytes / bytesPerKB) KB"
        default: return "\(bytes / bytesPerMB) MB"
        }
    }

    /// Static convenience overload for contexts without a `CacheService` instance.
    static func formatSize(_ bytes: Int64) -> String {
        let service = CacheService()
        return service.formatSize(bytes)
    }
}
