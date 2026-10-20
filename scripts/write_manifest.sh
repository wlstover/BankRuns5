#!/bin/bash
# write_manifest.sh — the arm's manifest.csv on stdout (split out of run_all.sh, 2026-10-20).
#
# One row per array index, with the full parameter tuple, so consolidation and
# replay key on task_id and never parse positions (the 2026-04 failure). The
# switch columns come from scripts/switch_names.sh, i.e. from settings.jl, in
# SWITCH_DEFAULTS order after git_commit. Each holds the raw value exported by
# the submitting shell; empty means the default. fix_double_count is written
# resolved (true unless set) because its default changed on 2026-10-20 and an
# empty field in an older manifest means the published false (replay_run.jl).
# git_commit is the code the tasks will run (-dirty if uncommitted changes).
# Readers go by header name, so column order is not part of the format.
#
# Usage: write_manifest.sh PARAMS_FILE TAG ASSIGN_RULE MC_DEPTH SEED_OFFSET [PROJECT_ROOT]
set -euo pipefail

PARAMS_FILE="$1"; TAG="$2"; RULE="$3"; DEPTH="$4"; OFFSET="$5"
ROOT="${6:-${BANKRUN_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}"
HERE="$(cd "$(dirname "$0")" && pwd)"

sha=$(sha256sum "$PARAMS_FILE" | cut -c1-16)
ts=$(date -Is)
gc="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)$(git -C "$ROOT" diff --quiet HEAD 2>/dev/null || echo -dirty)"

header="task_id,reserve,depq,sigma,k,p,alpha,mu,lambdaI,lambdaC,arm_tag,assign_rule,mc_depth,seed_offset,params_sha,submitted_at,git_commit"
suffix="${TAG},${RULE},${DEPTH},${OFFSET},${sha},${ts},${gc}"
for n in $(BANKRUN_PROJECT_ROOT="$ROOT" bash "$HERE/switch_names.sh"); do
    var="BANKRUN_${n}"
    val="${!var:-}"
    [[ "$n" == "FIX_DOUBLE_COUNT" ]] && val="${val:-true}"
    if [[ "$val" == *,* ]]; then
        echo "write_manifest.sh: ${var}='${val}' contains a comma" >&2; exit 1
    fi
    header+=",${n,,}"
    suffix+=",${val}"
done

echo "$header"
awk -v s="$suffix" '{printf "%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", NR,$1,$2,$3,$4,$5,$6,$7,$8,$9,s}' "$PARAMS_FILE"
