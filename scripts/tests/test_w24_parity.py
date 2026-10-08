"""W2-4 (Android Pixel 7a acceptance, 2026-10-08) parity contracts. No Xcode, devices or network.

Source-level wiring that XCTest cannot see from a unit host; the behaviour itself is covered by
odooTests (ServerUrlSchemePrefixTests).
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



if __name__ == "__main__":
    unittest.main()
