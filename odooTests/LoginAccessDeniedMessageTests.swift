//
//  LoginAccessDeniedMessageTests.swift
//  odooTests
//
//  demo111 live run 2026-09-29 (D2): a wrong password on Odoo 18 answers HTTP 200 with a JSON-RPC
//  error whose `data.name` is `odoo.exceptions.AccessDenied` and message "Access Denied". The
//  message has none of the words mapOdooError looked for, so it fell through to `.serverError`
//  and the login screen showed "Server error: Access Denied" / 「伺服器錯誤：Access Denied」.
//  It must map to the localized invalid-credentials message — and, for the push/re-auth path, to
//  `.invalidCredentials` so the re-auth guardrail stops instead of retrying a rejected password.
//

import XCTest
@testable import odoo

@MainActor
final class LoginAccessDeniedMessageTests: XCTestCase {

    /// Answers every request with an HTTP-200 JSON-RPC error envelope built from `body`.
    private final class JsonRpcErrorURLProtocol: URLProtocol {
        nonisolated(unsafe) static var body = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://localhost")!,
                                           statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private static func envelope(name: String?, message: String) -> Data {
        var data: [String: Any] = ["message": message, "arguments": [message], "debug": "Traceback …"]
        if let name { data["name"] = name }
        let json: [String: Any] = [
            "jsonrpc": "2.0", "id": 1,
            "error": ["code": 200, "message": "Odoo Server Error", "data": data],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private static let accessDenied = envelope(name: "odoo.exceptions.AccessDenied", message: "Access Denied")

    private func makeClient(body: Data) -> OdooAPIClient {
        JsonRpcErrorURLProtocol.body = body
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JsonRpcErrorURLProtocol.self]
        return OdooAPIClient(session: URLSession(configuration: config))
    }

    private func lproj(_ lang: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: LoginViewModel.self).path(forResource: lang, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func loginError(brand: AppBrand.Code, lang: String) async throws -> String? {
        let repository = AccountRepository(persistence: PersistenceController(inMemory: true),
                                           apiClient: makeClient(body: Self.accessDenied), brand: brand)
        let vm = LoginViewModel(addingAccount: true, repository: repository,
                                secureStorage: MockSecureStorage(),
                                localizationBundle: try lproj(lang))
        vm.serverUrl = "example.invalid"
        vm.database = "mydb"
        vm.goToNextStep()
        vm.username = "admin"
        vm.password = "fixture-password"
        vm.login(onSuccess: { XCTFail("Access Denied must not sign in") })
        for _ in 0..<500 where vm.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(vm.isLoading, "login did not finish")
        return vm.error
    }

    func test_login_givenAccessDenied_showsLocalizedInvalidCredentials() async throws {
        let expected: [(lang: String, text: String)] = [
            ("en", "Invalid username or password"),
            ("zh-Hant", "使用者名稱或密碼錯誤"),
            ("zh-Hans", "用户名或密码错误"),
        ]
        for brand in [AppBrand.Code.woowtech, .apporo] {
            for row in expected {
                let error = try await loginError(brand: brand, lang: row.lang)
                XCTAssertEqual(error, row.text, "\(brand) \(row.lang)")
                XCTAssertFalse((error ?? "").contains("Access Denied"), "raw server text leaked: \(brand) \(row.lang)")
            }
        }
    }

    func test_authenticate_givenAccessDenied_returnsInvalidCredentials() async {
        let result = await makeClient(body: Self.accessDenied)
            .authenticate(serverUrl: "https://example.invalid", database: "mydb",
                          username: "admin", password: "fixture-password")
        guard case .error(_, let type) = result else { return XCTFail("Expected error, got \(result)") }
        XCTAssertEqual(type, .invalidCredentials)
    }

    /// The re-auth guardrail relies on `.invalidCredentials` to stop; a `.serverError` here means a
    /// changed server password is retried as if it were a transient failure.
    func test_authenticatePushSession_givenAccessDenied_returnsInvalidCredentials() async {
        let result = await makeClient(body: Self.accessDenied)
            .authenticatePushSession(serverUrl: "https://example.invalid", database: "mydb",
                                     username: "admin", password: "fixture-password")
        guard case .error(_, let type) = result else { return XCTFail("Expected error, got \(result)") }
        XCTAssertEqual(type, .invalidCredentials)
    }

    /// Older servers / proxies may drop `data.name`; the bare Odoo message still identifies it.
    func test_authenticate_givenBareAccessDeniedMessage_returnsInvalidCredentials() async {
        let result = await makeClient(body: Self.envelope(name: nil, message: "Access Denied"))
            .authenticate(serverUrl: "https://example.invalid", database: "mydb",
                          username: "admin", password: "fixture-password")
        guard case .error(_, let type) = result else { return XCTFail("Expected error, got \(result)") }
        XCTAssertEqual(type, .invalidCredentials)
    }

    /// Regression guard: an unrelated server exception still surfaces as a server error.
    func test_authenticate_givenOtherServerException_staysServerError() async {
        let result = await makeClient(body: Self.envelope(name: "builtins.ValueError", message: "boom"))
            .authenticate(serverUrl: "https://example.invalid", database: "mydb",
                          username: "admin", password: "fixture-password")
        guard case .error(_, let type) = result else { return XCTFail("Expected error, got \(result)") }
        XCTAssertEqual(type, .serverError)
    }
}
