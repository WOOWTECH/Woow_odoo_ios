#!/usr/bin/env bash
# audit_test_hook_naming.sh — source-side audit for debug test hooks.
#
# Enforces the rules in CLAUDE.md § "Debug Test Hooks — Naming, Gating
# & Registry (MANDATORY)":
#
#   1. Every WOOW_TEST_*/WOOW_SEED_* token in `odoo/` source MUST be in
#      the KNOWN_HOOKS array below. Adding a hook without registering
#      it here is the bug we are guarding against.
#   2. Every ProcessInfo env-var lookup whose key does NOT start with
#      one of the two allowed prefixes is flagged — ad-hoc names like
#      `ODOO_TUNNEL` or `DEBUG_X` violate the convention.
#
# A separate script `audit_release_archive.sh` runs at archive time and
# greps the SIGNED IPA for these same registered hooks; that script
# fails if any KNOWN_HOOKS string appears in the Release binary.
# Together the two scripts close the loop:
#   - source side : every hook is registered
#   - binary side : every registered hook is absent from Release
#
# Usage: scripts/audit_test_hook_naming.sh
# Exit:  0 = clean, 1 = violation found

set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------
# REGISTRY — the source of truth for which test hooks exist.
#
# Adding a new hook? Append it here AND in scripts/audit_release_archive.sh
# (or refactor both to source from a shared file). Per CLAUDE.md the
# audit-script update is part of the hook's checklist; PRs that miss it
# are blocked by this script's source-side check.
# ---------------------------------------------------------------------
KNOWN_HOOKS=(
    "WOOW_TEST_THEME_COLOR"
    "WOOW_TEST_FORCE_BIOMETRIC"
    "WOOW_TEST_FORCE_PIN"
    "WOOW_TEST_AUTOTAP"
    "WOOW_SEED_ACCOUNT"
)

violations=0

# ---------------------------------------------------------------------
# Check 1 — every WOOW_TEST_*/WOOW_SEED_* reference in source must be
# a registered hook. Catches "added a hook but forgot to register it".
# ---------------------------------------------------------------------
referenced=$(grep -rhoE 'WOOW_(TEST|SEED)_[A-Z_][A-Z0-9_]*' odoo/ \
    | sort -u || true)

for token in $referenced; do
    found=0
    for known in "${KNOWN_HOOKS[@]}"; do
        if [ "$token" = "$known" ]; then
            found=1
            break
        fi
    done
    if [ "$found" = "0" ]; then
        echo "❌ FAIL — unregistered hook found in source: $token"
        echo "         Add it to KNOWN_HOOKS in $(basename "$0")"
        echo "         AND in scripts/audit_release_archive.sh"
        violations=$((violations + 1))
    fi
done

# ---------------------------------------------------------------------
# Check 2 — every ProcessInfo env-var lookup must use one of the two
# allowed prefixes. Catches non-conforming names like ODOO_TUNNEL,
# DEBUG_X, INTERNAL_FOO.
# ---------------------------------------------------------------------
nonconforming=$(grep -rhnE 'ProcessInfo\.processInfo\.environment\["[^"]+"\]' odoo/ \
    | grep -vE 'environment\["WOOW_(TEST|SEED)_' \
    || true)

if [ -n "$nonconforming" ]; then
    echo "❌ FAIL — env-var lookup with non-conforming prefix:"
    echo "$nonconforming"
    echo
    echo "Debug-only env vars MUST start with WOOW_TEST_ or WOOW_SEED_."
    echo "See CLAUDE.md § 'Debug Test Hooks — Naming, Gating & Registry'."
    violations=$((violations + 1))
fi

# Same check for the `env[...]` pattern (after `let env = ProcessInfo...`)
nonconforming_env=$(grep -rhnE '[^a-zA-Z_]env\["[^"]+"\]' odoo/ \
    | grep -vE 'env\["WOOW_(TEST|SEED)_' \
    || true)

if [ -n "$nonconforming_env" ]; then
    echo "❌ FAIL — env[...] lookup with non-conforming prefix:"
    echo "$nonconforming_env"
    violations=$((violations + 1))
fi

# ---------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------
if [ "$violations" -gt 0 ]; then
    echo
    echo "Found $violations violation(s). Refer to CLAUDE.md for the rule."
    exit 1
fi

echo "✅ PASS — all test hooks are registered and conform to naming convention"
echo "         Registered hooks (${#KNOWN_HOOKS[@]}): ${KNOWN_HOOKS[*]}"
