"""Wrong-PIN "attempts remaining" uses plural rules, not one format string. No Xcode, devices or network.

2026-09-28: the unlock screen (PinView) showed "Wrong PIN. 1 attempts remaining". `wrong_pin_%lld` now
also lives in `Localizable.stringsdict` (en: one/other; zh-Hant/zh-Hans: other only, text unchanged); the
`Localizable.strings` entry stays as the plain fallback and must keep the plural's `other` text. XCTest (WrongPinPluralTests)
checks the rendered text; this checks the resource shape and that PinView renders through it.
"""
from pathlib import Path
import json
import plistlib
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
KEY = "wrong_pin_%lld"
EXPECTED = {
    "en": {"one": "Wrong PIN. %lld attempt remaining", "other": "Wrong PIN. %lld attempts remaining"},
    "zh-Hant": {"other": "PIN 碼錯誤，剩餘 %lld 次"},
    "zh-Hans": {"other": "PIN 码错误，剩余 %lld 次"},
}


def code(path):
    """Source without `//` comment lines and without previews."""
    source = (ROOT / path).read_text().split("#Preview", 1)[0]
    return "\n".join(line for line in source.splitlines() if not line.strip().startswith("//"))


class WrongPinPluralTests(unittest.TestCase):
    def test_stringsdict_has_plural_rule_per_language(self):
        for lang, forms in EXPECTED.items():
            with self.subTest(lang=lang):
                path = ROOT / f"odoo/Resources/{lang}.lproj/Localizable.stringsdict"
                entry = plistlib.loads(path.read_bytes())[KEY]
                variable = entry["NSStringLocalizedFormatKey"].split("%#@", 1)[1].split("@", 1)[0]
                rule = entry[variable]
                self.assertEqual("NSStringPluralRuleType", rule["NSStringFormatSpecTypeKey"])
                self.assertEqual("lld", rule["NSStringFormatValueTypeKey"])
                given = {k: v for k, v in rule.items() if not k.startswith("NSStringFormat")}
                rendered = {k: entry["NSStringLocalizedFormatKey"].replace(f"%#@{variable}@", v)
                            for k, v in given.items()}
                self.assertEqual(forms, rendered)

    def test_strings_fallback_matches_the_plural_other_form(self):
        for lang, forms in EXPECTED.items():
            with self.subTest(lang=lang):
                path = ROOT / f"odoo/Resources/{lang}.lproj/Localizable.strings"
                values = json.loads(subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
                                                   check=True, capture_output=True).stdout)
                self.assertEqual(forms["other"], values[KEY])

    def test_pin_view_renders_through_the_plural_helper(self):
        view = code("odoo/UI/Auth/PinView.swift")
        self.assertIn("error = wrongPinMessage(remainingAttempts: remaining)", view)
        self.assertNotIn('String(localized: "wrong_pin_%lld"', view, "a plain format string cannot pick one/other")
        helper = code("odoo/UI/Auth/WrongPinMessage.swift")
        self.assertIn("String.localizedStringWithFormat(", helper)
        self.assertIn('NSLocalizedString("wrong_pin_%lld", bundle: bundle', helper)

if __name__ == "__main__":
    unittest.main()
