//
//  LoginUnexpectedResponseMessageTests.swift
//  odooTests
//
//  F2 (0930): a sign-in answered with HTTP 200 but a body that is not JSON-RPC (a captive portal,
//  a Cloudflare interstitial, a web page at the wrong address) surfaced the decoder's raw English
//  text — "Error: The data couldn’t be read because it isn’t in the correct format." — in every
//  language. It must be one localized message telling the user to check the server address.
//

import XCTest
@testable import odoo

@MainActor
final class LoginUnexpectedResponseMessageTests: XCTestCase {

    /// Answers every request with HTTP 200 and an HTML page (not JSON-RPC).
    private final class HTMLPageURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://localhost")!,
                                           statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<html><body>Welcome to the hotel Wi-Fi</body></html>".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient() -> OdooAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTMLPageURLProtocol.self]
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
        vm.login(onSuccess: { XCTFail("an HTML page must not sign in") })
        for _ in 0..<500 where vm.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(vm.isLoading, "login did not finish")
        return vm.error
    }

    func test_login_givenNonJSON200_showsLocalizedUnexpectedResponse() async throws {
        let expected: [(lang: String, text: String)] = [
            ("en", "The server sent an unexpected response. Check the server address and try again."),
            ("zh-Hant", "伺服器回應的內容無法辨識，請確認伺服器網址後再試一次。"),
            ("zh-Hans", "服务器返回的内容无法识别，请确认服务器网址后再试一次。"),
        ]
        for brand in [AppBrand.Code.woowtech, .apporo] {
            for row in expected {
                let error = try await loginError(brand: brand, lang: row.lang)
                XCTAssertEqual(error, row.text, "\(brand) \(row.lang)")
                XCTAssertFalse((error ?? "").contains("Error:"), "raw decoder text leaked: \(brand) \(row.lang)")
            }
        }
    }

    func test_authenticate_givenNonJSON200_returnsUnexpectedResponse() async {
        let result = await makeClient().authenticate(serverUrl: "https://example.invalid", database: "mydb",
                                                     username: "admin", password: "fixture-password")
        guard case .error(_, let type) = result else { return XCTFail("Expected error, got \(result)") }
        XCTAssertEqual(type, .unexpectedResponse)
    }
}
