import Foundation

/// Result of an Odoo authentication attempt.
/// Ported from Android: AuthResult.kt
enum AuthResult {
    case success(AuthSuccess)
    case error(String, ErrorType)

    struct AuthSuccess {
        let userId: Int
        let sessionId: String
        let username: String
        let displayName: String
    }

    enum ErrorType {
        case networkError
        case invalidUrl
        case databaseNotFound
        case invalidCredentials
        case sessionExpired
        case httpsRequired
        case serverError
        case unknown
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
