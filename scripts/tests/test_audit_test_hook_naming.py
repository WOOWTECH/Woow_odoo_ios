"""Offline source-audit regressions; fixtures only, no Xcode or product writes.

Run: python3 -B -m unittest discover -s scripts/tests -p test_audit_test_hook_naming.py -v
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/audit_test_hook_naming.sh"
INPUTS = ROOT / "scripts/test_hook_audit_inputs.xcfilelist"


class SourceAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="source-audit-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts/audit_test_hook_naming.sh"
        shutil.copyfile(SCRIPT, self.script)
        (self.root / "odoo").mkdir()

    def source(self, name, text):
        path = self.root / "odoo" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def run_audit(self, prefix=(), env=None):
        return subprocess.run([*prefix, "/bin/bash", str(self.script)],
                              capture_output=True, text=True, env=env, timeout=10)

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("PASS", result.stdout + result.stderr)

    def test_clean_no_matches(self):
        self.source("Clean.swift", "let value = 1\n")
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS", result.stdout)
        self.assertEqual(result.stderr, "")

    def test_empty_existing_source(self):
        self.assertEqual(self.run_audit().returncode, 0)

    def test_registered_hooks(self):
        self.source("Nested/Legal.swift", 'let x = ProcessInfo.processInfo.environment["WOOW_TEST_FORCE_PIN"]\nlet y = env["WOOW_SEED_ACCOUNT"]\n')
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS", result.stdout)

    def test_unregistered_hook(self):
        self.source("Unknown.swift", 'let x = "WOOW_TEST_UNREGISTERED"\n')
        result = self.run_audit()
        self.assert_rejected(result)
        self.assertIn("unregistered", result.stdout)

    def test_nonconforming_prefix(self):
        for lookup in ['ProcessInfo.processInfo.environment["DEBUG_X"]', 'env["ODOO_TUNNEL"]']:
            with self.subTest(lookup=lookup):
                self.source("Bad.swift", "let x = " + lookup + "\n")
                result = self.run_audit()
                self.assert_rejected(result)
                self.assertIn("non-conforming", result.stdout)

    def test_missing_source_root(self):
        (self.root / "odoo").rmdir()
        self.assert_rejected(self.run_audit())

    def test_source_root_is_file(self):
        (self.root / "odoo").rmdir()
        (self.root / "odoo").write_text("not a source directory")
        self.assert_rejected(self.run_audit())

    def fake_tool(self, name, body):
        bindir = self.root / "bin"
        bindir.mkdir(exist_ok=True)
        path = bindir / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)
        return dict(os.environ, PATH=str(bindir) + ":/usr/bin:/bin", AUDIT_TEST_COUNTER=str(self.root / "counter"))

    def test_grep_errors_at_each_scan_and_filter(self):
        self.source("Legal.swift", 'let x = ProcessInfo.processInfo.environment["WOOW_TEST_FORCE_PIN"]\nlet y = env["WOOW_SEED_ACCOUNT"]\n')
        for status in (2, 127):
            for invocation in range(1, 6):
                with self.subTest(status=status, invocation=invocation):
                    (self.root / "counter").write_text("0")
                    env = self.fake_tool("grep", 'read -r n < "$AUDIT_TEST_COUNTER"\nn=$((n + 1))\necho "$n" > "$AUDIT_TEST_COUNTER"\n'
                                         + f'if [ "$n" = {invocation} ]; then echo "synthetic grep failure" >&2; exit {status}; fi\n'
                                         + 'exec /usr/bin/grep "$@"\n')
                    result = self.run_audit(env=env)
                    self.assert_rejected(result)
                    self.assertIn("synthetic grep failure", result.stderr)

    def test_sort_tool_failure(self):
        self.source("Clean.swift", "let value = 1\n")
        result = self.run_audit(env=self.fake_tool("sort", 'echo "synthetic sort failure" >&2\nexit 2\n'))
        self.assert_rejected(result)
        self.assertIn("synthetic sort failure", result.stderr)

    @unittest.skipUnless(Path("/usr/bin/sandbox-exec").exists(), "macOS sandbox required")
    def test_permission_and_partial_read_failures(self):
        readable = self.source("Readable.swift", 'let x = "WOOW_TEST_FORCE_PIN"\n')
        unreadable = self.source("Nested/Unreadable.swift", "let value = 1\n")
        for denied in (readable, unreadable, unreadable.parent):
            with self.subTest(denied=denied.name):
                profile = '(version 1)(allow default)(deny file-read* (subpath ' + json.dumps(str(denied)) + '))'
                result = self.run_audit(["/usr/bin/sandbox-exec", "-p", profile])
                self.assert_rejected(result)
                self.assertIn("Operation not permitted", result.stderr)

    @unittest.skipUnless(Path("/usr/bin/sandbox-exec").exists(), "macOS sandbox required")
    def test_literal_xcode_inputs_cover_tree_and_reject_undeclared_sources(self):
        self.source("Nested/Legal.swift", 'let x = "WOOW_TEST_FORCE_PIN"\n')
        declared = [self.root, self.root / "scripts", self.script, self.root / "odoo", *sorted((self.root / "odoo").rglob("*"))]
        profile = '(version 1)(allow default)(deny file-read* (subpath ' + json.dumps(str(self.root)) + '))'
        profile += ''.join('(allow file-read* (literal ' + json.dumps(str(p)) + '))' for p in declared)
        prefix = ["/usr/bin/sandbox-exec", "-p", profile]
        result = self.run_audit(prefix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS", result.stdout)
        for name in ("Nested/Added.swift", "NewDirectory/Added.swift"):
            with self.subTest(name=name):
                added = self.source(name, "let x = 1\n")
                self.assert_rejected(self.run_audit(prefix))
                added.unlink()


class SourceAuditInputTests(unittest.TestCase):
    def test_xcode_inputs_cover_every_source_entry_without_widening(self):
        # Maintenance gate: includes resources/hidden files, not just *.swift.
        # os.walk must raise on traversal failure rather than silently omit it.
        def fail(error):
            raise error
        expected = {"$(SRCROOT)/odoo"}
        for directory, dirs, files in os.walk(ROOT / "odoo", onerror=fail):
            for name in dirs + files:
                expected.add("$(SRCROOT)/" + str((Path(directory) / name).relative_to(ROOT)))
        entries = [line for line in INPUTS.read_text().splitlines() if line and not line.startswith("#")]
        self.assertEqual(len(entries), len(set(entries)), "duplicate input")
        self.assertEqual(set(entries), expected, "Update test_hook_audit_inputs.xcfilelist when odoo/ entries change")

    def test_project_wires_list_and_keeps_sandbox_and_binary_gate(self):
        result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(ROOT / "odoo.xcodeproj/project.pbxproj")], capture_output=True, check=True)
        objects = json.loads(result.stdout)["objects"]
        phase = next(v for v in objects.values() if v.get("name") == "Audit debug-hook leaks (Release)")
        self.assertEqual(phase["inputFileListPaths"], ["$(SRCROOT)/scripts/test_hook_audit_inputs.xcfilelist"])
        self.assertIn('audit_test_hook_naming.sh" || exit $?', phase["shellScript"])
        self.assertIn('"$SRCROOT/scripts/audit_release_archive.sh" "$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"', phase["shellScript"])
        self.assertIn("$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/$(PRODUCT_NAME)", phase["inputPaths"])
        settings = [v["buildSettings"] for v in objects.values() if v.get("isa") == "XCBuildConfiguration"]
        self.assertEqual([s["ENABLE_USER_SCRIPT_SANDBOXING"] for s in settings if "ENABLE_USER_SCRIPT_SANDBOXING" in s], ["YES"] * 4)


if __name__ == "__main__":
    unittest.main()
