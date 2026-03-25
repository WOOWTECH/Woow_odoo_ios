import Foundation

/// Represents a connected Odoo server account.
/// Ported from Android: OdooAccount.kt
struct OdooAccount: Identifiable, Codable, Equatable {
    let id: String
    var serverUrl: String
    var database: String
    var username: String
    var displayName: String
    var userId: Int?
    var avatarBase64: String?
    var lastLogin: Date
    var isActive: Bool

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
    var fullServerUrl: String {
        serverUrl.hasPrefix("https://") ? serverUrl : "https://\(serverUrl)"
    }
}
