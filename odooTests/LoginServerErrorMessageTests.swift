//
//  LoginServerErrorMessageTests.swift
//  odooTests
//
//  A non-200 sign-in response (e.g. Cloudflare 530) used to surface as
//  "Server error: Server error" / 「伺服器錯誤：Server error」: OdooAPIClient passed a
//  hardcoded English "Server error" that LoginViewModel wrapped in `error_server_%@`.
//  The message must name the HTTP status once, fully localized.
//

import XCTest
@testable import odoo

@MainActor
final class LoginServerErrorMessageTests: XCTestCase {

    /// Answers every request like a Cloudflare origin-unreachable page: HTTP 530, HTML body.
    private final class CloudflareOriginDownURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://localhost")!,
                                           statusCode: 530, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<html>error code: 1033</html>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient() -> OdooAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareOriginDownURLProtocol.self]
        return OdooAPIClient(session: URLSession(configuration: config))
    }

    /// The app bundle's `<lang>.lproj`, so one test process can render every language.
    private func lproj(_ lang: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle(for: LoginViewModel.self).path(forResource: lang, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    private func loginError(brand: AppBrand.Code, lang: String) async throws -> String? {
        let repository = AccountRepository(persistence: PersistenceController(inMemory: true),
                                           apiClient: makeClient(), brand: brand)
        let vm = LoginViewModel(addingAccount: true, repository: repository,
                                secureStorage: MockSecureStorage(),
                                localizationBundle: try lproj(lang))
        vm.serverUrl = "example.invalid"
        vm.database = "mydb"
        vm.goToNextStep()
        vm.username = "admin"
        vm.password = "fixture-password"
        vm.login(onSuccess: { XCTFail("530 must not sign in") })
        for _ in 0..<500 where vm.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(vm.isLoading, "login did not finish")
        return vm.error
    }

    func test_login_given530Response_showsLocalizedServerErrorWithStatusOnce() async throws {
        let expected: [(lang: String, text: String, phrase: String)] = [
            ("en", "Server error (HTTP 530)", "Server error"),
            ("zh-Hant", "伺服器錯誤（HTTP 530）", "伺服器錯誤"),
            ("zh-Hans", "服务器错误（HTTP 530）", "服务器错误"),
        ]
        for brand in [AppBrand.Code.woowtech, .apporo] {
            for row in expected {
                let error = try await loginError(brand: brand, lang: row.lang)
                let context = "\(brand) \(row.lang)"
                XCTAssertEqual(error, row.text, context)
                let shown = error ?? ""
                XCTAssertTrue(shown.contains("530"), "status code missing: \(context)")
                XCTAssertEqual(shown.components(separatedBy: row.phrase).count - 1, 1,
                               "server-error phrase must appear exactly once: \(context)")
                if row.lang != "en" {
                    XCTAssertFalse(shown.localizedCaseInsensitiveContains("server"),
                                   "English leaked into \(context): \(shown)")
                }
            }
        }
    }

    func test_authenticate_given530Response_returnsServerHTTPStatus() async {
        let result = await makeClient().authenticate(serverUrl: "https://example.invalid", database: "mydb",
                                                     username: "admin", password: "fixture-password")
        guard case .error(_, let type) = result else { return XCTFail("Expected error, got \(result)") }
        XCTAssertEqual(type, .serverHTTPStatus(530))
    }

    func test_authenticatePushSession_given530Response_returnsServerHTTPStatus() async {
        let result = await makeClient().authenticatePushSession(serverUrl: "https://example.invalid", database: "mydb",
                                                                username: "admin", password: "fixture-password")
        guard case .error(_, let type) = result else { return XCTFail("Expected error, got \(result)") }
        XCTAssertEqual(type, .serverHTTPStatus(530))
    }
}
