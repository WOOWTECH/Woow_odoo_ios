"""Offline binary-audit regressions for scripts/audit_release_archive.sh.

Fixtures only: tiny Mach-O executables compiled into a temp dir (skipped when
no clang is available) plus fake otool/nm on PATH for failure injection. No
Xcode project build, archive, signing, device or network.

Run: python3 -B -m unittest discover -s scripts/tests -p test_audit_release_archive.py -v
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/audit_release_archive.sh"
SOURCE = "int twice(int x) { return x * 2; }\nint main(void) { return twice(1) - 2; }\n"


def clang_available():
    try:
        return subprocess.run(["/usr/bin/xcrun", "--find", "clang"], capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


HAS_CLANG = clang_available()


class ReleaseArchiveAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-audit-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / "odoo.app"
        self.app.mkdir()
        self.binary = self.app / "odoo"

    def compile(self, *flags, strip=False):
        source = self.root / "main.c"
        source.write_text(SOURCE)
        subprocess.run(["/usr/bin/xcrun", "clang", *flags, str(source), "-o", str(self.binary)],
                       check=True, capture_output=True, timeout=120)
        if strip:
            subprocess.run(["/usr/bin/xcrun", "strip", str(self.binary)], check=True, capture_output=True, timeout=60)

    def run_audit(self, env=None):
        return subprocess.run(["/bin/bash", str(SCRIPT), str(self.app)],
                              capture_output=True, text=True, env=env, timeout=60)

    def fake_tool(self, name, body, env=None):
        bindir = self.root / "bin"
        bindir.mkdir(exist_ok=True)
        path = bindir / name
        path.write_text("#!/bin/bash\n" + body)
        path.chmod(0o755)
        env = dict(env or os.environ)
        env["PATH"] = str(bindir) + ":/usr/bin:/bin"
        return env

    def assert_rejected(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn("PASS", result.stdout + result.stderr)

    # -- real Mach-O fixtures ------------------------------------------------

    @unittest.skipUnless(HAS_CLANG, "xcrun clang required to build Mach-O fixtures")
    def test_uninstrumented_binary_passes(self):
        self.compile()
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS", result.stdout)
        self.assertIn("no coverage instrumentation", result.stdout)
        self.assertNotIn("coverage instrumentation found", result.stdout)
        self.assertNotIn("• section", result.stdout)

    @unittest.skipUnless(HAS_CLANG, "xcrun clang required to build Mach-O fixtures")
    def test_coverage_instrumented_binary_fails_and_names_hits(self):
        self.compile("-fprofile-instr-generate", "-fcoverage-mapping")
        result = self.run_audit()
        self.assert_rejected(result)
        self.assertIn("coverage instrumentation", result.stdout)
        for section in ("__llvm_prf_cnts", "__llvm_prf_data", "__llvm_covmap"):
            self.assertIn(section, result.stdout)
        self.assertIn("___llvm_profile_", result.stdout)

    @unittest.skipUnless(HAS_CLANG, "xcrun clang required to build Mach-O fixtures")
    def test_stripped_instrumented_binary_still_fails_on_sections(self):
        # strip removes the local ___profc_/___llvm_profile_* symbols, but the
        # sections survive; a symbol-only check would false-pass here.
        self.compile("-fprofile-instr-generate", "-fcoverage-mapping", strip=True)
        result = self.run_audit()
        self.assert_rejected(result)
        self.assertIn("__llvm_prf_cnts", result.stdout)
        self.assertIn("__llvm_covmap", result.stdout)

    # -- fake tools (no compiler needed) ------------------------------------

    def fake_macho(self):
        self.binary.write_bytes(b"\xcf\xfa\xed\xfe fake mach-o placeholder\n")

    CLEAN_OTOOL = ('echo "$2:"\necho "Load command 0"\necho "      cmd LC_SEGMENT_64"\n'
                   'echo "  sectname __text"\necho "   segname __TEXT"\n')
    CLEAN_NM = ('echo "0000000100000000 (__TEXT,__text) [referenced dynamically] external __mh_execute_header"\n'
                'echo "0000000100000328 (__TEXT,__text) external _main"\n')

    def test_stubbed_coverage_sections_and_symbols_are_reported(self):
        self.fake_macho()
        env = self.fake_tool("otool", self.CLEAN_OTOOL + 'echo "  sectname __llvm_prf_cnts"\necho "  sectname __llvm_covfun"\n')
        env = self.fake_tool("nm", self.CLEAN_NM
                             + 'echo "00000001001a99e0 (__DATA,__llvm_prf_cnts) non-external ___profc_main"\n'
                             + 'echo "000000010010f120 (__TEXT,__text) non-external (was a private external) ___llvm_profile_begin_counters"\n', env)
        result = self.run_audit(env)
        self.assert_rejected(result)
        for line in ("• section __llvm_prf_cnts", "• section __llvm_covfun", "• symbol ___profc_main",
                     "• symbol ___llvm_profile_begin_counters"):
            self.assertIn(line + "\n", result.stdout)

    def test_stubbed_clean_tools_pass(self):
        self.fake_macho()
        env = self.fake_tool("otool", self.CLEAN_OTOOL)
        env = self.fake_tool("nm", self.CLEAN_NM, env)
        result = self.run_audit(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no coverage instrumentation", result.stdout)

    def test_large_clean_otool_output_passes(self):
        # Real app binaries print thousands of load-command lines; an early
        # exiting `grep -q` in a pipeline SIGPIPEs the writer and, under
        # pipefail, misreports "no load commands" (seen on the real odoo.app).
        self.fake_macho()
        env = self.fake_tool("otool", self.CLEAN_OTOOL
                             + 'for i in $(seq 1 20000); do echo "  sectname __const_$i"; done\n')
        env = self.fake_tool("nm", self.CLEAN_NM, env)
        result = self.run_audit(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no coverage instrumentation", result.stdout)

    def test_otool_failure_fails_closed(self):
        self.fake_macho()
        env = self.fake_tool("otool", 'echo "synthetic otool failure" >&2\nexit 1\n')
        env = self.fake_tool("nm", self.CLEAN_NM, env)
        result = self.run_audit(env)
        self.assert_rejected(result)
        self.assertIn("synthetic otool failure", result.stderr)

    def test_otool_without_load_commands_fails_closed(self):
        # Real otool exits 0 with "is not an object file" for non-Mach-O input.
        self.fake_macho()
        env = self.fake_tool("otool", 'echo "$2: is not an object file"\n')
        env = self.fake_tool("nm", self.CLEAN_NM, env)
        self.assert_rejected(self.run_audit(env))

    def test_nm_failure_fails_closed(self):
        self.fake_macho()
        env = self.fake_tool("otool", self.CLEAN_OTOOL)
        env = self.fake_tool("nm", 'echo "synthetic nm failure" >&2\nexit 1\n', env)
        result = self.run_audit(env)
        self.assert_rejected(result)
        self.assertIn("synthetic nm failure", result.stderr)


if __name__ == "__main__":
    unittest.main()
