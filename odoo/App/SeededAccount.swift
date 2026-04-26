#if DEBUG

import Foundation

/// Represents a pre-authenticated account seeded into the app at launch by an XCUITest.
///
/// The test encodes this as JSON in the `WOOW_SEED_ACCOUNT` launch-environment variable.
/// AppDelegate decodes it and calls `AccountRepository.replaceAccountsForTesting(_:)` so
/// the WebView opens directly to the Odoo dashboard without a login round-trip.
///
/// Field names are intentionally stable — the XCUITest `TestAccountSeeder` must produce JSON
/// with exactly these keys.
struct SeededAccount: Decodable, Sendable {
    /// The full server URL, e.g. "https://subscriptions-micro-enormous-eternal.trycloudflare.com".
    let serverURL: String
    /// Odoo database name, e.g. "odoo18_ecpay".
    let database: String
    /// Odoo username, e.g. "admin".
    let username: String
    /// The raw `session_id` cookie value obtained from JSON-RPC authenticate.
    let sessionCookie: String
}

#endif
