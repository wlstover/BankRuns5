#!/usr/bin/env bash
# test_restart_manifest.sh — run_all.sh --restart takes the arm from its manifest (2026-10-21).
#
# Before this fix --restart skipped the manifest block that --tasks runs, so a
# top-up from a clean shell ran the published model under an arm whose manifest
# recorded, e.g., BANKRUN_PRIVATE_SIGNAL=shock. Checks, all with --dry-run (no
# SLURM needed):
#   1  clean shell: --restart prints the manifest's settings and the sweep sbatch
#   2  a conflicting BANKRUN_* in the shell is refused
#   3  a manifest from another commit is refused
#
# Needs a clean checkout (the manifest's commit must be HEAD); tests/run_tests.sh
# reports it SKIPPED otherwise. Writes a throwaway arm under outputs/ and removes it.
#
# Run:  bash tests/test_restart_manifest.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! git -C "$ROOT" diff --quiet HEAD; then
    echo "SKIP: uncommitted changes; the manifest commit cannot equal a clean HEAD"; exit 2
fi
HEAD_SHORT="$(git -C "$ROOT" rev-parse --short HEAD)"
TAG="_test_restart_$$"
ARM="${ROOT}/outputs/${TAG}"
trap 'rm -rf "$ARM"' EXIT
mkdir -p "$ARM"
echo "0.30 0.0 2.0 6 0.05 0.1 0.5 0.1 0.9" > "$ARM/params.txt"

manifest() {   # manifest <git_commit>
    cat > "$ARM/manifest.csv" <<EOF
task_id,reserve,depq,sigma,k,p,alpha,mu,lambdaI,lambdaC,arm_tag,assign_rule,mc_depth,seed_offset,params_sha,submitted_at,git_commit,public_alpha,public_bias,public_rho,weight_phi,fix_double_count,fresh_clone,tiebreak,belief,belief_p0,public_mode,public_refresh,private_signal,private_noise,stay_return,log
1,0.30,0.0,2.0,6,0.05,0.1,0.5,0.1,0.9,${TAG},random,250,2000,x,now,$1,,,,,true,true,,,,,,shock,5,,summary
EOF
}

PASS=0; FAIL=0
check() { if eval "$2"; then echo "  ok    $1"; PASS=$((PASS+1)); else echo "  FAIL  $1"; echo "$OUT" | tail -5 | sed 's/^/        /'; FAIL=$((FAIL+1)); fi; }
run() { OUT="$(env -i PATH="$PATH" HOME="$HOME" BANKRUN_PROJECT_ROOT="$ROOT" "$@" \
               bash "$ROOT/scripts/run_all.sh" --tag "$TAG" --restart --dry-run 2>&1)"; RC=$?; }

echo "1  clean shell"
manifest "$HEAD_SHORT"
run
check "exit 0" '[[ $RC -eq 0 ]]'
check "settings line from the manifest" \
    '[[ "$OUT" == *"--restart: settings from manifest (commit ${HEAD_SHORT}, assign random, depth 250, seed offset 2000)"* ]]'
# the dry-run echo is printf %q, which escapes the commas in --export
check "sweep sbatch carries them" \
    '[[ "${OUT//\\/}" == *"BANKRUN_ASSIGN_RULE=random,BANKRUN_MC_DEPTH=250,SEED_OFFSET=2000"* ]]'

echo "2  conflicting switch in the shell"
run BANKRUN_PRIVATE_SIGNAL=none
check "refused" '[[ $RC -ne 0 && "$OUT" == *"BANKRUN_PRIVATE_SIGNAL=none in this shell, but the arm ran with '"'"'shock'"'"'"* ]]'

echo "3  manifest from another commit"
manifest 0000000
run
check "refused" '[[ $RC -ne 0 && "$OUT" == *"the arm ran at 0000000"* ]]'

echo ""
echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
