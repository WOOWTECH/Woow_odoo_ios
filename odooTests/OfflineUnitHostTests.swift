#if DEBUG && UNIT_TEST_HOST
import XCTest
import UIKit
#if canImport(FirebaseCore)
import FirebaseCore
#endif
@testable import odoo

final class OfflineUnitHostTests: XCTestCase {
    @MainActor
    func test_didFinish_givenOfflineHost_returnsWithoutFirebaseOrAPNs() {
        #if canImport(FirebaseCore)
        XCTAssertNil(FirebaseApp.app(), "The host must not configure Firebase before XCTest starts")
        #else
        XCTFail("FirebaseCore must be available to verify bootstrap isolation")
        #endif
        XCTAssertFalse(UIApplication.shared.isRegisteredForRemoteNotifications)
        XCTAssertTrue(AppDelegate().application(UIApplication.shared, didFinishLaunchingWithOptions: nil))
        #if canImport(FirebaseCore)
        XCTAssertNil(FirebaseApp.app())
        #endif
        XCTAssertFalse(UIApplication.shared.isRegisteredForRemoteNotifications)
        XCTAssertFalse(TestHookGate.testHooksEnabled)
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-WoowTestRunner"))
    }

    func test_canInit_givenHTTPAndHTTPS_returnsTrue() throws {
        for scheme in ["http", "https", "HTTPS"] {
            let url = try XCTUnwrap(URL(string: "\(scheme)://offline-unit.invalid/probe"))
            XCTAssertTrue(OfflineUnitHostURLProtocol.canInit(with: URLRequest(url: url)))
        }
    }

    func test_canInit_givenNonHTTP_returnsFalse() throws {
        for raw in ["file:///offline-unit", "data:text/plain,fixture", "about:blank"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(OfflineUnitHostURLProtocol.canInit(with: URLRequest(url: url)))
        }
    }

    func test_defaultAPIClient_givenHTTP_throwsOfflineDenial() async {
        await assertDefaultClientDenied(scheme: "http")
    }

    func test_defaultAPIClient_givenHTTPS_throwsOfflineDenial() async {
        await assertDefaultClientDenied(scheme: "https")
    }

    private func assertDefaultClientDenied(scheme: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await OdooAPIClient().callKw(
                serverUrl: "\(scheme)://offline-unit.invalid", model: "fixture", method: "probe"
            )
            XCTFail("An unstubbed request must fail closed", file: file, line: line)
        } catch {
            // DNS/ATS/timeout failure is NOT evidence that our guard handled the request.
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "OfflineUnitHost.NetworkDenied", file: file, line: line)
            XCTAssertEqual(failure.code, 1, file: file, line: line)
        }
    }

    func test_injectedSession_givenMockAndGlobalGuard_returnsMockResult() async throws {
        XCTAssertTrue(URLProtocol.registerClass(OfflineUnitHostURLProtocol.self))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineHostMockURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = OdooAPIClient(session: session)
        let result = try await client.callKw(
            serverUrl: "https://offline-unit.invalid", model: "fixture", method: "probe"
        )
        XCTAssertEqual(result as? String, "offline-mock-reached")
    }
}

/// Deliberately accepts every request and never forwards to another transport.
private final class OfflineHostMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"result":"offline-mock-reached"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
