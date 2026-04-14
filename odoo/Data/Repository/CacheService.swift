import Foundation
import WebKit

/// Manages cache clearing operations.
/// Ported from Android: CacheRepository.kt
final class CacheService {

    private let bytesPerKB: Int64 = 1024
    private let bytesPerMB: Int64 = 1024 * 1024

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
