"""Plural-rule contract for the unlock screen's wrong-PIN line (full-run I13).

`wrong_pin_%lld` in Localizable.strings is one fixed format, so English showed
"1 attempts remaining". The key is now also a plural rule in Localizable.stringsdict
(English one/other, Chinese other only). The `.strings` entry stays, unchanged, as the
plain fallback and is exactly the `other` form, so the three-language key set and
wording contract elsewhere are untouched. Mirrors Android 3fb8097 (PIN_PLURALS_RETYPED).
"""
import json
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
LANGS = ["en", "zh-Hans", "zh-Hant"]
KEY = "wrong_pin_%lld"


def plist(path):
    result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(ROOT / path)], check=True, capture_output=True)
    return json.loads(result.stdout)


class WrongPinPluralTests(unittest.TestCase):
    def rule(self, lang):
        table = plist(f"odoo/Resources/{lang}.lproj/Localizable.stringsdict")
        self.assertEqual(set(table), {KEY}, "only the wrong-PIN line is retyped as a plural")
        entry = table[KEY]
        self.assertEqual(entry["NSStringLocalizedFormatKey"], "%#@attempts@")
        rule = entry["attempts"]
        self.assertEqual(rule["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType")
        self.assertEqual(rule["NSStringFormatValueTypeKey"], "lld")
        return rule

    def test_other_form_is_the_unchanged_strings_text_in_every_language(self):
        for lang in LANGS:
            with self.subTest(lang=lang):
                strings = plist(f"odoo/Resources/{lang}.lproj/Localizable.strings")
                self.assertEqual(self.rule(lang)["other"], strings[KEY])

    def test_english_has_a_singular_and_chinese_only_other(self):
        english = self.rule("en")
        self.assertEqual(english["one"], "Wrong PIN. %lld attempt remaining")
        self.assertEqual(english["other"], "Wrong PIN. %lld attempts remaining")
        for lang in ["zh-Hans", "zh-Hant"]:
            with self.subTest(lang=lang):
                self.assertEqual(set(self.rule(lang)) - {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"}, {"other"})

    def test_unlock_screen_formats_through_the_plural_helper(self):
        view = (ROOT / "odoo/UI/Auth/PinView.swift").read_text()
        self.assertIn("wrongPinMessage(remainingAttempts: remaining)", view)
        self.assertNotIn(f'"{KEY}"', view)
        helper = (ROOT / "odoo/UI/Auth/WrongPinMessage.swift").read_text()
        self.assertIn("String.localizedStringWithFormat(", helper)


if __name__ == "__main__":
    unittest.main()
