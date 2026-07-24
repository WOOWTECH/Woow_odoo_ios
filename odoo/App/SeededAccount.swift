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
    /// The opaque tenant id the app would normally learn during FCM device registration.
    ///
    /// Optional so single-account seeds stay backward compatible. Multi-account cross-tenant
    /// deep-link tests MUST set this: `NotificationDeepLinkRouter` resolves an incoming
    /// `odoo_tenant_id` to a local account by matching this value, so an account seeded without
    /// it can never be the target of a cross-account notification tap.
    ///
    /// Declared `var … = nil` (not `let`) so the synthesized memberwise initializer keeps it
    /// optional for existing single-account callers, while `Decodable` still decodes it when the
    /// JSON provides it (a default value only applies when the key is absent).
    var tenantId: String? = nil
    /// Whether this account should be the active one after seeding.
    ///
    /// Optional (defaults to the single-seed behaviour of "active"). When seeding several
    /// accounts at once, exactly one should set this to `true`; the rest stay inactive so the
    /// test can verify a switch *to* one of them.
    var isActive: Bool? = nil
}

#endif
