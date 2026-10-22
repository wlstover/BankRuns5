#!/usr/bin/env bash
# CARA smoke (2026-10-22): scripts/cara_smoke.jl at each CARA value, in parallel,
# with the rung-1 reference switches (arms/rung1_partial.tsv r1p-none).
#   bash scripts/cara_smoke.sh [reps] [cara values...]
#   bash scripts/cara_smoke.sh 10 0 0.01 0.1 1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPS="${1:-10}"; shift || true
if [[ $# -gt 0 ]]; then VALUES=("$@"); else VALUES=(0 0.01 0.1 1); fi
JULIA="${JULIA:-julia}"
export BANKRUN_FRESH_CLONE=true BANKRUN_LOG=summary BANKRUN_BALANCE=firesale BANKRUN_PAYOFF=recovery \
       BANKRUN_FUNDAMENTAL=theta BANKRUN_FIRE_DISCOUNT=0.6 BANKRUN_EQUITY=0.06 BANKRUN_RETURN_LO=1.0 \
       BANKRUN_RETURN_HI=1.4 BANKRUN_STAY_RETURN=1.1 BANKRUN_PRIVATE_SIGNAL=theta BANKRUN_THETA_NOISE=0.10 \
       BANKRUN_THETA_PUBLIC_NOISE=0.10 BANKRUN_LAMBDA_SCOPE=both BANKRUN_WITHDRAW=partial
mkdir -p "$ROOT/outputs/cara_smoke"
for g in "${VALUES[@]}"; do
    BANKRUN_CARA="$g" CARA_SMOKE_REPS="$REPS" CARA_SMOKE_OUT="$ROOT/outputs/cara_smoke/g$g" \
        "$JULIA" --project="$ROOT" "$ROOT/scripts/cara_smoke.jl" > "$ROOT/outputs/cara_smoke/g$g.log" 2>&1 &
done
wait
echo "done: outputs/cara_smoke/g*/ (summary: python3 scripts/cara_smoke.py)"
