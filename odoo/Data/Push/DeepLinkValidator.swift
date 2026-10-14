import Foundation

/// Validates deep link URLs to prevent injection attacks.
/// Uses allowlist approach — only permits canonical Odoo /web paths and exact HTTPS-origin URLs.
/// Ported from Android: DeepLinkValidator.kt (hardened per architect review).
enum DeepLinkValidator {

    /// Compiled regex for canonical Odoo relative paths.
    /// Matches: /web, /web/, /web#..., /web?..., /web/login, /web/action/...
    /// Rejects: /website/, /webapi/, /web@evil.com, /web/../
    private static let allowedRelativePathPattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"^/web(?:[/?#]|$)"#,
        options: []  // Odoo paths are always lowercase — match strictly
    )

    /// Validates that an action URL is safe to load in WKWebView.
    ///
    /// Allowlist approach:
    /// - Relative paths matching `^/web([/?#]|$)` are allowed (canonical Odoo paths only)
    /// - Absolute URLs must match the active server's exact HTTPS origin
    /// - Everything else is rejected (javascript:, data:, blob:, file:, ftp:, /website/, etc.)
    ///
    /// Path traversal sequences (`..`) are always rejected before any other check.
    /// Absolute URL validation requires a complete valid `serverURL` — passing `""` will reject
    /// all absolute URLs, preventing silent bypass when the active server is unknown.
    ///
    /// - Parameters:
    ///   - url: The URL from a notification deep link or custom URL scheme
    ///   - serverURL: The complete expected Odoo server URL. Scheme, normalized host, and
    ///     effective HTTPS port are all part of the origin comparison.
    /// - Returns: true if the URL is safe to load
    static func isValid(url: String, serverURL: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == url else { return false }

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

        // Absolute links are account-internal only when their complete HTTPS origin matches.
        guard let parsed = URL(string: trimmed) else { return false }
        return isSameHTTPSOrigin(parsed, serverURL: serverURL)
    }

    /// Back-compatible host-only entry point for old callers/tests. It intentionally represents
    /// the default HTTPS origin (`:443`); production routing must pass the full server URL above.
    static func isValid(url: String, serverHost: String) -> Bool {
        guard !serverHost.isEmpty else { return isValid(url: url, serverURL: "") }
        var components = URLComponents()
        components.scheme = "https"
        components.host = serverHost
        return isValid(url: url, serverURL: components.url?.absoluteString ?? "")
    }

    /// Exact origin comparison used by both deep-link intake and WebView navigation. Explicit
    /// `:443` and the implicit HTTPS port are equivalent; a different port is a different origin.
    static func isSameHTTPSOrigin(_ candidate: URL, serverURL: String) -> Bool {
        guard let expectedURL = URL(string: serverURL),
              let candidateOrigin = HTTPSOrigin(candidate),
              let expectedOrigin = HTTPSOrigin(expectedURL) else { return false }
        return candidateOrigin == expectedOrigin
    }

    /// Blob URLs inherit the origin encoded after `blob:`. Only an exact account-origin blob is
    /// safe inside the WebView; opaque/malformed/cross-origin blobs are rejected.
    static func isSameOriginBlobURL(_ candidate: URL, serverURL: String) -> Bool {
        guard candidate.scheme?.lowercased() == "blob" else { return false }
        let raw = candidate.absoluteString
        guard raw.lowercased().hasPrefix("blob:"),
              let inner = URL(string: String(raw.dropFirst("blob:".count))) else { return false }
        return isSameHTTPSOrigin(inner, serverURL: serverURL)
    }

    private struct HTTPSOrigin: Equatable {
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard url.scheme?.lowercased() == "https", let rawHost = url.host else { return nil }
            var normalizedHost = rawHost.lowercased()
            while normalizedHost.hasSuffix(".") { normalizedHost.removeLast() }
            guard !normalizedHost.isEmpty else { return nil }
            host = normalizedHost
            port = url.port ?? 443
        }
    }
}
