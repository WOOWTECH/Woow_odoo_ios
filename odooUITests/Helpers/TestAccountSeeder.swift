import Foundation

/// Builds the JSON payload used to seed a pre-authenticated account into the app under test.
///
/// The JSON is placed in `XCUIApplication.launchEnvironment["WOOW_SEED_ACCOUNT"]` before
/// `app.launch()`. On the production side, `AppDelegate.processTestLaunchArguments()` decodes
/// it and calls `AccountRepository.replaceAccountsForTesting(_:)`.
///
/// Field names must exactly match `SeededAccount` in the production target.
enum TestAccountSeeder {

    /// Produces a JSON string encoding a seeded account from the given parameters.
    ///
    /// - Parameters:
    ///   - serverURL: Full server URL (no trailing slash), e.g. `"https://my.tunnel.trycloudflare.com"`.
    ///   - database: Odoo database name, e.g. `"odoo18_ecpay"`.
    ///   - username: Odoo username, e.g. `"admin"`.
    ///   - sessionCookie: Raw cookie string returned by `OdooHelper.authenticate()`,
    ///                    in `"session_id=<value>"` form OR just the raw value.
    ///                    The production hook stores it verbatim in HTTPCookieStorage.
    /// - Returns: A JSON string, or `nil` if serialisation fails (should never happen
    ///            given the simple string inputs).
    static func seedJSON(
        serverURL: String,
        database: String,
        username: String,
        sessionCookie: String
    ) -> String? {
        // Extract just the session_id value if the caller passed "session_id=abc".
        let cookieValue: String
        if sessionCookie.hasPrefix("session_id=") {
            cookieValue = String(sessionCookie.dropFirst("session_id=".count))
        } else {
            cookieValue = sessionCookie
        }

        let dict: [String: String] = [
            "serverURL": serverURL,
            "database": database,
            "username": username,
            "sessionCookie": cookieValue,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
