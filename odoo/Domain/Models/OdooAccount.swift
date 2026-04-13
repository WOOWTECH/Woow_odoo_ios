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

    init(
        id: String = UUID().uuidString,
        serverUrl: String,
        database: String,
        username: String,
        displayName: String,
        userId: Int? = nil,
        avatarBase64: String? = nil,
        lastLogin: Date = Date(),
        isActive: Bool = false
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
