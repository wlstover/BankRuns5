#!/bin/bash
# switch_names.sh — the BANKRUN_* switch names, read from settings.jl (2026-10-20).
#
# settings.jl's SWITCH_DEFAULTS is the one registry of model switches. Everything
# that has to list them (run_all.sh's untagged-arm guard, the manifest's switch
# columns via write_manifest.sh) reads them from here, so adding a switch is one
# line in SWITCH_DEFAULTS plus its parser entry, not an edit in four files.
#
# Usage:
#   scripts/switch_names.sh           # every switch, in SWITCH_DEFAULTS order
#   scripts/switch_names.sh --model   # only those that change the model
#                                     # (drops OUTPUT_ONLY_SWITCHES, e.g. LOG)
# Prints bare names (PUBLIC_ALPHA ...); the variable is BANKRUN_<NAME> and the
# manifest column is the lowercase name.
set -euo pipefail

SETTINGS="${BANKRUN_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/settings.jl"
[[ -f "$SETTINGS" ]] || { echo "switch_names.sh: $SETTINGS not found" >&2; exit 1; }

names=$(sed -n '/^const SWITCH_DEFAULTS = (/,/^)/p' "$SETTINGS" \
        | grep -oE '^[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]*=' | tr -d ' =')
[[ -n "$names" ]] || { echo "switch_names.sh: no SWITCH_DEFAULTS entries in $SETTINGS" >&2; exit 1; }

if [[ "${1:-}" == "--model" ]]; then
    output_only=$(grep -E '^const OUTPUT_ONLY_SWITCHES' "$SETTINGS" | grep -oE ':[A-Z][A-Z0-9_]*' | tr -d ':')
    for n in $names; do
        grep -qx "$n" <<< "$output_only" || echo "$n"
    done
else
    echo "$names"
fi
