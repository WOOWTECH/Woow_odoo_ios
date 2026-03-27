import Foundation
import WebKit

/// Manages cache clearing operations.
/// Ported from Android: CacheRepository.kt
final class CacheService {

    /// Clears app cache directory.
    func clearAppCache() {
        if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }

    /// Clears WKWebView data (cookies excluded to preserve login).
    @MainActor
    func clearWebViewCache() async {
        let dataStore = WKWebsiteDataStore.default()
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records)
    }

    /// Calculates cache directory size in bytes.
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

    /// Formats bytes to human-readable string.
    static func formatSize(_ bytes: Int64) -> String {
        switch bytes {
        case ..<1024: return "\(bytes) B"
        case ..<(1024 * 1024): return "\(bytes / 1024) KB"
        default: return "\(bytes / (1024 * 1024)) MB"
        }
    }
}
