"""Regression checks for review iV07b/iV36, scheme metadata, asset provenance.

Never imports verify_all (its main performs device operations).
"""
import ast
import copy
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from brand_verification import (IDENTITIES, load_brand_settings, selected_firebase_path,
                                verify_provider_color, verify_firebase_identity)
import test_brand_layer
from test_brand_layer import plist, text


class BrandVerificationTests(unittest.TestCase):
    def settings(self, configuration):
        settings = load_brand_settings(ROOT, configuration)
        if configuration.startswith("Apporo"):
            # Synthetic test identity, never persisted as a real client config.
            settings["FIREBASE_EXPECTED_PROJECT_ID"] = "mock-apporo-odoo"
        return settings

    def identity(self, settings):
        return {"BUNDLE_ID": settings["PRODUCT_BUNDLE_IDENTIFIER"],
                "PROJECT_ID": settings["FIREBASE_EXPECTED_PROJECT_ID"],
                "GOOGLE_APP_ID": "1:123:ios:abc", "GCM_SENDER_ID": "123"}

    def test_provider_colors_match_each_selected_configuration(self):
        for configuration in IDENTITIES:
            with self.subTest(configuration=configuration):
                self.assertTrue(verify_provider_color(configuration, self.settings(configuration),
                    text("odoo/App/AppBrand.swift"), text("odoo/UI/Theme/WoowColors.swift")))

    def test_provider_rejects_wrong_color_missing_wiring_or_mixed_configuration(self):
        settings = self.settings("ApporoDebug")
        provider = text("odoo/App/AppBrand.swift")
        theme = text("odoo/UI/Theme/WoowColors.swift")
        for source, wiring, config in [
            (provider.replace("#8B6B24", "#6183FC"), theme, settings),
            (provider, "// AppBrand.current.primaryColorHex", settings),
            ("// " + provider.replace("\n", "\n// "), theme, settings),
            (provider, theme, self.settings("Debug")),
        ]:
            self.assertFalse(verify_provider_color("ApporoDebug", config, source, wiring))

    def test_firebase_accepts_matching_nonsecret_identity_for_all_configurations(self):
        for configuration in IDENTITIES:
            with self.subTest(configuration=configuration):
                settings = self.settings(configuration)
                self.assertTrue(verify_firebase_identity(configuration, settings, ROOT,
                    selected_firebase_path(ROOT, settings), self.identity(settings)))

    def test_firebase_rejects_woow_source_even_with_apporo_fields(self):
        settings = self.settings("ApporoDebug")
        woow_path = ROOT / "odoo/GoogleService-Info.plist"
        self.assertFalse(verify_firebase_identity("ApporoDebug", settings, ROOT, woow_path, self.identity(settings)))
        settings["FIREBASE_CONFIG_PATH"] = str(woow_path)
        self.assertFalse(verify_firebase_identity("ApporoDebug", settings, ROOT, woow_path, self.identity(settings)))

    def test_firebase_rejects_wrong_brand_project_bundle_sender_or_missing_fields(self):
        settings = self.settings("ApporoDebug")
        path = selected_firebase_path(ROOT, settings)
        identity = self.identity(settings)
        for key in identity:
            with self.subTest(missing=key):
                missing = copy.copy(identity)
                del missing[key]
                self.assertFalse(verify_firebase_identity("ApporoDebug", settings, ROOT, path, missing))
        for key, value in [("BUNDLE_ID", "io.woowtech.odoo"), ("BUNDLE_ID", "com.apporo.odoo"),
                           ("PROJECT_ID", "woow-odoo-de2cb"), ("GCM_SENDER_ID", "456"),
                           ("GOOGLE_APP_ID", "1:123:android:abc")]:
            with self.subTest(key=key, value=value):
                self.assertFalse(verify_firebase_identity("ApporoDebug", settings, ROOT, path, dict(identity, **{key: value})))
        for project in ["woow-odoo-de2cb", "apporo-aiot-app"]:
            wrong = dict(settings, FIREBASE_EXPECTED_PROJECT_ID=project)
            self.assertFalse(verify_firebase_identity("ApporoDebug", wrong, ROOT, path, self.identity(wrong)))

    def test_firebase_missing_config_or_verified_project_never_passes(self):
        for configuration in ["ApporoDebug", "ApporoRelease"]:
            settings = load_brand_settings(ROOT, configuration)
            self.assertFalse(verify_firebase_identity(configuration, settings, ROOT,
                selected_firebase_path(ROOT, settings), None))
            settings["FIREBASE_EXPECTED_PROJECT_ID"] = ""
            self.assertFalse(verify_firebase_identity(configuration, settings, ROOT,
                selected_firebase_path(ROOT, settings), self.identity(settings)))
        self.assertFalse(verify_firebase_identity("Unknown", {}, ROOT, ROOT, {}))

    def test_settings_include_verified_local_override_without_fallback(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "Config").mkdir()
            (root / "Config/ApporoDebug.xcconfig").write_text(text("Config/ApporoDebug.xcconfig"))
            (root / "Config/Shared.xcconfig").write_text("MARKETING_VERSION = 1.0\n")
            self.assertEqual(load_brand_settings(root, "ApporoDebug")["FIREBASE_EXPECTED_PROJECT_ID"], "")
            (root / "Config/ApporoFirebase.local.xcconfig").write_text("FIREBASE_EXPECTED_PROJECT_ID = mock-apporo-odoo\n")
            self.assertEqual(load_brand_settings(root, "ApporoDebug")["FIREBASE_EXPECTED_PROJECT_ID"], "mock-apporo-odoo")
            with self.assertRaises(KeyError):
                load_brand_settings(root, "Unknown")

    def test_live_verifier_wires_helpers_without_legacy_assertions(self):
        tree = ast.parse(text("scripts/verify_all.py"))
        checks = {call.args[0].value: call for call in ast.walk(tree)
                  if isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == "check"
                  and call.args and isinstance(call.args[0], ast.Constant)}
        for vid, helper in [("iV07b-M1", "verify_provider_color"), ("iV36-M6", "verify_firebase_identity")]:
            expression = ast.unparse(checks[vid].args[2])
            self.assertIn(helper + "(TARGET.configuration, brand_settings", expression)
        self.assertIn("load_brand_settings(brand_root, TARGET.configuration)", text("scripts/verify_all.py"))
        self.assertNotIn('"API_KEY"', text("scripts/verify_all.py"))

    def test_ui_test_scheme_metadata_matches_app_configuration(self):
        objects = plist("odoo.xcodeproj/project.pbxproj")["objects"]
        configs = [v for v in objects.values() if v.get("isa") == "XCBuildConfiguration"
                   and v["buildSettings"].get("TEST_TARGET_NAME") == "odoo"]
        self.assertEqual(len(configs), 4)
        for config in configs:
            settings = config["buildSettings"]
            self.assertEqual(settings["INFOPLIST_KEY_TestAppURLScheme"], IDENTITIES[config["name"]][3])
            self.assertEqual(settings["INFOPLIST_KEY_TestAppBundleID"], IDENTITIES[config["name"]][2])
        shared = text("odooUITests/SharedTestConfig.swift")
        self.assertIn('object(forInfoDictionaryKey: "TestAppURLScheme")', shared)
        self.assertIn('switch (appBundleID, scheme)', shared)
        self.assertIn('fatalError("Inconsistent test target URL scheme configuration")', shared)

    def test_six_validator_entries_use_selected_scheme_and_unit_rejects_other_brand(self):
        for priority, expected in [("High", 2), ("Medium", 4)]:
            source = text(f"odooUITests/E2E_{priority}Priority_Tests.swift")
            self.assertEqual(source.count('URL(string: "\\(SharedTestConfig.appURLScheme)://'), expected)
            self.assertNotIn('URL(string: "woowodoo:', source)
            self.assertNotIn('URL(string: "apporoodoo', source)
        unit = text("odooTests/AppBrandTests.swift")
        for receiver, scheme in [("prod", "woowodoo"), ("dev", "woowodoo"),
                                 ("woow", "apporoodoo"), ("woow", "apporoodoo-dev")]:
            self.assertIn(f'XCTAssertFalse({receiver}.acceptsScheme("{scheme}"))', unit)
        self.assertNotIn("XCUIApplication", unit)

    def test_missing_provenance_skips_only_source_and_wrong_source_fails(self):
        case = test_brand_layer.BrandLayerTests()
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(unittest.SkipTest):
                case.test_asset_source_provenance_when_explicitly_supplied()
            # Repo-contained integrity must still execute without the original.
            case.test_assets_are_hashed_opaque_white_mark()
        with tempfile.TemporaryDirectory() as folder:
            wrong = Path(folder) / "wrong.png"
            wrong.write_bytes(b"not-the-original")
            with patch.dict(os.environ, {"APPORO_ASSET_SOURCE": str(wrong)}):
                with self.assertRaises(AssertionError):
                    case.test_asset_source_provenance_when_explicitly_supplied()


if __name__ == "__main__":
    unittest.main()
