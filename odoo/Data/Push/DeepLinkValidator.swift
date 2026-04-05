import Foundation

/// Validates deep link URLs to prevent injection attacks.
/// Uses allowlist approach — only permits canonical Odoo /web paths and https same-host URLs.
/// Ported from Android: DeepLinkValidator.kt (hardened per architect review).
enum DeepLinkValidator {

    /// Compiled regex for canonical Odoo relative paths.
    /// Matches: /web, /web/, /web#..., /web?..., /web/login, /web/action/...
    /// Rejects: /website/, /webapi/, /web@evil.com, /web/../
    private static let allowedRelativePathPattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^/web(?:[/?#]|$)"#,
        options: .caseInsensitive
    )

    /// Validates that an action URL is safe to load in WKWebView.
    ///
    /// Allowlist approach:
    /// - Relative paths matching `^/web([/?#]|$)` are allowed (canonical Odoo paths only)
    /// - Absolute URLs must be `https` scheme AND same host as the active server
    /// - Everything else is rejected (javascript:, data:, blob:, file:, ftp:, /website/, etc.)
    ///
    /// Path traversal sequences (`..`) are always rejected before any other check.
    /// Absolute URL validation requires a non-empty `serverHost` — passing `""` will reject
    /// all absolute URLs, preventing silent bypass when the active server is unknown.
    ///
    /// - Parameters:
    ///   - url: The URL from a notification deep link or custom URL scheme
    ///   - serverHost: The expected Odoo server hostname (e.g. "company.odoo.com").
    ///     Pass `account.serverHost` from the active account; do not pass an empty string.
    /// - Returns: true if the URL is safe to load
    static func isValid(url: String, serverHost: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Reject control characters (newline injection, header injection)
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return false
        }

        // Reject path traversal sequences in both raw and percent-encoded forms
        let lower = trimmed.lowercased()
        if lower.contains("..") || lower.contains("%2e%2e") {
            return false
        }

        // Allow only canonical Odoo relative paths — /web, /web/, /web#..., /web?...
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if allowedRelativePathPattern.firstMatch(in: trimmed, range: range) != nil {
            return true
        }

        // For absolute URLs: require https scheme, non-empty serverHost, and same host.
        // An empty serverHost means the active account is unknown — reject all absolute URLs
        // rather than silently allowing or silently rejecting with no indication to callers.
        guard !serverHost.isEmpty,
              let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "https",
              let urlHost = parsed.host else {
            return false
        }
        return urlHost.caseInsensitiveCompare(serverHost) == .orderedSame
    }
}
