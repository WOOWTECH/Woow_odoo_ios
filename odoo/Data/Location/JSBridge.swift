#if DEBUG

import Foundation
import WebKit

// MARK: - JSBridgeMessageHandlerProxy

/// A WKScriptMessageHandler registered under the name "__woowTestEval" in DEBUG builds only.
///
/// Enables XCUITest suites to evaluate arbitrary JavaScript inside the WKWebView from the
/// test process, without requiring private WebKit APIs or UIKit introspection.
///
/// Protocol (matches E2E test helper in the QA agent's test plan):
/// - Incoming message body: `{ "id": "<uuid>", "code": "<js source>" }`
/// - The handler evaluates `code` in the webView context.
/// - Result is returned by calling the JS function `__woowTestBridgeResult(id, resultJSON)` in the page.
///
/// This class is intentionally compiled out of Release builds (`#if DEBUG`).
final class JSBridgeMessageHandlerProxy: NSObject, WKScriptMessageHandler {

    /// The webView to evaluate JavaScript in. Set by OdooWebView.makeUIView immediately after
    /// the webView is created (before any page loads).
    weak var webView: WKWebView?

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let requestId = body["id"] as? String,
              let code = body["code"] as? String,
              let webView = webView
        else { return }

        Task { @MainActor in
            webView.evaluateJavaScript(code) { result, error in
                let resultString: String
                if let error {
                    resultString = "{\"error\": \"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}"
                } else if let result {
                    if let data = try? JSONSerialization.data(withJSONObject: result),
                       let json = String(data: data, encoding: .utf8) {
                        resultString = json
                    } else {
                        resultString = "\"\(result)\""
                    }
                } else {
                    resultString = "null"
                }

                let callbackJS = "__woowTestBridgeResult('\(requestId)', \(resultString));"
                webView.evaluateJavaScript(callbackJS, completionHandler: nil)
            }
        }
    }
}

#endif
