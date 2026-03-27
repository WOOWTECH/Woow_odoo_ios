import Foundation

/// Validates deep link URLs to prevent injection attacks.
/// Uses allowlist approach — only permits relative /web paths and https same-host URLs.
/// Ported from Android: DeepLinkValidator.kt (hardened per architect review).
enum DeepLinkValidator {

    /// Validates that an action URL is safe to load in WKWebView.
    ///
    /// Allowlist approach:
    /// - Relative paths starting with `/web` are always allowed
    /// - Absolute URLs must be `https` scheme AND same host
    /// - Everything else is rejected (javascript:, data:, blob:, file:, ftp:, etc.)
    ///
    /// - Parameters:
    ///   - url: The URL from a notification deep link
    ///   - serverHost: The expected Odoo server hostname
    /// - Returns: true if the URL is safe to load
    static func isValid(url: String, serverHost: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Reject URLs containing control characters (newline injection, header injection)
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return false
        }

        // Allow relative paths starting with /web
        if trimmed.hasPrefix("/web") {
            return true
        }

        // For absolute URLs: only allow https with same host
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "https",
              let urlHost = parsed.host else {
            return false
        }
        return urlHost.caseInsensitiveCompare(serverHost) == .orderedSame
    }
}
