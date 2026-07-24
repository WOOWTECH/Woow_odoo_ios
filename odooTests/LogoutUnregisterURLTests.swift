//
//  LogoutUnregisterURLTests.swift
//  odooTests
//
//  Story: Fix "logged-out tenant keeps pushing" (Bug B). Regression guard against the
//  "https://https://…" double-prefix bug in AccountRepository.unregisterFcmToken.
//
//  The previous implementation built the unregister URL as `"https://\(serverUrl)"`, but
//  `serverUrl` is already stored https-prefixed, producing a malformed `https://https://…`
//  URL that made every unregister throw and get swallowed — leaving the logged-out tenant's
//  device row active on the server. The fix uses `serverUrl.ensureHTTPS` (idempotent).
//
//  This test proves the fix deterministically and OFFLINE by injecting a URLProtocol-recording
//  OdooAPIClient(session:) into the REAL AccountRepository + an in-memory Core Data store, seeding
//  a local FCM token (so unregister does NOT early-return), logging out the active account, and
//  asserting the RECORDED outgoing request URL is the single-https call_kw endpoint and its JSON
//  body's params.method == "unregister_device".
//

import XCTest
@testable import odoo

@MainActor
final class LogoutUnregisterURLTests: XCTestCase {

    // MARK: - Recording URLProtocol

    /// A URLProtocol subclass that RECORDS the outgoing request (URL + body) and returns a canned
    /// JSON-RPC success response so `callKw` completes without a real network call.
    ///
    /// Because `URLSession` strips `httpBody` from the `URLRequest` handed to a protocol (it moves
    /// it to a stream), we capture the body from `URLProtocol.property(forKey:in:)` is not reliable
    /// either — instead we read `request.httpBody` first and fall back to draining
    /// `request.httpBodyStream`, which is how ephemeral sessions deliver POST bodies to a protocol.
    private final class RecordingURLProtocol: URLProtocol {
        struct Recorded {
            let url: URL?
            let body: Data?
        }

        // Static capture — only one request is expected per test (a single logout unregister call).
        static var recorded: Recorded?

        static func reset() { recorded = nil }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            RecordingURLProtocol.recorded = Recorded(
                url: request.url,
                body: RecordingURLProtocol.extractBody(from: request)
            )

            // Canned JSON-RPC success — `callKw` only needs a decodable envelope with no error.
            let json = #"{"jsonrpc":"2.0","id":"r1","result":true}"#
            let data = Data(json.utf8)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://localhost")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// Reads the POST body either directly (`httpBody`) or by draining `httpBodyStream`.
        private static func extractBody(from request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data.isEmpty ? nil : data
        }
    }

    // MARK: - Fixtures

    private var persistence: PersistenceController!
    private var secureStorage: SecureStorage!
    private var repo: AccountRepository!

    override func setUp() async throws {
        try await super.setUp()
        RecordingURLProtocol.reset()

        persistence = PersistenceController(inMemory: true)
        secureStorage = SecureStorage.shared

        // URLProtocol-recording session injected into the real OdooAPIClient(session:).
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: config)
        let apiClient = OdooAPIClient(session: session)

        repo = AccountRepository(
            persistence: persistence,
            secureStorage: secureStorage,
            apiClient: apiClient
        )

        // Seed a LOCAL FCM token so `unregisterFcmToken` does NOT early-return — this is what makes
        // the unregister call actually fire (its guard is `getFcmToken() != nil`).
        secureStorage.saveFcmToken("test-fcm-token-abc123")

        // A = demo777 (inactive), B = demo888 (active) — logout(accountId: nil) targets active B.
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: "https://demo777-odoo.woowtech.io", database: "demo777",
                          username: "admin", sessionCookie: "sess-a", tenantId: "demo777", isActive: false),
            SeededAccount(serverURL: "https://demo888-odoo.woowtech.io", database: "demo888",
                          username: "admin", sessionCookie: "sess-b", tenantId: "demo888", isActive: true),
        ])
    }

    override func tearDown() async throws {
        secureStorage.deleteFcmToken()
        RecordingURLProtocol.reset()
        repo = nil
        secureStorage = nil
        persistence = nil
        try await super.tearDown()
    }

    // MARK: - Test

    /// Bug B regression guard: logging out the active account (B) must fire an `unregister_device`
    /// call to the CORRECT single-https URL — never the malformed `https://https://…` double prefix.
    func test_logoutActiveAccount_firesUnregisterToSingleHttpsUrl() async throws {
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo888", "precondition: B active")

        await repo.logout(accountId: nil) // logs out the active account (B)

        // The unregister call must have been recorded (proves it was NOT swallowed by a bad URL).
        let recorded = try XCTUnwrap(
            RecordingURLProtocol.recorded,
            "logout of the active account with a stored FCM token must fire an unregister request"
        )

        // 1. Exactly ONE https:// — the correct call_kw endpoint for account B's server.
        let recordedUrlString = try XCTUnwrap(recorded.url?.absoluteString, "recorded request must have a URL")
        XCTAssertEqual(
            recordedUrlString,
            "https://demo888-odoo.woowtech.io/web/dataset/call_kw",
            "unregister must hit the single-https call_kw endpoint for the logged-out account"
        )

        // 2. Explicit double-prefix regression assertion.
        XCTAssertFalse(
            recordedUrlString.contains("https://https://"),
            "URL must NOT contain a double https:// prefix (the Bug B malformed-URL regression)"
        )

        // 3. The JSON-RPC body's params.method must be "unregister_device".
        let body = try XCTUnwrap(recorded.body, "recorded request must have a JSON body")
        let jsonObject = try JSONSerialization.jsonObject(with: body)
        let root = try XCTUnwrap(jsonObject as? [String: Any], "body must be a JSON object")
        let params = try XCTUnwrap(root["params"] as? [String: Any], "body must carry a params object")
        XCTAssertEqual(
            params["method"] as? String,
            "unregister_device",
            "the unregister call must invoke the unregister_device model method"
        )
        XCTAssertEqual(
            params["model"] as? String,
            "woow.fcm.device",
            "the unregister call must target the woow.fcm.device model"
        )
    }
}
