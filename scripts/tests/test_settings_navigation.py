"""LIVE-0927-2: Settings shows exactly one back control. No Xcode, devices or network.

Settings is only ever reached by a push inside ConfigView's NavigationStack
(`.navigationDestination`), so the system back button is already there. A second,
hand-made leading chevron produced two back buttons (live run 2026-09-27, 24 / 47).
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SETTINGS = "odoo/UI/Settings/SettingsView.swift"


def text(path):
    return (ROOT / path).read_text()


def entry_points():
    """Every `SettingsView(` construction in app sources, excluding previews."""
    sites = []
    for path in sorted((ROOT / "odoo").rglob("*.swift")):
        source = path.read_text()
        body = source.split("#Preview", 1)[0]
        for match in re.finditer(r"\bSettingsView\(", body):
            sites.append((path.relative_to(ROOT), body, match.start()))
    return sites


class SettingsNavigationTests(unittest.TestCase):
    def test_settings_has_no_custom_back_button(self):
        source = text(SETTINGS)
        # Hiding the system button would bring back the need for a custom one.
        for marker in ("onBackClick", "chevron.left", "navigationBarBackButtonHidden"):
            self.assertFalse(marker in source, f"{SETTINGS} still has a custom back control: {marker}")

    def test_every_settings_entry_point_is_a_push_with_system_back(self):
        sites = entry_points()
        self.assertTrue(sites, "no SettingsView entry point found")
        for path, body, start in sites:
            with self.subTest(path=str(path)):
                preceding = body[max(0, start - 200):start]
                self.assertIn(".navigationDestination(", preceding,
                              "SettingsView must be pushed so the system back button exists")


if __name__ == "__main__":
    unittest.main()
