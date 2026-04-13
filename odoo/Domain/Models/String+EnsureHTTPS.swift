import Foundation

extension String {
    /// Ensures the string has an "https://" prefix. If it already has one, returns unchanged.
    /// Converts "http://" prefix to "https://". Passes through other schemes (e.g. ftp://) unchanged.
    /// For bare domains (no scheme), prepends "https://".
    var ensureHTTPS: String {
        if lowercased().hasPrefix("https://") { return self }
        if lowercased().hasPrefix("http://") {
            return "https://" + dropFirst("http://".count)
        }
        // Pass through other schemes unchanged (e.g. ftp://, ssh://)
        if contains("://") { return self }
        return "https://\(self)"
    }
}
