"""Permission prompts for App Review 2.1(a) and 5.1.1(ii). No Xcode, devices or network.

woowtech platform 1.0 (3) was rejected (2026-09); the same code ships Apporo:
- 2.1(a): tapping the microphone in Odoo Discuss on iPad crashed the app. Info.plist had no
  NSMicrophoneUsageDescription, so iOS terminates the app when WKWebView asks for the microphone.
- 5.1.1(ii): the camera / photo library purpose strings were too vague ("to upload photos in Odoo").

Checked here: the Info.plist defaults (Config/Shared.xcconfig INFOPLIST_KEY_*) and every brand x language
InfoPlist.strings carry the three keys with the brand name, a concrete purpose and an example; the
location prompt keeps its exact wording. XCTest (PermissionUsageDescriptionTests) checks the built bundle.
"""
from pathlib import Path
import json
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "415d094"  # feat/apporo-platform-brand-layer before this change
LANGS = ["en", "zh-Hans", "zh-Hant"]
KEYS = ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSPhotoLibraryUsageDescription"]
BRAND = {("apporo", lang): "Apporo platform" for lang in LANGS}
BRAND.update({("woowtech", "en"): "woowtech platform", ("woowtech", "zh-Hans"): "woowtech platform",
              ("woowtech", "zh-Hant"): "渥屋平台"})
REQUIRED = {
    "NSMicrophoneUsageDescription": {
        "en": ["microphone", "voice message", "voice call", "Odoo Discuss"],
        "zh-Hant": ["麥克風", "語音訊息", "語音通話", "討論"],
        "zh-Hans": ["麦克风", "语音消息", "语音通话", "讨论"],
    },
    "NSCameraUsageDescription": {
        "en": ["camera", "photo", "for example", "quotation", "expense", "maintenance"],
        "zh-Hant": ["相機", "拍照", "例如", "報價單", "費用報銷", "維修"],
        "zh-Hans": ["相机", "拍照", "例如", "报价单", "费用报销", "维修"],
    },
    "NSPhotoLibraryUsageDescription": {
        "en": ["photo", "attach", "Odoo record", "chat message", "for example"],
        "zh-Hant": ["相簿", "附加", "Odoo 紀錄", "聊天訊息", "例如"],
        "zh-Hans": ["相册", "附加", "Odoo 记录", "聊天消息", "例如"],
    },
}
VAGUE = ["to upload photos in Odoo", "to upload images in Odoo", "上傳照片", "上传照片", "上傳圖片", "上传图片"]


def strings(brand, lang, rev=None):
    path = f"BrandResources/{brand}/{lang}.lproj/InfoPlist.strings"
    data = (subprocess.run(["git", "show", f"{rev}:{path}"], cwd=ROOT, check=True, capture_output=True).stdout
            if rev else (ROOT / path).read_bytes())
    result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", "-"], input=data,
                            check=True, capture_output=True)
    return json.loads(result.stdout)


def xcconfig(rev=None):
    path = "Config/Shared.xcconfig"
    text = (subprocess.run(["git", "show", f"{rev}:{path}"], cwd=ROOT, check=True, capture_output=True).stdout.decode()
            if rev else (ROOT / path).read_text())
    return dict(re.findall(r"^INFOPLIST_KEY_(\w+) = (.*)$", text, re.M))


class PermissionPromptTests(unittest.TestCase):
    def test_every_brand_and_language_has_specific_prompts(self):
        defaults = {k: v.replace("$(APP_DISPLAY_NAME)", "woowtech platform") for k, v in xcconfig().items()}
        for (brand, lang), name in BRAND.items():
            values = strings(brand, lang)
            for key in KEYS:
                with self.subTest(brand=brand, lang=lang, key=key):
                    # woowtech en has no per-key override: iOS shows the Info.plist default.
                    text = values[key] if (brand, lang) != ("woowtech", "en") else defaults[key]
                    if (brand, lang) == ("woowtech", "en"):
                        self.assertNotIn(key, values)
                    self.assertIn(name, text)
                    for word in REQUIRED[key][lang]:
                        self.assertIn(word, text)
                    self.assertGreaterEqual(len(text), 90 if lang == "en" else 35)
                    for vague in VAGUE:
                        self.assertNotIn(vague, text)
                    other = "woow" if brand == "apporo" else "apporo"
                    self.assertNotIn(other, text.lower())
                    if lang != "en":
                        self.assertRegex(text, r"[一-鿿]")

    def test_info_plist_defaults_declare_all_keys_with_purpose(self):
        defaults = xcconfig()
        for key in KEYS:
            with self.subTest(key=key):
                text = defaults[key]
                self.assertTrue(text.startswith("$(APP_DISPLAY_NAME) "), text)
                for word in REQUIRED[key]["en"]:
                    self.assertIn(word, text)
                self.assertNotIn("//", text, "// starts an xcconfig comment")

    def test_location_prompt_wording_is_unchanged(self):
        self.assertEqual(xcconfig(BASELINE)["NSLocationWhenInUseUsageDescription"],
                         xcconfig()["NSLocationWhenInUseUsageDescription"])
        for (brand, lang) in BRAND:
            with self.subTest(brand=brand, lang=lang):
                old = strings(brand, lang, BASELINE).get("NSLocationWhenInUseUsageDescription")
                self.assertEqual(old, strings(brand, lang).get("NSLocationWhenInUseUsageDescription"))


if __name__ == "__main__":
    unittest.main()
