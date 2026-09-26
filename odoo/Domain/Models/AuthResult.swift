import Foundation

/// Result of an Odoo authentication attempt.
/// Ported from Android: AuthResult.kt
enum AuthResult: Sendable, Equatable {
    case success(AuthSuccess)
    case error(String, ErrorType)

    struct AuthSuccess: Sendable, Equatable {
        let userId: Int
        let sessionId: String
        let username: String
        let displayName: String
        let sessionCookie: PushSessionCookie?

        init(userId: Int, sessionId: String, username: String, displayName: String,
             sessionCookie: PushSessionCookie? = nil) {
            self.userId = userId
            self.sessionId = sessionId
            self.username = username
            self.displayName = displayName
            self.sessionCookie = sessionCookie
        }
    }

    enum ErrorType: Sendable, Equatable {
        case networkError
        case invalidUrl
        case databaseNotFound
        case invalidCredentials
        case sessionExpired
        case httpsRequired
        case serverError
        /// The server answered sign-in with this non-200 HTTP status (e.g. Cloudflare 530).
        case serverHTTPStatus(Int)
        case unknown
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Immutable serialization of the response cookie's properties, not a SID-to-root
/// cookie conversion. Absolute expiry is frozen so Max-Age cannot restart on load.
struct PushSessionCookie: Codable, Sendable, Equatable {
    private let propertiesData: Data

    init?(cookie: HTTPCookie, responseURL: URL, now: Date = Date()) {
        guard cookie.name == "session_id", let host = responseURL.host?.lowercased(),
              responseURL.scheme == "https", !cookie.path.isEmpty, cookie.path.hasPrefix("/"),
              cookie.expiresDate.map({ $0 > now }) ?? true else { return nil }
        let domain = cookie.domain.lowercased()
        let matchesDomain = domain.hasPrefix(".")
            ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
        // Cookie scope must cover the authenticate endpoint; never broaden it.
        let path = responseURL.path
        let matchesPath = path == cookie.path || (path.hasPrefix(cookie.path) &&
            (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
        guard matchesDomain, matchesPath, let properties = cookie.properties else { return nil }
        var encoded: [String: Any] = [:]
        for (key, value) in properties {
            encoded[key.rawValue] = (value as? URL)?.absoluteString ?? value
        }
        encoded.removeValue(forKey: HTTPCookiePropertyKey.maximumAge.rawValue)
        if let expires = cookie.expiresDate { encoded[HTTPCookiePropertyKey.expires.rawValue] = expires }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: encoded, format: .binary, options: 0) else { return nil }
        propertiesData = data
    }

    func cookie(now: Date = Date()) -> HTTPCookie? {
        guard let values = try? PropertyListSerialization.propertyList(from: propertiesData, options: [], format: nil) as? [String: Any],
              let cookie = HTTPCookie(properties: Dictionary(uniqueKeysWithValues: values.map { (HTTPCookiePropertyKey($0.key), $0.value) })),
              cookie.expiresDate.map({ $0 > now }) ?? true else { return nil }
        return cookie
    }
}
