import Foundation

extension String {
    /// Ensures the string has an "https://" prefix. If it already has exactly one, returns unchanged;
    /// repeated leading "https://" prefixes (any case) collapse to the last one.
    /// Converts "http://" prefix to "https://". Passes through other schemes (e.g. ftp://) unchanged.
    /// For bare domains (no scheme), prepends "https://".
    /// A scheme counts only at the very start (RFC 3986 `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`
    /// followed by "://"); a "://" inside a path (`host/erp/a://b`, accepted by ServerUrlInput) is not one.
    var ensureHTTPS: String {
        let https = "https://"
        if lowercased().hasPrefix(https) {
            var rest = Substring(self)
            while rest.dropFirst(https.count).lowercased().hasPrefix(https) {
                rest = rest.dropFirst(https.count)
            }
            return String(rest)
        }
        if lowercased().hasPrefix("http://") {
            return "https://" + dropFirst("http://".count)
        }
        // Pass through other schemes unchanged (e.g. ftp://, ssh://)
        if hasLeadingScheme { return self }
        return "https://\(self)"
    }

    private var hasLeadingScheme: Bool {
        range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
    }
}
