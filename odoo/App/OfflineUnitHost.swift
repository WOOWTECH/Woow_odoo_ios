#if UNIT_TEST_HOST && !DEBUG
#error("UNIT_TEST_HOST requires DEBUG and must never be used for Release")
#endif

#if DEBUG && UNIT_TEST_HOST
import Foundation

/// Rejects unstubbed Odoo HTTP transport in the compile-only unit host.
/// Explicitly installed on the default API session; global registration is only
/// defense-in-depth, not a sandbox for WebKit, background sessions or other SDKs.
final class OfflineUnitHostURLProtocol: URLProtocol {
    static let errorDomain = "OfflineUnitHost.NetworkDenied"

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // No forwarding session, DNS lookup or request metadata in the error.
        client?.urlProtocol(self, didFailWithError: NSError(
            domain: Self.errorDomain, code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unstubbed HTTP request denied by offline unit host"]
        ))
    }

    override func stopLoading() {}
}
#endif
