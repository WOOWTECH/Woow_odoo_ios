"""Offline stage-2 contracts. No Xcode, devices, dependencies or network."""
import ast
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from brand_test_target import block_legacy_live_e2e, validate_target
from generate_apporo_assets import read_png


def text(path):
    return (ROOT / path).read_text()


def plist(path):
    # plutil parses OpenStep project files and .strings without loading Xcode.
    result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(ROOT / path)], check=True, capture_output=True)
    return json.loads(result.stdout)


def config(name):
    values = {}
    for line in text("Config/" + name + ".xcconfig").splitlines():
        if " = " in line and not line.startswith("//"):
            key, value = line.split(" = ", 1)
            values[key] = value
    return values



# demo111 live run 2026-09-29 — approved odooApp.swift root deltas (current, baseline).
# F3 (0930): the external-link handler delegates validation and account binding to the unit-tested
# `ExternalLinkIntake`; the scheme gate stays in the root. Folded back to the protected baseline.
# pi 1001e (2026-10-02): a switch refused because the target must sign in again opens a pre-filled
# sign-in for that account. Folded back to the previous root before the older delta lists apply.
SIGN_IN_REQUIRED_ROOT_DELTAS = [
    ("""    @State private var isAddingAccount = false
    /// pi 1001e: an existing account a switch refused because it must sign in again; the login screen
    /// opens pre-filled for it (credentials step) with Cancel back to the current account.
    @State private var signInAccount: OdooAccount?
    @State private var pendingSignInAccount: OdooAccount?
""", """    @State private var isAddingAccount = false
"""),
    ("""                LoginView(addingAccount: isAddingAccount, signInAccount: signInAccount, onLoginSuccess: {
                    isAddingAccount = false
                    signInAccount = nil
""", """                LoginView(addingAccount: isAddingAccount, onLoginSuccess: {
                    isAddingAccount = false
"""),
    ("""                    isAddingAccount = false
                    signInAccount = nil
                    rootViewModel.cancelAddAccount()""", """                    isAddingAccount = false
                    rootViewModel.cancelAddAccount()"""),
    ("""                .id("\\(isAddingAccount)-\\(signInAccount?.id ?? "")")""", """                .id(isAddingAccount)"""),
    ("""            if let account = pendingSignInAccount {
                pendingSignInAccount = nil
                signInAccount = account
                isAddingAccount = true
                rootViewModel.beginAddAccount()
            } else if pendingAddAccount {""", """            if pendingAddAccount {"""),
    ("""                onSignInRequired: { account in
                    pendingSignInAccount = account
                    showConfig = false
                },
""", ""),
]

EXTERNAL_LINK_INTAKE_ROOT_DELTAS = [
    ("""        guard AppBrand.current.acceptsScheme(url.scheme) else { return }
        // F3 (0930): validation + account binding live in `ExternalLinkIntake` (unit-tested).
        ExternalLinkIntake.accept(url, activeAccount: AccountRepository().getActiveAccount(),
                                  manager: DeepLinkManager.shared)
""", """        guard AppBrand.current.acceptsScheme(url.scheme) else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let urlParam = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            return
        }
        let serverHost = AccountRepository().getActiveAccount()?.serverHost ?? ""
        if DeepLinkValidator.isValid(url: urlParam, serverHost: serverHost) {
            DeepLinkManager.shared.setPending(urlParam)
        }
"""),
]

ADD_ACCOUNT_CANCEL_AND_PRUNE_ROOT_DELTAS = [
    ("""                }, onCancel: rootViewModel.canCancelAddAccount ? {
                    // Back to the account that was active; App Lock re-prompts via the
                    // launchState → .authenticated observer if a background re-locked meanwhile.
                    isAddingAccount = false
                    rootViewModel.cancelAddAccount()
                } : nil)
""", """                })
"""),
    ("""            rootViewModel.checkSession()
            // D1: delete WebKit stores whose account is gone (earlier builds never removed them;
            // a store still in use at logout is deleted here on the next launch).
            await AccountRepository().pruneOrphanWebData()
""", """            rootViewModel.checkSession()
"""),
    ("""            // Also covers the add-account form, which sits in front of a signed-in account.
            guard rootViewModel.shouldRelockOnBackground else { return }
""", """            guard rootViewModel.launchState == .authenticated else { return }
"""),
    ("""                // Not over the add-account form: the gate prompts when Cancel returns to the account.
                guard rootViewModel.launchState == .authenticated else { break }
                authViewModel.appDidBecomeActive()
""", """                authViewModel.appDidBecomeActive()
"""),
]


class BrandLayerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = plist("odoo.xcodeproj/project.pbxproj")
        cls.objects = cls.project["objects"]

    def test_four_configuration_identities(self):
        matrix = [
            ("WoowDebug", "woowtech", "io.woowtech.odoo", "woowodoo", "3", "AppIcon"),
            ("WoowRelease", "woowtech", "io.woowtech.odoo", "woowodoo", "3", "AppIcon"),
            ("ApporoDebug", "apporo", "com.apporo.odoo.dev", "apporoodoo-dev", "1", "ApporoAppIcon"),
            # ApporoRelease build 1 = App Store Connect 2026-09-27 (b902ff47), build 2 = 8c03e44
            # (TestFlight 2026-09-29), build 3 = the 1001g bump (1001b–1001g fixes; not yet
            # uploaded). Uploaded numbers can never be reused.
            ("ApporoRelease", "apporo", "com.apporo.odoo", "apporoodoo", "3", "ApporoAppIcon"),
        ]
        for name, brand, bundle, scheme, version, icon in matrix:
            with self.subTest(name=name):
                c = config(name)
                for key, expected in [("APP_BRAND", brand), ("PRODUCT_BUNDLE_IDENTIFIER", bundle), ("APP_URL_SCHEME", scheme), ("CURRENT_PROJECT_VERSION", version), ("ASSETCATALOG_COMPILER_APPICON_NAME", icon)]:
                    self.assertEqual(c[key], expected)
                self.assertEqual(c["APP_DISPLAY_NAME"], "Apporo platform" if brand == "apporo" else "woowtech platform")
        self.assertIn("MARKETING_VERSION = 1.0", text("Config/Shared.xcconfig"))
        # Guard against re-using an uploaded ApporoRelease build number.
        self.assertGreaterEqual(int(config("ApporoRelease")["CURRENT_PROJECT_VERSION"]), 3)

    def test_project_and_three_targets_have_matching_configurations(self):
        lists = [v for v in self.objects.values() if v.get("isa") == "XCConfigurationList"]
        self.assertEqual(len(lists), 4)
        for group in lists:
            configs = [self.objects[x] for x in group["buildConfigurations"]]
            self.assertEqual({c["name"] for c in configs}, {"Debug", "Release", "ApporoDebug", "ApporoRelease"})
        targets = [v for v in self.objects.values() if v.get("isa") == "PBXNativeTarget"]
        self.assertEqual({v["name"] for v in targets}, {"odoo", "odooTests", "odooUITests"})
        app = next(v for v in targets if v["name"] == "odoo")
        for cid in self.objects[app["buildConfigurationList"]]["buildConfigurations"]:
            c = self.objects[cid]
            name = c["name"] if c["name"].startswith("Apporo") else "Woow" + c["name"]
            self.assertEqual(self.objects[c["baseConfigurationReference"]]["path"], "Config/" + name + ".xcconfig")
            for key in ["PRODUCT_BUNDLE_IDENTIFIER", "CURRENT_PROJECT_VERSION", "ASSETCATALOG_COMPILER_APPICON_NAME", "INFOPLIST_KEY_CFBundleDisplayName"]:
                self.assertNotIn(key, c["buildSettings"], "target overrides xcconfig")

    def test_release_flags_apns_and_audit_not_skipped(self):
        for name in ["WoowDebug", "WoowRelease", "ApporoDebug", "ApporoRelease"]:
            c = config(name)
            release = name.endswith("Release")
            self.assertEqual(c["BRAND_RELEASE_AUDIT"], "YES" if release else "NO")
            self.assertEqual(c["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "" if release else "DEBUG")
            entitlements = plistlib.loads((ROOT / c["CODE_SIGN_ENTITLEMENTS"]).read_bytes())
            self.assertEqual(entitlements["aps-environment"], "production" if release else "development")
        for c in self.objects.values():
            if c.get("isa") == "XCBuildConfiguration" and c["name"].endswith("Release"):
                self.assertNotIn("DEBUG", c["buildSettings"].get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""))
        phase = next(v for v in self.objects.values() if v.get("name") == "Audit debug-hook leaks (Release)")
        self.assertIn('$BRAND_RELEASE_AUDIT', phase["shellScript"])
        self.assertNotIn('$CONFIGURATION\\\" !=', phase["shellScript"])
        self.assertIn('audit_test_hook_naming.sh', phase["shellScript"])
        self.assertIn('audit_release_archive.sh', phase["shellScript"])

    def test_release_configs_never_instrument_coverage(self):
        # A scheme whose test plan gathers coverage makes the *build* action
        # inject CLANG_COVERAGE_MAPPING=YES above xcconfig precedence, even for
        # Release. The xcconfig must turn off the gates the Swift/Clang compiler
        # and linker specs consult, so the in-build Release audit (coverage
        # check) passes. Debug keeps Xcode's defaults for unit-test coverage.
        keys = ["CLANG_COVERAGE_MAPPING", "ENABLE_CODE_COVERAGE", "CLANG_ENABLE_CODE_COVERAGE",
                "CLANG_COVERAGE_MAPPING_LINKER_ARGS", "LD_DEBUG_VARIANT"]
        for name in ["WoowRelease", "ApporoRelease"]:
            c = config(name)
            for key in keys:
                with self.subTest(name=name, key=key):
                    self.assertEqual(c.get(key), "NO")
        for name in ["WoowDebug", "ApporoDebug", "Shared"]:
            c = config(name)
            for key in keys:
                with self.subTest(name=name, key=key):
                    self.assertNotIn(key, c)
        for c in self.objects.values():
            if c.get("isa") == "XCBuildConfiguration":
                for key in keys:
                    self.assertNotIn(key, c["buildSettings"], "project/target level would override xcconfig")

    def test_schemes_preserve_woow_and_select_apporo(self):
        original = subprocess.run(["git", "show", "a50c4df:odoo.xcodeproj/xcshareddata/xcschemes/odoo.xcscheme"], cwd=ROOT, capture_output=True, check=True).stdout
        self.assertEqual(original, (ROOT / "odoo.xcodeproj/xcshareddata/xcschemes/odoo.xcscheme").read_bytes())
        scheme = ET.fromstring(text("odoo.xcodeproj/xcshareddata/xcschemes/apporoodoo.xcscheme"))
        for action in ["TestAction", "LaunchAction", "AnalyzeAction"]:
            self.assertEqual(scheme.find(action).get("buildConfiguration"), "ApporoDebug")
        for action in ["ProfileAction", "ArchiveAction"]:
            self.assertEqual(scheme.find(action).get("buildConfiguration"), "ApporoRelease")
        # Default plan stays unit-only (no live location E2E); UI tests are
        # reachable only by explicitly choosing -testPlan ApporoUI.
        plans = {p.get("reference"): p.get("default") for p in scheme.findall("TestAction/TestPlans/TestPlanReference")}
        self.assertEqual(plans, {"container:ApporoUnit.xctestplan": "YES", "container:ApporoUI.xctestplan": None})
        self.assertEqual([e.get("BlueprintName") for e in scheme.findall("TestAction/Testables/TestableReference/BuildableReference")], ["odooTests", "odooUITests"])
        for plan_name, target in [("ApporoUnit", "odooTests"), ("ApporoUI", "odooUITests")]:
            plan = json.loads(text(f"{plan_name}.xctestplan"))
            self.assertEqual([t["target"]["name"] for t in plan["testTargets"]], [target])
            self.assertTrue(all(t.get("enabled", True) for t in plan["testTargets"]))
            self.assertNotIn("environmentVariableEntries", json.dumps(plan))
            self.assertNotIn("RUN_LOCATION_E2E", json.dumps(plan))

    def test_resource_outputs_have_one_owner_and_declared_inputs(self):
        exceptions = next(v for v in self.objects.values() if v.get("isa") == "PBXFileSystemSynchronizedBuildFileExceptionSet")["membershipExceptions"]
        self.assertIn("GoogleService-Info.plist", exceptions)
        phase = next(v for v in self.objects.values() if v.get("name") == "Select brand resources")
        self.assertEqual(len(phase["outputPaths"]), 4)
        self.assertEqual(len(set(phase["outputPaths"])), 4)
        self.assertIn("$(FIREBASE_CONFIG_PATH)", phase["inputPaths"])
        self.assertEqual(phase["alwaysOutOfDate"], "1")
        for lang in ["en", "zh-Hans", "zh-Hant"]:
            self.assertIn(f"$(SRCROOT)/BrandResources/$(APP_BRAND)/{lang}.lproj/InfoPlist.strings", phase["inputPaths"])
        self.assertFalse(any(v.get("path") == "BrandResources" for v in self.objects.values()))

    def test_localized_brand_resources_live_outside_synchronized_sources(self):
        # Actual Xcode builds still copied localized files despite membership exclusions.
        # Keeping their only source outside the synchronized group removes that producer.
        self.assertEqual(list((ROOT / "odoo").rglob("InfoPlist.strings")), [])
        for lang in ["en", "zh-Hans", "zh-Hant"]:
            self.assertTrue((ROOT / f"odoo/Resources/{lang}.lproj/Localizable.strings").is_file())
            for brand in ["woowtech", "apporo"]:
                self.assertTrue((ROOT / f"BrandResources/{brand}/{lang}.lproj/InfoPlist.strings").is_file())

    def test_apporo_firebase_is_external_and_has_no_woow_fallback(self):
        for name in ["ApporoDebug", "ApporoRelease"]:
            c = config(name)
            self.assertEqual(c["FIREBASE_EXPECTED_PROJECT_ID"], "")
            self.assertEqual(c["FIREBASE_CONFIG_PATH"], f"$(SRCROOT)/BrandResources/Firebase/{name}/GoogleService-Info.plist")
            relative_path = c["FIREBASE_CONFIG_PATH"].replace("$(SRCROOT)/", "")
            # A provisioned local client may exist; it must remain ignored and untracked.
            ignored = subprocess.run(["git", "check-ignore", "-q", "--", relative_path], cwd=ROOT)
            tracked = subprocess.run(["git", "ls-files", "--error-unmatch", "--", relative_path],
                                     cwd=ROOT, capture_output=True)
            self.assertEqual(ignored.returncode, 0)
            self.assertNotEqual(tracked.returncode, 0)
        source = text("odoo/App/AppDelegate.swift")
        self.assertEqual(source.count("FirebaseApp.configure("), 1)
        self.assertIn("FirebaseApp.configure(options: options)", source)
        self.assertIn("options.bundleID == AppBrand.current.bundleID", source)
        self.assertIn("options.projectID == expectedProject", source)

    def run_resources(self, name, destination, **overrides):
        c = config(name)
        env = dict(os.environ, SRCROOT=str(ROOT), CONFIGURATION=name if name.startswith("Apporo") else name.removeprefix("Woow"), TARGET_BUILD_DIR=str(destination), UNLOCALIZED_RESOURCES_FOLDER_PATH="odoo.app")
        env.update({k: v.replace("$(SRCROOT)", str(ROOT)) for k, v in c.items()})
        # Synthetic client only: this offline suite must not read real credentials.
        if name.startswith("Woow"):
            fixture = Path(destination) / "mock-firebase.plist"
            fixture.write_bytes(plistlib.dumps({
                "BUNDLE_ID": "io.woowtech.odoo", "PROJECT_ID": "woow-odoo-de2cb",
                "GOOGLE_APP_ID": "1:123:ios:abc", "GCM_SENDER_ID": "123",
                "API_KEY": "offline-mock-not-a-credential",
            }))
            env["FIREBASE_CONFIG_PATH"] = str(fixture)
        else:
            # Never touch a real provisioned Apporo client during negative fixture tests.
            env["FIREBASE_CONFIG_PATH"] = str(Path(destination) / "missing-firebase.plist")
        env.update(overrides)
        return subprocess.run(["/bin/sh", str(ROOT / "scripts/select_brand_resources.sh")], env=env, cwd=ROOT, capture_output=True, text=True)

    def test_missing_apporo_configs_fail_before_any_output(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            for name in ["ApporoDebug", "ApporoRelease"]:
                result = self.run_resources(name, Path(folder))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("selected Firebase plist is missing", result.stderr)
                self.assertEqual(list(Path(folder).iterdir()), [])

    def test_resource_selection_rejects_unknown_or_mixed_variant(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            for overrides in [{"APP_BRAND": "unknown"}, {"PRODUCT_BUNDLE_IDENTIFIER": "io.woowtech.odoo"}, {"APP_URL_SCHEME": "apporoodoo"}, {"BRAND_RELEASE_AUDIT": "YES"}]:
                result = self.run_resources("ApporoDebug", Path(folder), **overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unknown or inconsistent variant", result.stderr)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_resource_selection_rejects_cross_brand_firebase(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            fixture = Path(folder) / "mock-woow.plist"
            fixture.write_bytes(plistlib.dumps({
                "BUNDLE_ID": "io.woowtech.odoo", "PROJECT_ID": "woow-odoo-de2cb",
                "GOOGLE_APP_ID": "1:123:ios:abc", "GCM_SENDER_ID": "123",
                "API_KEY": "offline-mock-not-a-credential",
            }))
            result = self.run_resources("ApporoDebug", Path(folder), FIREBASE_CONFIG_PATH=str(fixture), FIREBASE_EXPECTED_PROJECT_ID="woow-odoo-de2cb")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Firebase identity mismatch", result.stderr)
            self.assertEqual(list(Path(folder).iterdir()), [fixture])

    def test_missing_verified_project_fails_before_output(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            result = self.run_resources("WoowDebug", Path(folder), FIREBASE_EXPECTED_PROJECT_ID="")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("verified Firebase project ID is required", result.stderr)
            self.assertEqual(list(Path(folder).iterdir()), [Path(folder) / "mock-firebase.plist"])

    def test_woow_selection_copies_only_selected_resources(self):
        # Copy semantics checked with a synthetic client, not real credentials.
        with tempfile.TemporaryDirectory(dir=ROOT) as folder:
            for variant in ["WoowDebug", "WoowRelease"]:
                result = self.run_resources(variant, Path(folder))
                self.assertEqual(result.returncode, 0, result.stderr)
                app = Path(folder) / "odoo.app"
                files = sorted(str(p.relative_to(app)) for p in app.rglob("*") if p.is_file())
                self.assertEqual(files, sorted(["GoogleService-Info.plist"] + [f"{lang}.lproj/InfoPlist.strings" for lang in ["en", "zh-Hans", "zh-Hant"]]))
                self.assertEqual((app / "GoogleService-Info.plist").read_bytes(), (Path(folder) / "mock-firebase.plist").read_bytes())

    def test_localized_resources_and_woow_baseline(self):
        keysets = []
        for lang in ["en", "zh-Hans", "zh-Hant"]:
            apporo = plist(f"BrandResources/apporo/{lang}.lproj/InfoPlist.strings")
            self.assertEqual(apporo["CFBundleDisplayName"], "Apporo platform")
            self.assertEqual(apporo["CFBundleName"], "Apporo platform")
            for key in ["NSCameraUsageDescription", "NSPhotoLibraryUsageDescription", "NSFaceIDUsageDescription", "NSLocationWhenInUseUsageDescription"]:
                self.assertIn("Apporo platform", apporo[key])
                self.assertNotIn("woow", apporo[key].lower())
                if lang != "en":
                    self.assertRegex(apporo[key], r"[\u4e00-\u9fff]")
            path = f"odoo/Resources/{lang}.lproj/InfoPlist.strings"
            # WOOW baseline is the 1.0.1 engineering fix (acff782): zh-Hant name
            # 「渥屋平台」 plus zh-Hans/zh-Hant permission prompts; en is unchanged
            # from ios-1.0-b3 (a50c4df).
            original = subprocess.run(["git", "show", "acff782:" + path], cwd=ROOT, check=True, capture_output=True).stdout
            self.assertFalse((ROOT / path).exists(), "No duplicate auto-copied InfoPlist source")
            # App Review 2026-09 (2.1(a) / 5.1.1(ii)): only the camera, photo library and new microphone
            # prompts may differ from that baseline; every other byte stays identical.
            def without_review_prompts(data):
                keys = (b'"NSCameraUsageDescription"', b'"NSPhotoLibraryUsageDescription"', b'"NSMicrophoneUsageDescription"')
                return b"".join(line for line in data.splitlines(keepends=True) if not line.startswith(keys))
            current = (ROOT / f"BrandResources/woowtech/{lang}.lproj/InfoPlist.strings").read_bytes()
            self.assertEqual(without_review_prompts(original), without_review_prompts(current))
            if lang == "en":
                self.assertEqual(original, current)
            woow = plist(f"BrandResources/woowtech/{lang}.lproj/InfoPlist.strings")
            self.assertEqual(woow["CFBundleDisplayName"], "渥屋平台" if lang == "zh-Hant" else "woowtech platform")
            if lang != "en":
                for key in ["NSCameraUsageDescription", "NSPhotoLibraryUsageDescription", "NSFaceIDUsageDescription", "NSLocationWhenInUseUsageDescription"]:
                    self.assertRegex(woow[key], r"[\u4e00-\u9fff]")
                    self.assertNotIn("apporo", woow[key].lower())
            shared = plist(f"odoo/Resources/{lang}.lproj/Localizable.strings")
            keysets.append(set(shared))
            self.assertIn("%@", shared["biometric_reason"])
            self.assertFalse(any("woow" in value.lower() for value in shared.values()))
        self.assertEqual(keysets[0], keysets[1])
        self.assertEqual(keysets[0], keysets[2])

    def test_provider_is_wired_not_just_defined(self):
        self.assertIn("AppBrand.current.primaryColorHex", text("odoo/Domain/Models/AppSettings.swift"))
        self.assertIn("AppBrand.current.primaryColorHex", text("odoo/UI/Theme/WoowColors.swift"))
        self.assertIn("AppBrand.current.logoAsset", text("odoo/UI/Login/LoginView.swift"))
        self.assertIn("AppBrand.current.keychainService", text("odoo/Data/Storage/SecureStorage.swift"))
        self.assertIn("AppBrand.current.acceptsScheme(url.scheme)", text("odoo/odooApp.swift"))
        for file in ["odoo/UI/Login/LoginView.swift", "odoo/UI/Main/MainView.swift"]:
            self.assertIn("AppBrand.current.displayName", text(file))
        settings = text("odoo/UI/Settings/SettingsView.swift")
        for token in ["AppBrand.current.signature", "AppBrand.current.websiteURL", "AppBrand.current.contactEmail", "AppBrand.current.pageURL"]:
            self.assertIn(token, settings)
        for path in (ROOT / "odoo/UI").rglob("*.swift"):
            code = "\n".join(line for line in path.read_text().splitlines() if not line.strip().startswith("//"))
            for old in ['"#6183FC"', '"WoowLogo"', '"woowtech platform"', '"https://aiot.woowtech.io"']:
                self.assertNotIn(old, code, str(path.relative_to(ROOT)))
        self.assertIn('AppBrand.current.localized("biometric_reason")', text("odoo/UI/Auth/AuthViewModel.swift"))

    def test_scheme_branding_preserves_validator_privacy_and_ordinary_root(self):
        for file in ["odoo/Data/Push/DeepLinkValidator.swift", "odoo/App/TestHookGate.swift", "odoo/PrivacyInfo.xcprivacy"]:
            result = subprocess.run(["git", "diff", "a50c4df", "--", file], cwd=ROOT, capture_output=True, check=True)
            self.assertEqual(result.stdout, b"", file)
        original = subprocess.run(["git", "show", "a50c4df:odoo/odooApp.swift"], cwd=ROOT, capture_output=True, check=True).stdout.decode()
        expected = original.replace('guard url.scheme == "woowodoo"', 'guard AppBrand.current.acceptsScheme(url.scheme)')
        # The only additional root delta is the compile-only offline host. Keep
        # comparing the entire ordinary app path with the protected baseline.
        offline_root = '''            #if DEBUG && UNIT_TEST_HOST
            // Do not construct business dependencies or start checkSession.
            EmptyView()
            #else
'''
        current = text("odoo/odooApp.swift")
        self.assertEqual(current.count(offline_root), 1)
        current = current.replace(offline_root, "", 1)
        current = current.replace("                }\n            #endif\n        }", "                }\n        }", 1)
        # Approved root deltas for the demo111 2026-09-29 live-run fixes (D1 orphan-store pruning,
        # D3 add-account Cancel + App Lock coverage). Each current hunk must appear exactly once and
        # is folded back to the protected baseline before the whole-file comparison.
        for now, baseline in SIGN_IN_REQUIRED_ROOT_DELTAS + ADD_ACCOUNT_CANCEL_AND_PRUNE_ROOT_DELTAS + EXTERNAL_LINK_INTAKE_ROOT_DELTAS:
            self.assertEqual(current.count(now), 1, now)
            current = current.replace(now, baseline, 1)
        self.assertEqual(current, expected)

    def test_assets_are_hashed_opaque_white_mark(self):
        manifest = json.loads(text("BrandResources/asset-manifest.json"))
        self.assertEqual(len(manifest["outputs"]), 2)
        for output in manifest["outputs"]:
            data = (ROOT / output["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(data).hexdigest(), output["sha256"])
        icon = [output for output in manifest["outputs"] if output["path"].endswith("ApporoAppIcon.png")]
        self.assertEqual(len(icon), 1)
        data = (ROOT / icon[0]["path"]).read_bytes()
        # The app icon is the approved opaque white mark; the 2026-10-08 round login badge must not
        # change it (iOS masks the icon shape itself).
        self.assertEqual(hashlib.sha256(data).hexdigest(), "20814047ff0c3c51792158d3e0f24c1d24ffb8f2bf4cc4a9274a614476257f73")
        width, height, channels, rows = read_png(data)
        self.assertEqual((width, height, channels), (1024, 1024, 3))
        for corner in [rows[0][:3], rows[0][-3:], rows[-1][:3], rows[-1][-3:]]:
            self.assertEqual(corner, b"\xff\xff\xff")
        self.assertTrue(any(pixel != 255 for row in rows for pixel in row))

    def test_login_logo_is_round_badge(self):
        # Owner 2026-10-08: "Logo都要是圓型外框，這個通盤都去改". Supersedes the I16 dark variant
        # (transparent, #E6E6E6 mark): one universal image for both appearances, like WoowLogo — a
        # white disc with a #D9D9D9 inner-edge ring and the original #4D4D4D mark, transparent outside.
        manifest = json.loads(text("BrandResources/asset-manifest.json"))
        self.assertNotIn("appearance_variants", manifest)
        logo = [output for output in manifest["outputs"] if output["path"] == "odoo/Assets.xcassets/ApporoLogo.imageset/ApporoLogo.png"]
        self.assertEqual(len(logo), 1)
        data = (ROOT / logo[0]["path"]).read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), logo[0]["sha256"])
        contents = json.loads(text("odoo/Assets.xcassets/ApporoLogo.imageset/Contents.json"))
        self.assertEqual(contents["images"], [{"idiom": "universal", "filename": "ApporoLogo.png"}])
        self.assertEqual(sorted(p.name for p in (ROOT / "odoo/Assets.xcassets/ApporoLogo.imageset").iterdir()), ["ApporoLogo.png", "Contents.json"])
        width, height, channels, rows = read_png(data)
        self.assertEqual((width, height, channels), (1024, 1024, 4))

        def px(x, y):
            return tuple(rows[y][x * 4:x * 4 + 4])

        last = width - 1
        for x, y in [(0, 0), (last, 0), (0, last), (last, last), (100, 100), (last - 100, last - 100)]:
            self.assertEqual(px(x, y)[3], 0, (x, y))  # outside the disc
        self.assertEqual(px(512, 512), (255, 255, 255, 255))  # opaque white centre (mark has a hole there)
        ring = int(width * .03)
        for x, y in [(ring // 2, 512), (last - ring // 2, 512), (512, ring // 2), (512, last - ring // 2)]:
            r, g, b, a = px(x, y)
            self.assertEqual(a, 255, (x, y))
            for channel in (r, g, b):
                self.assertLessEqual(abs(channel - 0xD9), 2, (x, y))
        for x, y in [(ring + 20, 512), (512, ring + 20), (300, 512 - 150)]:
            self.assertEqual(px(x, y), (255, 255, 255, 255), (x, y))  # disc fill between ring and mark
        # Anti-aliased rim: partial alpha exists just at the disc edge.
        self.assertTrue(any(0 < row[3] < 255 for row in [px(x, 512) for x in range(0, 4)] + [px(x, 0) for x in range(400, 624)]))
        # The mark keeps its original #4D4D4D and stays inside the centred 60 % square.
        mark = round(width * .6)
        origin = (width - mark) // 2
        grey = [(x, y) for y in range(0, height, 2) for x in range(0, width, 2) if px(x, y) == (0x4D, 0x4D, 0x4D, 255)]
        self.assertGreater(len(grey), 1000)
        self.assertTrue(all(origin <= x < origin + mark and origin <= y < origin + mark for x, y in grey))

    def test_asset_source_provenance_when_explicitly_supplied(self):
        # Historical manifest source is provenance, never a required machine path.
        source = os.environ.get("APPORO_ASSET_SOURCE")
        if not source:
            self.skipTest("Source provenance not checked: set APPORO_ASSET_SOURCE to the original PNG")
        manifest = json.loads(text("BrandResources/asset-manifest.json"))
        self.assertEqual(hashlib.sha256(Path(source).read_bytes()).hexdigest(), manifest["source_sha256"])

    def test_apporo_white_primary_contrast(self):
        rgb = [int(x, 16) / 255 for x in ["8B", "6B", "24"]]
        linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in rgb]
        luminance = sum(a * b for a, b in zip(linear, [.2126, .7152, .0722]))
        self.assertGreaterEqual(1.05 / (luminance + .05), 4.5)
        accent = json.loads(text("odoo/Assets.xcassets/ApporoAccentColor.colorset/Contents.json"))
        self.assertEqual(accent["colors"][0]["color"]["components"], {"red": "0x8B", "green": "0x6B", "blue": "0x24", "alpha": "1.000"})

    def test_hook_registries_cover_existing_hooks_in_both_audits(self):
        referenced = set()
        for path in (ROOT / "odoo").rglob("*.swift"):
            referenced.update(re.findall(r"WOOW_(?:TEST|SEED)_[A-Z_][A-Z0-9_]*", path.read_text()))
        for script in ["scripts/audit_test_hook_naming.sh", "scripts/audit_release_archive.sh"]:
            registry = set(re.findall(r'"(WOOW_(?:TEST|SEED)_[A-Z_][A-Z0-9_]*)"', text(script)))
            self.assertEqual(referenced, registry)

    def test_device_target_requires_isolation_and_explicit_authorization(self):
        for bundle, scheme, authorized in [("io.woowtech.odoo", "odoo", True), ("io.woowtech.odoo.debug", "odoo", True), ("com.apporo.odoo", "apporoodoo", True), ("com.apporo.odoo.dev", "odoo", True), ("com.apporo.odoo.dev", "apporoodoo", False)]:
            with self.assertRaises(ValueError):
                validate_target(bundle, scheme, authorized)
        target = validate_target("com.apporo.odoo.dev", "apporoodoo", True)
        self.assertEqual((target.bundle_id, target.scheme, target.configuration), ("com.apporo.odoo.dev", "apporoodoo", "ApporoDebug"))
        source = text("scripts/verify_all.py")
        self.assertLess(source.index("TARGET = require_authorized_target()"), source.index("subprocess.run("))
        self.assertIn('"-scheme", TARGET.scheme', source)

    def test_legacy_e2e_is_blocked_before_imports_credentials_or_side_effects(self):
        # Inspect only; never execute the preserved live E2E scripts.
        for name in ["e2e-fcm-test.py", "ios_chaos_hprime.py"]:
            nodes = ast.parse(text("scripts/" + name)).body
            nodes = [n for n in nodes if not (isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant) and isinstance(n.value.value, str)) and not (isinstance(n, ast.ImportFrom) and n.module == "__future__")]
            self.assertIsInstance(nodes[0], ast.ImportFrom)
            self.assertEqual(nodes[0].module, "brand_test_target")
            self.assertEqual(ast.unparse(nodes[1]), "block_legacy_live_e2e()")
        with self.assertRaises(SystemExit) as raised:
            block_legacy_live_e2e()
        self.assertIn("BLOCKED", str(raised.exception))

    def test_test_target_brand_metadata_is_build_selected(self):
        configs = [v for v in self.objects.values() if v.get("isa") == "XCBuildConfiguration" and v["buildSettings"].get("TEST_TARGET_NAME") == "odoo"]
        self.assertEqual(len(configs), 4)
        for c in configs:
            apporo = c["name"].startswith("Apporo")
            self.assertEqual(c["buildSettings"]["INFOPLIST_KEY_TestAppDisplayName"], "Apporo platform" if apporo else "woowtech platform")
        self.assertIn('object(forInfoDictionaryKey: "TestAppDisplayName")', text("odooUITests/SharedTestConfig.swift"))


if __name__ == "__main__":
    unittest.main()
