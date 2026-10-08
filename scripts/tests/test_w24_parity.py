"""W2-4 (Android Pixel 7a acceptance, 2026-10-08) parity contracts. No Xcode, devices or network.

Source-level wiring that XCTest cannot see from a unit host; the behaviour itself is covered by
odooTests (ServerUrlSchemePrefixTests, OfflineScreen*Tests, SettingsGapTests).
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def text(path):
    return (ROOT / path).read_text()


class LoginSchemePrefixTests(unittest.TestCase):
    """U4: the fixed `https://` label is hidden once the field holds its own scheme."""

    def test_fixed_prefix_is_gated_on_the_typed_text(self):
        view = text("odoo/UI/Login/LoginView.swift")
        gate = "if ServerUrlInput.showsFixedSchemePrefix(for: viewModel.serverUrl) {"
        self.assertIn(gate, view)
        block = view.split(gate, 1)[1].split("}", 1)[0]
        self.assertIn('Text("https://")', block)
        self.assertEqual(view.count('Text("https://")'), 1, "no ungated copy of the label")

    def test_validation_is_unchanged(self):
        source = text("odoo/UI/Login/ServerUrlInput.swift")
        classify = source.split("static func classify(", 1)[1].split("static func showsFixedSchemePrefix", 1)[0]
        self.assertNotIn("showsFixedSchemePrefix", classify)



class OfflineScreenWiringTests(unittest.TestCase):
    """L1: MainView shows the app's own offline screen, driven by the WebView coordinator."""

    def test_main_view_owns_state_passes_it_down_and_overlays_offline_view(self):
        view = text("odoo/UI/Main/MainView.swift")
        self.assertIn("@StateObject private var offlineState = WebViewOfflineState()", view)
        self.assertIn("offlineState: offlineState", view)
        self.assertIn("if offlineState.isShowingOfflineScreen {", view)
        self.assertIn("OfflineView(onRetry: { offlineState.retry() })", view)

    def test_coordinator_owns_retry_and_both_failure_delegates_feed_it(self):
        web = text("odoo/UI/Main/OdooWebView.swift")
        self.assertIn("offlineState: offlineState", web.split("func makeCoordinator()", 1)[1].split("}", 1)[0])
        self.assertIn("offlineState.retryAction = { [weak self] in self?.retryAfterLoadFailure() }", web)
        self.assertEqual(web.count("finishLoad(after: error, in: webView)"), 2)
        self.assertIn("networkRecovery.start { [weak self] in self?.retryAfterLoadFailure() }", web)
        # Ownership: a retry only ever loads the coordinator's current account WebView.
        retry = web.split("func retryAfterLoadFailure()", 1)[1].split("private func clearLoadFailure()", 1)[0]
        self.assertIn("guard let webView, let accountId = currentAccountId,", retry)
        self.assertIn("!retiredAccountIds.contains(accountId)", retry)
        self.assertIn("loadBaseRequest(webView, URLRequest(url: target))", retry)
        # Switch and retirement clear the outgoing account's failure.
        self.assertEqual(web.count("        clearLoadFailure()\n"), 4, "rebuild, retire, didCommit, retry")

    def test_offline_view_shows_no_address_or_error_text(self):
        view = "\n".join(line for line in text("odoo/UI/Main/OfflineView.swift").splitlines()
                         if not line.strip().startswith("//"))
        # Its only input is the retry closure: nothing to render an address or error from.
        self.assertIn("    let onRetry: () -> Void\n\n    var body", view)
        for forbidden in ("serverUrl", "URL", "localizedDescription", "error", "Error"):
            self.assertNotIn(forbidden, view)
        for key in ("offline_title", "offline_message", "offline_retry"):
            self.assertIn(f'String(localized: "{key}")', view)
            for lang in ("en", "zh-Hans", "zh-Hant"):
                strings = text(f"odoo/Resources/{lang}.lproj/Localizable.strings")
                self.assertEqual(strings.count(f'"{key}" = '), 1, f"{key} [{lang}]")


if __name__ == "__main__":
    unittest.main()
