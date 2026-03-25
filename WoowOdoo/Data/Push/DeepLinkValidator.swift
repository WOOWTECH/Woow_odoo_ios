import Foundation

/// Validates deep link URLs to prevent injection attacks.
/// Direct port from Android: DeepLinkValidator.kt (same logic, same tests).
enum DeepLinkValidator {

    /// Validates that an action URL is safe to load in WKWebView.
    ///
    /// - Parameters:
    ///   - url: The URL from a notification deep link
    ///   - serverHost: The expected Odoo server hostname
    /// - Returns: true if the URL is safe to load
    static func isValid(url: String, serverHost: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()

        // Reject dangerous schemes
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") {
            return false
        }

        // Allow relative paths starting with /web
        if trimmed.hasPrefix("/web") {
            return true
        }

        // For absolute URLs, verify same host
        guard let parsed = URL(string: trimmed),
              let urlHost = parsed.host else {
            return false
        }
        return urlHost.caseInsensitiveCompare(serverHost) == .orderedSame
    }
}
