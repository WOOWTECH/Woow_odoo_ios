"""Offline brand checks shared by verification and stdlib tests.

Importing this module does no I/O. Validators accept source/identity data only;
no device tools, Firebase credentials, or live verification entry point needed.
"""
from pathlib import Path
import re


# Independent expectations, not values derived from the provider under test.
IDENTITIES = {
    "Debug": ("WoowDebug", "woowtech", "io.woowtech.odoo", "woowodoo", "#6183FC"),
    "Release": ("WoowRelease", "woowtech", "io.woowtech.odoo", "woowodoo", "#6183FC"),
    "ApporoDebug": ("ApporoDebug", "apporo", "com.apporo.odoo.dev", "apporoodoo-dev", "#8B6B24"),
    "ApporoRelease": ("ApporoRelease", "apporo", "com.apporo.odoo", "apporoodoo", "#8B6B24"),
}


def load_brand_settings(root, configuration):
    """Read only xcconfig settings, including declared local project-ID override.

    Missing required includes/unknown configurations fail rather than falling
    back. This is not a general Xcode build-settings evaluator.
    """
    name = IDENTITIES[configuration][0]
    values = {}

    def include(path):
        for line in path.read_text().splitlines():
            directive = re.fullmatch(r'#include(\?)? "([^"]+)"', line.strip())
            if directive:
                child = path.parent / directive[2]
                if not directive[1] or child.exists():
                    include(child)
            elif " = " in line and not line.lstrip().startswith("//"):
                key, value = line.split(" = ", 1)
                values[key.strip()] = value.strip()

    include(Path(root) / "Config" / (name + ".xcconfig"))
    return values


def valid_configuration(configuration, settings):
    expected = IDENTITIES.get(configuration)
    return expected is not None and all(settings.get(key) == value for key, value in zip(
        ("APP_BRAND", "PRODUCT_BUNDLE_IDENTIFIER", "APP_URL_SCHEME"), expected[1:4]))


def verify_provider_color(configuration, settings, provider_source, theme_source):
    if not valid_configuration(configuration, settings):
        return False
    # Require the actual property expression, not unrelated hex strings/comments.
    provider = re.sub(r"//[^\n]*", "", provider_source)
    theme = re.sub(r"//[^\n]*", "", theme_source)
    match = re.search(r'var primaryColorHex: String\s*\{\s*code == \.apporo\s*\?\s*"(#[0-9A-F]{6})"\s*:\s*"(#[0-9A-F]{6})"\s*\}', provider)
    if not match or "AppBrand.current.primaryColorHex" not in theme:
        return False
    selected = match[1] if settings["APP_BRAND"] == "apporo" else match[2]
    return selected == IDENTITIES[configuration][4]


def selected_firebase_path(root, settings):
    return Path(settings.get("FIREBASE_CONFIG_PATH", "").replace("$(SRCROOT)", str(root)))


def verify_firebase_identity(configuration, settings, root, selected_path, identity):
    """Only non-secret plist fields; None means missing/unreadable configuration."""
    if not valid_configuration(configuration, settings) or not identity:
        return False
    apporo = settings["APP_BRAND"] == "apporo"
    relative = (f"BrandResources/Firebase/{configuration}/GoogleService-Info.plist"
                if apporo else "odoo/GoogleService-Info.plist")
    expected_path = (Path(root) / relative).resolve()
    if Path(selected_path).resolve() != expected_path or selected_firebase_path(root, settings).resolve() != expected_path:
        return False
    project = settings.get("FIREBASE_EXPECTED_PROJECT_ID", "")
    if not project or (apporo and (project.startswith("woow") or "aiot" in project)):
        return False
    sender = identity.get("GCM_SENDER_ID", "")
    app_id = identity.get("GOOGLE_APP_ID", "")
    return (identity.get("BUNDLE_ID") == settings["PRODUCT_BUNDLE_IDENTIFIER"]
            and identity.get("PROJECT_ID") == project
            and isinstance(sender, str) and re.fullmatch(r"[0-9]+", sender) is not None
            and isinstance(app_id, str) and re.fullmatch(r"1:" + re.escape(sender) + r":ios:[0-9a-f]+", app_id) is not None)
