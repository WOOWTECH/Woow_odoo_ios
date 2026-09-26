import Foundation

/// Classifies what the user typed into the login form's server-URL field.
///
/// The field already shows a fixed `https://` prefix, yet users paste whole URLs,
/// type the scheme a second time, or leave stray whitespace. Before this existed,
/// `https://https://example.invalid` passed validation (`URL(string:)` parses the
/// second `https` as the host) and the credentials step echoed the doubled scheme;
/// `https;//example.invalid` likewise reached the summary as `https://https;//…`.
///
/// Ported from Android ServerUrlInput.kt (commit 34a6933), same outcome for the same input:
/// - leading/trailing whitespace is trimmed (Kotlin `trim()` set);
/// - any leading `http://` (any case) is rejected as insecure, even `http://https://…`;
/// - repeated leading `https://` prefixes (any case) collapse to one;
///   an `http://` left after that (`https://http://…`) is invalid;
/// - `#fragment` and `?query` are dropped;
/// - the host (text before the first `/`) must match
///   `^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:\d{1,5})?$` — ASCII only, so `_`,
///   `;`, spaces, full-width or IDN characters and any leftover scheme are invalid;
/// - a path starting with `web` or `odoo` (browser-copied Odoo page) is dropped,
///   any other path is kept without trailing `/` (sub-path deployments).
///
/// Text is compared per Unicode scalar, matching Kotlin's per-`Char` string functions.
/// Parity table: odooTests/ServerUrlInputTests.swift.
enum ServerUrlInput {

    enum Outcome: Equatable {
        /// Normalized `host[:port][/path]` with no scheme — the form supplies `https://`.
        /// Equals Android `displayValue(normalize(raw))`.
        case valid(String)
        case httpsRequired
        case invalid
    }

    private static let https = "https://"
    private static let http = "http://"

    /// Kotlin/JVM `Char.isWhitespace`: Zs/Zl/Zp plus TAB, LF, VT, FF, CR and U+001C–U+001F.
    private static let kotlinWhitespace: CharacterSet = {
        var set = CharacterSet.whitespaces // Zs + TAB
        set.insert(charactersIn: "\u{0A}\u{0B}\u{0C}\u{0D}\u{1C}\u{1D}\u{1E}\u{1F}\u{2028}\u{2029}")
        return set
    }()

    static func classify(_ raw: String) -> Outcome {
        var rest = raw.trimmingCharacters(in: kotlinWhitespace)
        if hasCaselessPrefix(rest, http) { return .httpsRequired }

        while hasCaselessPrefix(rest, https) {
            rest = String(rest.unicodeScalars.dropFirst(https.unicodeScalars.count))
        }
        if hasCaselessPrefix(rest, http) { return .invalid }

        rest = before("?", in: before("#", in: rest))
        let host = before("/", in: rest)
        guard isValidHost(host) else { return .invalid }

        let path = trimTrailingSlashes(after("/", in: rest))
        let keepPath = !path.isEmpty
            && !path.unicodeScalars.starts(with: "web".unicodeScalars)
            && !path.unicodeScalars.starts(with: "odoo".unicodeScalars)
        return .valid(keepPath ? "\(host)/\(path)" : host)
    }

    // MARK: - Host pattern `^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:\d{1,5})?$`

    private static func isValidHost(_ host: String) -> Bool {
        let scalars = Array(host.unicodeScalars)
        let colon = scalars.firstIndex(of: ":")
        let name = scalars[..<(colon ?? scalars.endIndex)]

        guard let first = name.first, let last = name.last,
              isAsciiAlphanumeric(first), isAsciiAlphanumeric(last),
              name.allSatisfy({ isAsciiAlphanumeric($0) || $0 == "." || $0 == "-" })
        else { return false }

        guard let colonIndex = colon else { return true }
        let port = scalars[(colonIndex + 1)...]
        return (1...5).contains(port.count) && port.allSatisfy(isAsciiDigit)
    }

    private static func isAsciiDigit(_ s: Unicode.Scalar) -> Bool { ("0"..."9").contains(s) }

    private static func isAsciiAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        isAsciiDigit(s) || ("a"..."z").contains(s) || ("A"..."Z").contains(s)
    }

    // MARK: - Scalar-wise string helpers (Kotlin substringBefore/After, startsWith, trimEnd)

    private static func hasCaselessPrefix(_ s: String, _ prefix: String) -> Bool {
        s.lowercased().unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    private static func before(_ delimiter: Unicode.Scalar, in s: String) -> String {
        guard let i = s.unicodeScalars.firstIndex(of: delimiter) else { return s }
        return String(s.unicodeScalars[..<i])
    }

    /// Text after the first `delimiter`, or "" when it is absent.
    private static func after(_ delimiter: Unicode.Scalar, in s: String) -> String {
        guard let i = s.unicodeScalars.firstIndex(of: delimiter) else { return "" }
        return String(s.unicodeScalars[s.unicodeScalars.index(after: i)...])
    }

    private static func trimTrailingSlashes(_ s: String) -> String {
        var scalars = s.unicodeScalars[...]
        while scalars.last == "/" { scalars = scalars.dropLast() }
        return String(scalars)
    }
}
