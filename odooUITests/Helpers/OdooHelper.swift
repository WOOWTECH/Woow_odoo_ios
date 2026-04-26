import Foundation

/// JSON-RPC 2.0 client that runs inside the XCUITest process to authenticate with Odoo and
/// query hr.attendance records. Reads the server URL and database from `SharedTestConfig`
/// (single source of truth — `TestConfig.plist`, with env-var override for CI).
///
/// All methods are `async throws` and use `URLSession.shared.data(for:)` (Swift Concurrency).
/// No Combine or completion-handler patterns are used.
enum OdooHelper {

    // MARK: - Configuration

    /// Base URL of the Odoo server under test.
    ///
    /// `SharedTestConfig.serverURL` returns a host (e.g. "example.trycloudflare.com");
    /// we prepend `https://` to match the convention used elsewhere in the test suite
    /// (see `odooUITests.swift:849` and `E2E_MediumPriority_Tests.swift:553`).
    static let tunnelURL: String = "https://\(SharedTestConfig.serverURL)"

    /// Odoo database name. Sourced from `SharedTestConfig` (TestConfig.plist).
    static let db: String = SharedTestConfig.database

    static let user = SharedTestConfig.adminUser
    static let password = SharedTestConfig.adminPass

    // MARK: - Attendance model

    /// Mirrors the relevant columns of hr.attendance used in GPS verification.
    ///
    /// Odoo returns `false` (a JSON boolean) for empty Many2one and Date fields rather than
    /// `null`. `check_in` and `check_out` are stored as strings when set, but Odoo sends
    /// `false` when they are not set. The custom decoder handles both cases.
    struct Attendance: Decodable {
        let id: Int
        let in_latitude: Double
        let in_longitude: Double
        let out_latitude: Double
        let out_longitude: Double
        let check_in: String?
        let check_out: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            in_latitude = try c.decodeIfPresent(Double.self, forKey: .in_latitude) ?? 0
            in_longitude = try c.decodeIfPresent(Double.self, forKey: .in_longitude) ?? 0
            out_latitude = try c.decodeIfPresent(Double.self, forKey: .out_latitude) ?? 0
            out_longitude = try c.decodeIfPresent(Double.self, forKey: .out_longitude) ?? 0
            // Odoo sends `false` instead of `null` for unset date fields.
            check_in = Self.decodeFalseAsNil(container: c, key: .check_in)
            check_out = Self.decodeFalseAsNil(container: c, key: .check_out)
        }

        private enum CodingKeys: String, CodingKey {
            case id, in_latitude, in_longitude, out_latitude, out_longitude, check_in, check_out
        }

        /// Decodes a string field that Odoo may send as `false` (boolean) when unset.
        private static func decodeFalseAsNil(
            container: KeyedDecodingContainer<CodingKeys>,
            key: CodingKeys
        ) -> String? {
            // Try string first (the normal case when a value is present).
            if let str = try? container.decodeIfPresent(String.self, forKey: key) {
                return str
            }
            // Odoo sends `false` for unset date fields — treat as nil.
            if (try? container.decodeIfPresent(Bool.self, forKey: key)) != nil {
                return nil
            }
            return nil
        }
    }

    // MARK: - Private helpers

    /// Builds a JSON-RPC 2.0 request body dictionary ready for serialisation.
    private static func rpcBody(method: String, params: [String: Any]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "method": method,
            "id": Int.random(in: 1 ... 999_999),
            "params": params,
        ]
    }

    /// Performs a single JSON-RPC POST and returns the decoded result value.
    ///
    /// - Parameters:
    ///   - path: The URL path suffix, e.g. "/web/dataset/call_kw".
    ///   - body: The full JSON-RPC body dictionary.
    ///   - cookie: Optional session cookie header value ("session_id=…").
    ///   - returning: The `Decodable` type to decode from `result`.
    /// - Throws: `URLError`, `DecodingError`, or `OdooRPCError` on Odoo-level errors.
    private static func post<T: Decodable>(
        path: String,
        body: [String: Any],
        cookie: String? = nil,
        returning type: T.Type
    ) async throws -> T {
        guard let url = URL(string: "\(tunnelURL)\(path)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        // Decode the envelope first to surface Odoo-level errors before diving into `result`.
        let envelope = try JSONDecoder().decode(RPCEnvelope<T>.self, from: data)
        if let error = envelope.error {
            throw OdooRPCError(message: error.data?.message ?? error.message)
        }
        guard let result = envelope.result else {
            throw OdooRPCError(message: "JSON-RPC response missing 'result' field")
        }
        return result
    }

    // MARK: - Public API

    /// Authenticates with Odoo via JSON-RPC `/web/session/authenticate` and returns
    /// the session cookie string and the Odoo uid for the authenticated user.
    ///
    /// The returned cookie is in `"session_id=<value>"` format, ready to pass as an
    /// HTTP Cookie header to subsequent calls.
    static func authenticate() async throws -> (cookie: String, uid: Int) {
        let params: [String: Any] = [
            "db": db,
            "login": user,
            "password": password,
        ]
        let body = rpcBody(method: "call", params: params)

        guard let url = URL(string: "\(tunnelURL)/web/session/authenticate") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Extract the session_id cookie from the Set-Cookie header.
        var sessionCookie = ""
        if let httpResponse = response as? HTTPURLResponse {
            let headers = httpResponse.allHeaderFields
            // Prefer the raw Set-Cookie header; fall back to HTTPCookieStorage.
            if let setCookie = headers["Set-Cookie"] as? String {
                // Header may be "session_id=abc; Path=/"
                for part in setCookie.components(separatedBy: ";") {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("session_id=") {
                        sessionCookie = trimmed
                        break
                    }
                }
            }
        }

        // Also read the uid from the JSON body.
        let envelope = try JSONDecoder().decode(RPCEnvelope<AuthResult>.self, from: data)
        guard let authResult = envelope.result, authResult.uid > 0 else {
            throw OdooRPCError(message: "Authentication failed — uid is 0 or missing")
        }

        if sessionCookie.isEmpty {
            // Build the cookie from the JSON result as a fallback (Cloudflare tunnels
            // sometimes strip Set-Cookie; Odoo also returns session_id in the JSON body).
            if let sid = authResult.session_id, !sid.isEmpty {
                sessionCookie = "session_id=\(sid)"
            } else {
                throw OdooRPCError(message: "Could not extract session_id from auth response")
            }
        }

        return (cookie: sessionCookie, uid: authResult.uid)
    }

    /// Resolves the `hr.employee` id that corresponds to the given Odoo user id.
    ///
    /// Odoo's `hr.employee` model stores `user_id` as a many2one field pointing to `res.users`.
    /// This method searches for the first employee whose `user_id` matches `userId`.
    static func employeeID(forUserId userId: Int, cookie: String) async throws -> Int {
        let params: [String: Any] = [
            "model": "hr.employee",
            "method": "search_read",
            "args": [[["user_id", "=", userId]]],
            "kwargs": [
                "fields": ["id", "name"],
                "limit": 1,
            ],
        ]
        let body = rpcBody(method: "call", params: params)
        let results = try await post(
            path: "/web/dataset/call_kw",
            body: body,
            cookie: cookie,
            returning: [EmployeeRecord].self
        )
        guard let first = results.first else {
            throw OdooRPCError(message: "No hr.employee found for user_id=\(userId)")
        }
        return first.id
    }

    /// Retrieves the most recent hr.attendance record for the given employee.
    ///
    /// Returns `nil` when no attendance record exists yet (fresh install / first clock-in).
    static func latestAttendance(forEmployeeID empId: Int, cookie: String) async throws -> Attendance? {
        let domain: [[Any]] = [["employee_id", "=", empId]]
        let params: [String: Any] = [
            "model": "hr.attendance",
            "method": "search_read",
            "args": [domain],
            "kwargs": [
                "fields": ["id", "check_in", "check_out",
                           "in_latitude", "in_longitude",
                           "out_latitude", "out_longitude"],
                "limit": 1,
                "order": "id desc",
            ],
        ]
        let body = rpcBody(method: "call", params: params)
        let results = try await post(
            path: "/web/dataset/call_kw",
            body: body,
            cookie: cookie,
            returning: [Attendance].self
        )
        return results.first
    }

    /// Forces the employee into the checked-out state by writing a `check_out` timestamp
    /// on any open attendance record. If the employee is already checked out this is a no-op.
    ///
    /// This normalises server state before `test_clockOutThenIn_populatesBothGPSColumns`
    /// so the first UI action will always be a clock-in, regardless of prior test runs.
    static func ensureCheckedOut(forEmployeeID empId: Int, cookie: String) async throws {
        // Find any open attendance (check_out is False in Odoo).
        let domain: [[Any]] = [
            ["employee_id", "=", empId],
            ["check_out", "=", false],
        ]
        let searchParams: [String: Any] = [
            "model": "hr.attendance",
            "method": "search_read",
            "args": [domain],
            "kwargs": [
                "fields": ["id"],
                "limit": 1,
            ],
        ]
        let searchBody = rpcBody(method: "call", params: searchParams)
        let open = try await post(
            path: "/web/dataset/call_kw",
            body: searchBody,
            cookie: cookie,
            returning: [IdRecord].self
        )
        guard let record = open.first else {
            // Already checked out — nothing to do.
            return
        }

        // Write check_out = now so the record is closed.
        // Odoo 18 expects datetime strings in the format "YYYY-MM-DD HH:MM:SS" (UTC),
        // not ISO8601 with T/Z separators (which it rejects with a format error).
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let now = formatter.string(from: Date())
        let writeParams: [String: Any] = [
            "model": "hr.attendance",
            "method": "write",
            "args": [[record.id], ["check_out": now]],
            "kwargs": [:],
        ]
        let writeBody = rpcBody(method: "call", params: writeParams)
        _ = try await post(
            path: "/web/dataset/call_kw",
            body: writeBody,
            cookie: cookie,
            returning: Bool.self
        )
    }
}

// MARK: - Private decoding helpers

private struct RPCEnvelope<T: Decodable>: Decodable {
    let result: T?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let message: String
    let data: RPCErrorData?
}

private struct RPCErrorData: Decodable {
    let message: String?
}

private struct AuthResult: Decodable {
    let uid: Int
    let session_id: String?
}

private struct EmployeeRecord: Decodable {
    let id: Int
    let name: String
}

private struct IdRecord: Decodable {
    let id: Int
}

// MARK: - Error type

/// Represents a JSON-RPC error returned by the Odoo server.
struct OdooRPCError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { "Odoo RPC error: \(message)" }
}
