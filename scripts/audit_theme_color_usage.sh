#!/usr/bin/env bash
# audit_theme_color_usage.sh — fail if any user-visible UI file in
# `odoo/UI/` uses a STATIC brand color reference instead of observing
# `WoowTheme.shared.primaryColor`.
#
# Why: static brand constants in `WoowColors` are seed values for
# `WoowTheme`. Using them directly in a view bypasses the user's
# theme-color preference (UX-48) — the same silent regression that bit
# us on 2026-04-28 (see `docs/2026-04-28-theme-color-not-applied-plan.md`).
#
# What this catches (per the adversarial review):
#   * `WoowColors.primaryBlue`   — the original culprit
#   * `WoowColors.<anyOther>`    — future brand additions (primaryGreen, etc.)
#   * `Color("primaryBlue")`     — asset-catalog references that bypass the theme
#
# What this allows:
#   * `odoo/UI/Theme/WoowColors.swift`  — the constants live here
#   * `odoo/UI/Theme/WoowTheme.swift`   — references the default
#   * any `*Test*` / `*Preview*` file   — test fixtures may use constants
#   * comment-only lines                — historical references, OK
#
# Usage: scripts/audit_theme_color_usage.sh
# Exit:  0 = clean, 1 = violation found

set -euo pipefail

cd "$(dirname "$0")/.."

# Match either pattern:
#   WoowColors.<identifier>
#   Color("<identifier>")
# Both forms can return a static brand color that bypasses the theme.
patterns='WoowColors\.[A-Za-z][A-Za-z0-9]*|Color\("[A-Za-z][A-Za-z0-9]*"\)'

violations=$(git grep -nE "$patterns" -- 'odoo/UI/' \
    | grep -v '^odoo/UI/Theme/WoowColors\.swift:' \
    | grep -v '^odoo/UI/Theme/WoowTheme\.swift:' \
    | grep -v 'Test\.swift:' \
    | grep -v '/Preview' \
    | grep -vE '^[^:]+:[0-9]+:\s*//' \
    | grep -v 'WoowColors\.brandColors' \
    | grep -v 'WoowColors\.accentColors' \
    || true)
# `WoowColors.brandColors` and `accentColors` are arrays consumed by
# the color picker itself (`ColorPickerView`) to display the palette
# of choices to the user — not theme-bypassing single-color references.
# Allowlisted explicitly so the audit can't falsely flag the legitimate
# picker UI.

if [ -n "$violations" ]; then
    echo "❌ FAIL — static brand color hardcoded in user-visible UI:"
    echo
    echo "$violations"
    echo
    echo "Replace with:"
    echo "  @ObservedObject private var theme = WoowTheme.shared"
    echo "  ...theme.primaryColor"
    echo
    echo "Or, if a non-themed accent is genuinely needed (e.g. error-state"
    echo "red), add the file to the allowlist in this script and document why."
    echo
    echo "See docs/2026-04-28-theme-color-not-applied-plan.md"
    exit 1
fi

echo "✅ PASS — no user-visible UI hardcodes a static brand color"
