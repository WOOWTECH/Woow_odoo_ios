//
//  SwitchAccountNoUnregisterTests.swift
//  odooTests
//
//  AC9: switching accounts must NOT trigger any `unregister_device` call.
//  Only `logout` (and `removeAccount`) unregister the device's FCM token; a plain
//  account SWITCH must never touch the push registration — otherwise switching would
//  silently stop notifications for the account being switched away from.
//
//  Strategy (mirrors OdooAPIClientAuthTests + MultiAccountLogoutTests):
//   - Drive the REAL AccountRepository against an in-memory Core Data store.
//   - Inject a URLProtocol-RECORDING OdooAPIClient(session:) that records every outgoing
//     request's URL path and the JSON-RPC `params.method` (the CallKw method, e.g.
//     "unregister_device"), then returns a canned success-shaped auth response.
//   - Store a local FCM token so that IF any unregister path fired, it would actually
//     emit a network request (unregisterFcmToken is a no-op when no token is stored).
//   - Store a password for the target account so switchAccount's session-validation
//     `authenticate` call executes (this is the path we want to prove does NOT unregister).
//   - Seed A (active) + B (inactive), await repo.switchAccount(id: B), then assert NO
//     recorded request had params.method == "unregister_device".
//

import XCTest
@testable import odoo

@MainActor
final class SwitchAccountNoUnregisterTests: XCTestCase {

    // MARK: - Recording URLProtocol

    /// A URLProtocol subclass that RECORDS each outgoing request (URL path + JSON-RPC
    /// `params.method`) and returns a canned success-shaped `/web/session/authenticate`
    /// response so that `switchAccount`'s session validation proceeds.
    ///
    /// Note on body capture: URLSession frequently moves a request's `httpBody` into
    /// `httpBodyStream` by the time URLProtocol sees it, so we read whichever is present.
    private final class RecordingURLProtocol: URLProtocol {

        /// Records every request's URL path (e.g. "/web/dataset/call_kw").
        static var recordedPaths: [String] = []
        /// Records the JSON-RPC `params.method` for CallKw requests (e.g. "unregister_device").
        /// Authenticate requests have no `params.method`, so they contribute nothing here.
        static var recordedMethods: [String] = []

        static func reset() {
            recordedPaths = []
            recordedMethods = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            RecordingURLProtocol.record(request: request)

            // Canned success-shaped authenticate response so switchAccount's validation passes.
            let json = """
            {
              "jsonrpc": "2.0",
              "id": "1",
              "result": {
                "uid": 7,
                "name": "Administrator",
                "username": "admin",
                "session_id": "sess-validated",
                "db": "demo888"
              }
            }
            """
            let data = json.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://demo888-odoo.woowtech.io")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// Extracts and records the URL path and JSON-RPC `params.method` from a request.
        private static func record(request: URLRequest) {
            if let path = request.url?.path {
                recordedPaths.append(path)
            }

            guard let body = bodyData(from: request),
                  let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let params = root["params"] as? [String: Any],
                  let method = params["method"] as? String else {
                return
            }
            recordedMethods.append(method)
        }

        /// Returns the request body from `httpBody`, falling back to draining
        /// `httpBodyStream` (URLSession may relocate the body into a stream).
        private static func bodyData(from request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
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

    private let serverB = "https://demo888-odoo.woowtech.io"
    private let usernameB = "admin"
    private let passwordB = "password-b"

    override func setUp() async throws {
        try await super.setUp()
        RecordingURLProtocol.reset()

        persistence = PersistenceController(inMemory: true)
        secureStorage = SecureStorage.shared

        // Recording OdooAPIClient over an ephemeral session — fully offline.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: config)
        let recordingApiClient = OdooAPIClient(session: session)

        repo = AccountRepository(
            persistence: persistence,
            secureStorage: secureStorage,
            apiClient: recordingApiClient
        )

        // A = demo777 (active), B = demo888 (inactive). Mirrors MultiAccountLogoutTests seeding.
        repo.replaceAccountsForTesting([
            SeededAccount(serverURL: "https://demo777-odoo.woowtech.io", database: "demo777",
                          username: "admin", sessionCookie: "sess-a", tenantId: "demo777", isActive: true),
            SeededAccount(serverURL: serverB, database: "demo888",
                          username: usernameB, sessionCookie: "sess-b", tenantId: "demo888", isActive: false),
        ])

        // Store a local FCM token so that — if any unregister path fired — it would actually
        // emit a network request. Without a stored token, unregisterFcmToken is a silent no-op,
        // which would make this test pass vacuously.
        secureStorage.saveFcmToken("fcm-token-for-ac9")

        // Store a password for B so switchAccount's session-validation authenticate call runs.
        // (replaceAccountsForTesting seeds only the session cookie, not a password.)
        secureStorage.savePassword(serverUrl: serverB, username: usernameB, password: passwordB)
    }

    override func tearDown() async throws {
        secureStorage.deleteFcmToken()
        secureStorage.deletePassword(serverUrl: serverB, username: usernameB)
        secureStorage.deleteSessionId(serverUrl: serverB, username: usernameB)
        repo = nil
        persistence = nil
        secureStorage = nil
        RecordingURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Tests

    /// AC9: switching accounts must NOT trigger an `unregister_device` call.
    /// switchAccount may hit `/web/session/authenticate` to validate the session — that's
    /// expected; the invariant is that it never emits the `unregister_device` CallKw.
    func test_switchAccount_doesNotTriggerUnregisterDevice() async throws {
        // Resolve B's id from the repository (ids are UUIDs assigned during seeding).
        let all = repo.getAllAccounts()
        guard let accountB = all.first(where: { $0.database == "demo888" }) else {
            throw XCTSkip("Seed for account B (demo888) not found — cannot exercise switchAccount")
        }
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo777", "precondition: A (demo777) active")

        let switched = await repo.switchAccount(id: accountB.id)

        // Whether or not the switch succeeds, the AC9 invariant must hold. We still surface the
        // outcome to make failures diagnosable.
        XCTAssertTrue(switched, "switchAccount should succeed with a valid stored password and success-shaped auth")
        XCTAssertEqual(repo.getActiveAccount()?.database, "demo888", "B must be active after a successful switch")

        // Core assertion (AC9): no recorded request carried the unregister_device method.
        XCTAssertFalse(
            RecordingURLProtocol.recordedMethods.contains("unregister_device"),
            "Switching accounts must NOT emit unregister_device — only logout may. Recorded methods: \(RecordingURLProtocol.recordedMethods)"
        )

        // Belt-and-suspenders: no request path should be a call_kw carrying unregister_device.
        // (The method assertion above already covers this; this documents intent.)
        XCTAssertFalse(
            RecordingURLProtocol.recordedMethods.contains(where: { $0.contains("unregister") }),
            "No unregister-family CallKw method may be emitted during a switch. Recorded methods: \(RecordingURLProtocol.recordedMethods)"
        )
    }
}
