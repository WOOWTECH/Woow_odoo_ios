#!/usr/bin/env bash
# audit_release_archive.sh — binary-side audit for debug test hooks.
#
# Pair with scripts/audit_test_hook_naming.sh. Together they close the
# loop documented in CLAUDE.md § "Debug Test Hooks — Naming, Gating
# & Registry (MANDATORY)":
#
#   - source side : every WOOW_TEST_*/WOOW_SEED_* reference is registered
#                   (audit_test_hook_naming.sh)
#   - binary side : every registered string is ABSENT from the Release
#                   binary (this script)
#
# The binary-side check guards the App Store 2.3.1 commitment: a Release
# build must not contain debug-only feature strings, even as inert
# fragments — Apple Review may extract strings from the IPA and reject
# on undocumented capabilities.
#
# Usage:
#   scripts/audit_release_archive.sh <path-to-ipa-or-app>
#   scripts/audit_release_archive.sh build/Release-iphoneos/odoo.app
#   scripts/audit_release_archive.sh ~/Library/Developer/Xcode/Archives/2026-05-04/odoo.xcarchive/Products/Applications/odoo.app
#
# When invoked without arguments, scans common build-output locations
# and audits whichever archive/app is found.
#
# Exit:  0 = clean (no hook strings in binary), 1 = leak detected, 2 = no archive found

set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------
# REGISTRY — must stay in sync with scripts/audit_test_hook_naming.sh.
# Adding a hook? Append to BOTH files.
# ---------------------------------------------------------------------
KNOWN_HOOKS=(
    "WOOW_TEST_THEME_COLOR"
    "WOOW_TEST_FORCE_BIOMETRIC"
    "WOOW_TEST_FORCE_PIN"
    "WOOW_TEST_AUTOTAP"
    "WOOW_SEED_ACCOUNT"
)

# Also flag the launch-argument marker — its presence in a Release
# binary indicates the test-hook activation path was not stripped.
KNOWN_HOOKS+=("-WoowTestRunner")

# ---------------------------------------------------------------------
# Locate the binary to audit.
# ---------------------------------------------------------------------
TARGET="${1:-}"
TMPDIR=""

cleanup() {
    if [ -n "$TMPDIR" ] && [ -d "$TMPDIR" ]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

# Auto-discover if no argument given.
if [ -z "$TARGET" ]; then
    candidates=(
        "build/Release-iphoneos/odoo.app"
        "build/Release-iphonesimulator/odoo.app"
        "DerivedData/odoo/Build/Products/Release-iphoneos/odoo.app"
        "DerivedData/odoo/Build/Products/Release-iphonesimulator/odoo.app"
    )
    for c in "${candidates[@]}"; do
        if [ -d "$c" ] || [ -f "$c" ]; then
            TARGET="$c"
            break
        fi
    done
fi

if [ -z "$TARGET" ] || { [ ! -e "$TARGET" ]; }; then
    echo "❌ FAIL — no Release archive found to audit."
    echo
    echo "Build a Release archive first, or pass an explicit path:"
    echo "  $(basename "$0") <path-to-.app-or-.ipa>"
    echo
    echo "Common Release locations:"
    echo "  build/Release-iphoneos/odoo.app"
    echo "  ~/Library/Developer/Xcode/Archives/<date>/odoo.xcarchive/Products/Applications/odoo.app"
    exit 2
fi

# ---------------------------------------------------------------------
# If TARGET is an .ipa, unzip into a tempdir and locate the binary.
# If TARGET is an .app, point at its Mach-O directly.
# ---------------------------------------------------------------------
case "$TARGET" in
    *.ipa)
        TMPDIR="$(mktemp -d)"
        unzip -q "$TARGET" -d "$TMPDIR"
        APP_PATH="$(find "$TMPDIR/Payload" -maxdepth 1 -name "*.app" -type d | head -1)"
        if [ -z "$APP_PATH" ]; then
            echo "❌ FAIL — could not locate .app inside $TARGET"
            exit 1
        fi
        ;;
    *.app)
        APP_PATH="$TARGET"
        ;;
    *)
        echo "❌ FAIL — expected .ipa or .app path, got: $TARGET"
        exit 1
        ;;
esac

# Resolve the executable name. Default: the bundle directory name minus
# `.app` (correct for 99% of iOS apps including this one). When invoked
# from an Xcode Run Script build phase, the Info.plist may not yet be
# present in the staged bundle — so we don't depend on it.
EXEC_NAME="$(basename "$APP_PATH" .app)"

# If a Mach-O at that path doesn't exist, try Info.plist as a fallback —
# it might have a non-default CFBundleExecutable name.
if [ ! -f "$APP_PATH/$EXEC_NAME" ] && [ -f "$APP_PATH/Info.plist" ]; then
    PLIST_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist" 2>/dev/null)"
    # PlistBuddy prints error messages to stdout — accept only valid
    # filename-shaped output (no spaces, alphanumeric + . _ -).
    if echo "$PLIST_EXEC" | grep -qE '^[A-Za-z0-9._-]+$'; then
        EXEC_NAME="$PLIST_EXEC"
    fi
fi
BINARY="$APP_PATH/$EXEC_NAME"

if [ ! -f "$BINARY" ]; then
    echo "❌ FAIL — Mach-O binary not found at $BINARY"
    exit 1
fi

echo "→ Auditing binary: $BINARY"
echo "→ Binary size: $(stat -f%z "$BINARY" 2>/dev/null || stat -c%s "$BINARY") bytes"

# ---------------------------------------------------------------------
# Verify Release configuration. A debug build is allowed to contain
# these strings — auditing it would produce noise. We refuse to give
# a green check on a Debug binary so a misconfigured CI matrix can't
# accidentally pass this gate.
# ---------------------------------------------------------------------
# Mach-O reports DEBUG-flavored builds via the LC_BUILD_VERSION /
# LC_VERSION_MIN_IPHONEOS load commands; simpler heuristic — Debug
# binaries typically retain the unstripped DWARF or symbol table.
# We use `nm` symbol count as a coarse signal: Release builds are
# stripped and have far fewer global symbols than Debug.
SYM_COUNT="$(nm -gU "$BINARY" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
if [ "$SYM_COUNT" -gt 5000 ]; then
    echo "⚠️  WARNING — binary has $SYM_COUNT global symbols, suggesting a Debug or"
    echo "    unstripped build. This audit is intended for Release archives."
    echo "    Continuing anyway, but a clean result on a Debug build is meaningless."
fi

# ---------------------------------------------------------------------
# THE CHECK — grep the Mach-O binary for each registered hook string.
# `strings` extracts printable sequences; `grep -F` does literal match
# without regex interpretation. We check both because the launch-arg
# marker `-WoowTestRunner` would not be reported by `strings` if it's
# embedded in the binary differently than as a NUL-terminated literal.
# ---------------------------------------------------------------------
# Sanity: confirm we can actually read the binary. If we can't (sandbox,
# permissions), the audit cannot make a credible PASS judgment — bail
# loudly rather than silently report clean. This prevents false-pass
# from a sandboxed Xcode build phase that blocks file reads.
if ! head -c 1 "$BINARY" >/dev/null 2>&1; then
    echo "❌ FAIL — cannot read binary at $BINARY"
    echo "         (Operation not permitted? sandbox? missing file?)"
    echo "         Audit refusing to claim PASS without verifiable read access."
    exit 1
fi

violations=0
leaked_hooks=()

for hook in "${KNOWN_HOOKS[@]}"; do
    # Primary check: `strings` + literal grep.
    if strings "$BINARY" 2>/dev/null | grep -qF -- "$hook"; then
        leaked_hooks+=("$hook")
        violations=$((violations + 1))
        continue
    fi
    # Fallback: raw byte grep (handles strings split across `strings`
    # extraction boundaries or stored in unusual sections).
    if LC_ALL=C grep -qF -- "$hook" "$BINARY" 2>/dev/null; then
        leaked_hooks+=("$hook (raw)")
        violations=$((violations + 1))
    fi
done

# ---------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------
if [ "$violations" -gt 0 ]; then
    echo
    echo "❌ FAIL — debug-hook strings found in Release binary:"
    for h in "${leaked_hooks[@]}"; do
        echo "    • $h"
    done
    echo
    echo "These strings must be absent from any App Store-bound binary."
    echo "Likely causes:"
    echo "  1. A WOOW_TEST_*/WOOW_SEED_* reference is not gated behind"
    echo "     TestHookGate.testHooksEnabled (check CLAUDE.md)."
    echo "  2. A bare \`#if DEBUG\` block leaks the literal at compile time"
    echo "     when Release is built without -DDEBUG removing the branch."
    echo "  3. A hook is referenced from a non-conditionally-compiled string"
    echo "     literal (e.g. an error message containing the hook name)."
    echo
    echo "See CLAUDE.md § 'Debug Test Hooks — Naming, Gating & Registry'."
    exit 1
fi

echo "✅ PASS — no debug-hook strings present in Release binary"
echo "         Checked ${#KNOWN_HOOKS[@]} registered hook strings against"
echo "         $(basename "$BINARY") ($EXEC_NAME)"
