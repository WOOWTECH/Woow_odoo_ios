import Foundation

/// Classifies what the user typed into the login form's server-URL field.
///
/// The field already shows a fixed `https://` prefix, yet users paste whole URLs,
/// type the scheme a second time, or leave stray whitespace. Before this existed,
/// `https://https://example.invalid` passed validation (`URL(string:)` parses the
/// second `https` as the host) and the credentials step echoed the doubled scheme.
///
/// Outcomes match Android for scheme handling:
/// - leading/trailing whitespace is trimmed;
/// - any leading `http://` (any case) is rejected as insecure, even `http://https://…`;
/// - repeated leading `https://` prefixes (any case) collapse to one;
/// - a scheme still present after that (`https://http://…`, `https://ftp://…`) is invalid.
///
/// Ported from Android: ServerUrlInput.kt (scheme handling only; Android's
/// `/web`/`/odoo` path stripping and host-character pattern are not ported).
enum ServerUrlInput {

    enum Outcome: Equatable {
        /// Normalized `host[:port][/path]` with no scheme — the form supplies `https://`.
        case valid(String)
        case httpsRequired
        case invalid
    }

    private static let https = "https://"
    private static let http = "http://"

    static func classify(_ raw: String) -> Outcome {
        var rest = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.lowercased().hasPrefix(http) { return .httpsRequired }

        while rest.lowercased().hasPrefix(https) {
            rest = String(rest.dropFirst(https.count))
        }
        // Whatever scheme is left can only be a typo or a downgrade attempt.
        guard !rest.contains("://") else { return .invalid }

        guard let host = URL(string: https + rest)?.host, !host.isEmpty else { return .invalid }
        return .valid(rest)
    }
}
