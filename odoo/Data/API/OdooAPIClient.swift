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
        // HTTPS enforcement (ported from Android)
        guard serverUrl.hasPrefix("https://") else {
            return .error("HTTPS required", .httpsRequired)
        }

        let url = "\(serverUrl)/web/session/authenticate"
        let params = AuthenticateParams(db: database, login: username, password: password)
        let request = JsonRpcRequest(id: nextRequestId(), params: params)

        do {
            let (data, response) = try await post(url: url, body: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return .error("Server error", .serverError)
            }

            let decoded = try JSONDecoder().decode(
                JsonRpcResponse<AuthenticateResult>.self,
                from: data
            )

            if let error = decoded.error, let msg = error.data?.message ?? error.message {
                return mapOdooError(message: msg)
            }

            guard let result = decoded.result,
                  let uid = result.uid, uid > 0 else {
                return .error("Invalid credentials", .invalidCredentials)
            }

            let sessionId = getSessionId(for: serverUrl) ?? ""
            let name = result.name ?? username

            return .success(AuthResult.AuthSuccess(
                userId: uid,
                sessionId: sessionId,
                username: username,
                displayName: name
            ))
        } catch is URLError {
            return .error("Unable to connect to server", .networkError)
        } catch {
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
        let url = "\(serverUrl)/web/dataset/call_kw"
        let params = CallKwParams(model: model, method: method, args: args, kwargs: kwargs)
        let request = JsonRpcRequest(id: nextRequestId(authenticated: true), params: params)

        let (data, _) = try await post(url: url, body: request)
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
    func getSessionId(for serverUrl: String) -> String? {
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

    // MARK: - Private Helpers

    private func post<T: Encodable>(url: String, body: T) async throws -> (Data, URLResponse) {
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

        return try await session.data(for: urlRequest)
    }

    /// Maps Odoo error messages to typed AuthResult errors.
    /// Ported from Android: OdooJsonRpcClient error handling
    private func mapOdooError(message: String) -> AuthResult {
        let lower = message.lowercased()
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
enum OdooAPIError: Error, LocalizedError {
    case invalidUrl
    case invalidResponse
    case httpsRequired
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidUrl: return "Invalid server URL"
        case .invalidResponse: return "Invalid response from server"
        case .httpsRequired: return "HTTPS connection required"
        case .serverError(let msg): return msg
        }
    }
}
