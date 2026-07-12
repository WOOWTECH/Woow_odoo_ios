import Foundation

/// Represents a connected Odoo server account.
/// Ported from Android: OdooAccount.kt
struct OdooAccount: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let serverUrl: String
    let database: String
    let username: String
    let displayName: String
    let userId: Int?
    let avatarBase64: String?
    let lastLogin: Date
    let isActive: Bool
    /// Opaque tenant identifier issued by the Odoo server at device registration.
    ///
    /// This is the routing key for multi-account push notifications: an incoming FCM
    /// payload carries the originating server's `odoo_tenant_id`, and the app matches it
    /// against this value to find the local account that owns the notification. It is
    /// `nil` for accounts registered before this field existed (lightweight-migration
    /// default) or before the server has returned a tenant id.
    let tenantId: String?

    init(
        id: String = UUID().uuidString,
        serverUrl: String,
        database: String,
        username: String,
        displayName: String,
        userId: Int? = nil,
        avatarBase64: String? = nil,
        lastLogin: Date = Date(),
        isActive: Bool = false,
        tenantId: String? = nil
    ) {
        self.id = id
        self.serverUrl = serverUrl
        self.database = database
        self.username = username
        self.displayName = displayName
        self.userId = userId
        self.avatarBase64 = avatarBase64
        self.lastLogin = lastLogin
        self.isActive = isActive
        self.tenantId = tenantId
    }

    /// Returns server URL with https:// prefix guaranteed.
    /// Handles bare domains, http:// → https://, and preserves existing https://.
    var fullServerUrl: String {
        serverUrl.ensureHTTPS
    }

    /// Returns the hostname component of serverUrl for use as a Keychain key scope
    /// and deep link validation. Falls back to the raw serverUrl string if parsing fails.
    var serverHost: String {
        URL(string: fullServerUrl)?.host ?? serverUrl
    }
}
