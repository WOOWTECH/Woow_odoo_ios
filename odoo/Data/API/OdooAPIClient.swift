import Foundation
import os

/// Odoo JSON-RPC 2.0 API client using URLSession async/await.
/// Ported from: Android OdooJsonRpcClient.kt + OdooJsonRpcClient (kasim1011) patterns.
///
/// Key design decisions from reference project:
/// - Single CallKw endpoint for all CRUD operations
/// - Auto-incrementing request IDs with "r" prefix after auth
/// - Session cookies managed automatically by URLSession
/// - HTTPS-only enforcement
actor OdooAPIClient {

    private let session: URLSession
    private let logger = Logger(subsystem: "io.woowtech.odoo", category: "API")
    private var requestId: Int = 0

    /// Default init with standard URLSession configuration.
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpCookieStorage = .shared
        #if DEBUG && UNIT_TEST_HOST
        // Explicit session configuration, independent of global URLProtocol precedence.
        config.protocolClasses = [OfflineUnitHostURLProtocol.self]
        #endif
        self.session = URLSession(configuration: config)
    }

    /// Testable init — inject custom URLSession with MockURLProtocol.
    init(session: URLSession) {
        self.session = session
    }

    // MARK: - Request ID Generation
    // Ported from OdooJsonRpcClient: Odoo.kt jsonRpcId

    private func nextRequestId(authenticated: Bool = false) -> String {
        requestId += 1
        return authenticated ? "r\(requestId)" : "\(requestId)"
    }

    // MARK: - Authentication

    /// Authenticates with an Odoo server via JSON-RPC.
    /// Ported from Android: OdooJsonRpcClient.authenticate()
    func authenticate(
        serverUrl: String,
        database: String,
        username: String,
        password: String
    ) async -> AuthResult {
        await authenticate(serverUrl: serverUrl, database: database, username: username,
                           password: password, isolatedPushSession: false)
    }

    /// Account-scoped push healing never reads or writes the shared cookie jar.
    func authenticatePushSession(
        serverUrl: String, database: String, username: String, password: String
    ) async -> AuthResult {
        await authenticate(serverUrl: serverUrl, database: database, username: username,
                           password: password, isolatedPushSession: true)
    }

    private func authenticate(
        serverUrl: String, database: String, username: String, password: String,
        isolatedPushSession: Bool
    ) async -> AuthResult {
        // HTTPS enforcement (ported from Android)
        guard serverUrl.hasPrefix("https://") else {
            return .error("HTTPS required", .httpsRequired)
        }

        let url = "\(serverUrl)/web/session/authenticate"
        let params = AuthenticateParams(db: database, login: username, password: password)
        let request = JsonRpcRequest(id: nextRequestId(), params: params)

        do {
            let (data, response) = try await post(url: url, body: request, pushSessionId: isolatedPushSession ? "" : nil)

            guard let httpResponse = response as? HTTPURLResponse else {
                // URLSession reports malformed responses as URLError(.badServerResponse); same bucket.
                return .error("Unable to connect to server", .networkError)
            }
            guard httpResponse.statusCode == 200 else {
                // Status only; LoginViewModel renders the localized text (`error_server_http_%lld`).
                return .error("HTTP \(httpResponse.statusCode)", .serverHTTPStatus(httpResponse.statusCode))
            }

            let decoded = try JSONDecoder().decode(
                JsonRpcResponse<AuthenticateResult>.self,
                from: data
            )

            if let error = decoded.error, let msg = error.data?.message ?? error.message {
                return Self.mapOdooError(message: msg, exceptionName: error.data?.name)
            }

            guard let result = decoded.result,
                  let uid = result.uid, uid > 0 else {
                return .error("Invalid credentials", .invalidCredentials)
            }

            let sessionId: String
            var sessionCookie: PushSessionCookie?
            if isolatedPushSession {
                let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) {
                    if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value }
                }
                guard let responseURL = httpResponse.url, responseURL.absoluteString == url else {
                    return .error(String(localized: "error_session_setup"), .serverError)
                }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: responseURL)
                    .filter { $0.name == "session_id" }
                guard cookies.count == 1, let cookie = cookies.first,
                      let validated = PushSessionCookie(cookie: cookie, responseURL: responseURL) else {
                    return .error(String(localized: "error_session_setup"), .serverError)
                }
                sessionCookie = validated
                sessionId = cookie.value
                guard Self.isValidPushSessionId(sessionId),
                      result.db == nil || result.db == database,
                      result.username == nil || result.username == username else {
                    return .error(String(localized: "error_session_setup"), .serverError)
                }
            } else {
                sessionId = getSessionId(for: serverUrl) ?? ""
            }
            let name = result.name ?? username

            return .success(AuthResult.AuthSuccess(
                userId: uid,
                sessionId: sessionId,
                username: username,
                displayName: name,
                sessionCookie: sessionCookie
            ))
        } catch is URLError {
            return .error("Unable to connect to server", .networkError)
        } catch {
            if isolatedPushSession { return .error(String(localized: "error_session_setup"), .serverError) }
            return .error("Error: \(error.localizedDescription)", .unknown)
        }
    }

    // MARK: - CRUD Operations (CallKw pattern from OdooJsonRpcClient)

    /// Generic CallKw — calls any Odoo model method.
    /// Ported from OdooJsonRpcClient: Odoo.callKw()
    func callKw(
        serverUrl: String,
        model: String,
        method: String,
        args: [Any] = [],
        kwargs: [String: Any] = [:]
    ) async throws -> Any? {
        try await executeCallKw(serverUrl: serverUrl, model: model, method: method,
                                args: args, kwargs: kwargs, pushSessionId: nil)
    }

    /// Only the Apporo compound registrar uses this pinned, account-owned SID.
    func callKwWithPushSession(
        serverUrl: String, sessionId: String, method: String, kwargs: [String: Any] = [:]
    ) async throws -> Any? {
        guard URL(string: serverUrl)?.scheme == "https", Self.isValidPushSessionId(sessionId) else {
            throw OdooAPIError.invalidUrl
        }
        return try await executeCallKw(serverUrl: serverUrl, model: "woow.fcm.device", method: method,
                                       args: [], kwargs: kwargs, pushSessionId: sessionId)
    }

    private static func isValidPushSessionId(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            $0.value >= 0x21 && $0.value <= 0x7E && ![0x22, 0x2C, 0x3B, 0x5C].contains($0.value)
        }
    }

    private func executeCallKw(
        serverUrl: String, model: String, method: String, args: [Any], kwargs: [String: Any],
        pushSessionId: String?
    ) async throws -> Any? {
        let url = "\(serverUrl)/web/dataset/call_kw"
        let params = CallKwParams(model: model, method: method, args: args, kwargs: kwargs)
        let request = JsonRpcRequest(id: nextRequestId(authenticated: true), params: params)

        let (data, response) = try await post(url: url, body: request, pushSessionId: pushSessionId)

        // WI-3 self-heal detection: an expired Odoo session arrives on these `type='json'` routes as
        // HTTP 200 with a `SessionExpiredException` error envelope (not HTTP 401), so body inspection
        // — not a status-code check — is required. A genuine transport 401 is honoured too. Throwing a
        // dedicated `.sessionExpired` lets the healing layer re-auth once and retry (see
        // SessionReauthenticator); every other error stays a `serverError`.
        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        if SessionExpiry.isSessionExpired(httpCode: httpCode, body: data) {
            throw OdooAPIError.sessionExpired
        }

        if pushSessionId != nil && httpCode != 200 { throw OdooAPIError.invalidResponse }

        let decoded = try JSONDecoder().decode(
            JsonRpcResponse<AnyCodable>.self,
            from: data
        )

        if let error = decoded.error, let msg = error.data?.message ?? error.message, !msg.isEmpty {
            throw OdooAPIError.serverError(msg)
        }

        return decoded.result?.value
    }

    /// Search and read records.
    /// Ported from OdooJsonRpcClient: Odoo.searchRead()
    func searchRead(
        serverUrl: String,
        model: String,
        fields: [String],
        domain: [[Any]] = [],
        offset: Int = 0,
        limit: Int = 80,
        sort: String = ""
    ) async throws -> [[String: Any]] {
        let url = "\(serverUrl)/web/dataset/search_read"
        let params = SearchReadParams(
            model: model, fields: fields, domain: domain,
            offset: offset, limit: limit, sort: sort
        )
        let request = JsonRpcRequest(id: nextRequestId(authenticated: true), params: params)

        let (data, _) = try await post(url: url, body: request)

        // Parse response manually for flexible typing
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let records = result["records"] as? [[String: Any]] else {
            throw OdooAPIError.invalidResponse
        }

        return records
    }

    // MARK: - Cookie / Session Management
    // Ported from OdooJsonRpcClient: CookieJar pattern

    /// Extracts session_id cookie for a given server URL.
    /// Marked nonisolated — reads thread-safe HTTPCookieStorage, no actor hop needed. (H1)
    nonisolated func getSessionId(for serverUrl: String) -> String? {
        guard let url = URL(string: serverUrl),
              let cookies = HTTPCookieStorage.shared.cookies(for: url) else {
            return nil
        }
        return cookies.first(where: { $0.name == "session_id" })?.value
    }

    /// Clears all cookies for a server host.
    func clearCookies(for serverUrl: String) {
        guard let url = URL(string: serverUrl),
              let cookies = HTTPCookieStorage.shared.cookies(for: url) else {
            return
        }
        cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }

    /// Best-effort server-side logout of ONE account's session (demo111 2026-09-29, D1): before
    /// this, removing an account never revoked its Odoo session, which stayed valid until the
    /// server's idle GC.
    ///
    /// The request carries only `session_id=<sessionId>` in an explicit Cookie header with
    /// automatic cookie handling off, so it never reads or writes the shared cookie jar (a
    /// same-host sibling account's cookie is never sent or replaced) and follows no redirect.
    /// https only; a value that could inject a header is refused. Errors and timeouts are
    /// swallowed — local logout never depends on the server answering.
    func destroySession(serverUrl: String, sessionId: String) async {
        guard serverUrl.hasPrefix("https://"), Self.isValidPushSessionId(sessionId),
              let url = URL(string: Self.trimmedServerUrl(serverUrl) + "/web/session/destroy") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        request.setValue("session_id=\(sessionId)", forHTTPHeaderField: "Cookie")
        request.httpBody = try? JSONEncoder().encode(JsonRpcRequest(id: nextRequestId(), params: EmptyRpcParams()))
        do {
            _ = try await session.data(for: request, delegate: PushNoRedirectDelegate())
        } catch {
            logger.info("session destroy skipped: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// What the server says about one stored session (D5).
    enum PushSessionCheck: Equatable, Sendable {
        /// Accepted; the session belongs to `uid` on `db` (nil when the server omits it).
        case valid(uid: Int, db: String?)
        /// Rejected (expired / logged out / no user).
        case invalid
        /// No usable answer (transport error, non-200, unparsable) — unknown, not rejected.
        case unknown
    }

    /// Asks the server whether `sessionId` is still a live session (`/web/session/get_session_info`),
    /// sending ONLY that session in an explicit Cookie header, never touching the shared jar and not
    /// following redirects — the same isolation as `authenticatePushSession`. Lets an account switch
    /// reuse a still-valid session instead of logging in again (demo111 2026-09-29, D5).
    func pushSessionInfo(serverUrl: String, sessionId: String) async -> PushSessionCheck {
        guard serverUrl.hasPrefix("https://"), Self.isValidPushSessionId(sessionId) else { return .unknown }
        let url = "\(Self.trimmedServerUrl(serverUrl))/web/session/get_session_info"
        do {
            let (data, response) = try await post(url: url, body: JsonRpcRequest(id: nextRequestId(), params: EmptyRpcParams()),
                                                  pushSessionId: sessionId)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .unknown }
            let decoded = try JSONDecoder().decode(JsonRpcResponse<SessionInfoResult>.self, from: data)
            if decoded.error != nil { return .invalid }
            guard let uid = decoded.result?.uid, uid > 0 else { return .invalid }
            return .valid(uid: uid, db: decoded.result?.db)
        } catch {
            return .unknown
        }
    }

    private static func trimmedServerUrl(_ serverUrl: String) -> String {
        serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
    }

    // MARK: - Private Helpers

    private func post<T: Encodable>(url: String, body: T, pushSessionId: String? = nil) async throws -> (Data, URLResponse) {
        guard let requestUrl = URL(string: url) else {
            throw OdooAPIError.invalidUrl
        }

        var urlRequest = URLRequest(url: requestUrl)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        #if DEBUG
        logger.debug("POST \(url)")
        #endif

        if let pushSessionId {
            // Disable both automatic Cookie and Set-Cookie processing for this request.
            urlRequest.httpShouldHandleCookies = false
            if !pushSessionId.isEmpty {
                urlRequest.setValue("session_id=\(pushSessionId)", forHTTPHeaderField: "Cookie")
            }
            return try await session.data(for: urlRequest, delegate: PushNoRedirectDelegate())
        }
        return try await session.data(for: urlRequest)
    }

    /// Maps Odoo error messages to typed AuthResult errors.
    /// Ported from Android: OdooJsonRpcClient error handling
    ///
    /// Odoo 18 answers a wrong login/password with `odoo.exceptions.AccessDenied` and the message
    /// "Access Denied" — none of the words below — so it used to fall through to `.serverError` and
    /// the login screen showed "Server error: Access Denied" (demo111 2026-09-29, D2). It is the
    /// invalid-credentials case; the re-auth guardrail also depends on this to stop retrying a
    /// rejected stored password.
    static func mapOdooError(message: String, exceptionName: String?) -> AuthResult {
        let lower = message.lowercased()
        if exceptionName == "odoo.exceptions.AccessDenied"
            || lower.trimmingCharacters(in: .whitespacesAndNewlines) == "access denied" {
            return .error(message, .invalidCredentials)
        }
        if lower.contains("database") {
            return .error(message, .databaseNotFound)
        } else if lower.contains("login") || lower.contains("password") || lower.contains("credentials") {
            return .error(message, .invalidCredentials)
        } else {
            return .error(message, .serverError)
        }
    }
}

/// Errors thrown by OdooAPIClient.
enum OdooAPIError: Error, LocalizedError, Equatable {
    case invalidUrl
    case invalidResponse
    case httpsRequired
    case serverError(String)
    /// The Odoo session cookie has expired (HTTP-200 `SessionExpiredException` envelope or a genuine
    /// 401). Distinct so the WI-3 self-heal layer can re-authenticate once and retry the request.
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidUrl: return "Invalid server URL"
        case .invalidResponse: return "Invalid response from server"
        case .httpsRequired: return "HTTPS connection required"
        case .serverError(let msg): return msg
        case .sessionExpired: return "Session expired"
        }
    }
}

/// Never forward an account-bound push session or credentials to a redirect target.
private final class PushNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
