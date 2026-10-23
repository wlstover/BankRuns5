#!/bin/bash
# =============================================================================
# sweep_task.slurm — array-task payload for the BankRuns5 sweep.
#
# NOT meant to be submitted by hand. run_all.sh submits it, computing the array
# range from the params file and threading everything else through --export.
# Submitting it directly will fail the guard below, on purpose: the previous
# version of this file (sweep.slurm) carried a hardcoded --array=1-2160 and a
# hardcoded params path, which is exactly the coupling this split removes.
#
# Expected environment (all set by run_all.sh --export):
#   PROJECT_ROOT           BankRuns5 root on HPC
#   PARAMS_FILE            absolute path to the arm's params file
#   ARM_DIR                absolute path to the arm's output root
#   ARM_TAG                arm name (for logging)
#   BANKRUN_ASSIGN_RULE    warmup | random | reverse (parsed in finMain0001.jl, used in functions4.jl modelGen)
#   BANKRUN_MC_DEPTH       Monte Carlo draws per agent decision (finMain0001.jl)
#   SEED_OFFSET            added to the array index to form GEN_SEED
#
# One task = one parameter combination = 50 model runs (5 seeds x 10 iterations,
# set in parameterGen.jl). Each task writes into its own directory because
# finMain0001.jl writes per-worker CSVs (bankRunResults2.csv, agents2.csv, …)
# whose names collide across tasks otherwise.
# =============================================================================

#SBATCH --job-name=bankrun-sweep
#SBATCH --partition=normal
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G
#SBATCH --export=ALL

set -euo pipefail

: "${PROJECT_ROOT:?sweep_task.slurm must be submitted via run_all.sh (PROJECT_ROOT unset)}"
: "${PARAMS_FILE:?PARAMS_FILE not set — submit via run_all.sh}"
: "${ARM_DIR:?ARM_DIR not set — submit via run_all.sh}"
ARM_TAG="${ARM_TAG:-unknown}"
BANKRUN_ASSIGN_RULE="${BANKRUN_ASSIGN_RULE:-warmup}"
BANKRUN_MC_DEPTH="${BANKRUN_MC_DEPTH:-100}"
SEED_OFFSET="${SEED_OFFSET:-1000}"

export BANKRUN_ASSIGN_RULE   # read by finMain0001.jl -> functions4.jl modelGen
export BANKRUN_MC_DEPTH      # read by finMain0001.jl, broadcast to workers
# Public-signal switches (Level 1, 2026-10-08; see finMain0001.jl). Unset or
# empty = the published model. They reach this script through --export=ALL, so
# set them in the submitting shell. run_all.sh records their raw values in the
# manifest (2026-10-15); a non-default run also writes bankRunPublicParams<core>.csv
# and, for the tie-break / belief switches, bankRunDecisionParams<core>.csv.
export BANKRUN_PUBLIC_ALPHA="${BANKRUN_PUBLIC_ALPHA:-}"
export BANKRUN_PUBLIC_BIAS="${BANKRUN_PUBLIC_BIAS:-}"
export BANKRUN_PUBLIC_RHO="${BANKRUN_PUBLIC_RHO:-}"
export BANKRUN_WEIGHT_PHI="${BANKRUN_WEIGHT_PHI:-}"
export BANKRUN_FIX_DOUBLE_COUNT="${BANKRUN_FIX_DOUBLE_COUNT:-}"
export BANKRUN_FRESH_CLONE="${BANKRUN_FRESH_CLONE:-}"
export BANKRUN_TIEBREAK="${BANKRUN_TIEBREAK:-}"     # schuler-sync (settings.jl)
export BANKRUN_BELIEF="${BANKRUN_BELIEF:-}"
export BANKRUN_BELIEF_P0="${BANKRUN_BELIEF_P0:-}"
export BANKRUN_LOG="${BANKRUN_LOG:-}"           # full | summary (2026-10-15)
export BANKRUN_PUBLIC_MODE="${BANKRUN_PUBLIC_MODE:-}"         # markup | stale (2026-10-20)
export BANKRUN_PUBLIC_REFRESH="${BANKRUN_PUBLIC_REFRESH:-}"
export BANKRUN_PRIVATE_SIGNAL="${BANKRUN_PRIVATE_SIGNAL:-}"   # none | shock (2026-10-20)
export BANKRUN_STAY_RETURN="${BANKRUN_STAY_RETURN:-}"         # R >= 1 (2026-10-20)
# Balance sheet and fundamental (2026-10-21)
export BANKRUN_PAYOFF="${BANKRUN_PAYOFF:-}"                   # full | recovery
export BANKRUN_BALANCE="${BANKRUN_BALANCE:-}"                 # vault | firesale
export BANKRUN_FIRE_DISCOUNT="${BANKRUN_FIRE_DISCOUNT:-}"
export BANKRUN_EQUITY="${BANKRUN_EQUITY:-}"
export BANKRUN_FUNDAMENTAL="${BANKRUN_FUNDAMENTAL:-}"         # none | theta
export BANKRUN_RETURN_LO="${BANKRUN_RETURN_LO:-}"
export BANKRUN_RETURN_HI="${BANKRUN_RETURN_HI:-}"
export BANKRUN_THETA_NOISE="${BANKRUN_THETA_NOISE:-}"
export BANKRUN_PRIVATE_NOISE="${BANKRUN_PRIVATE_NOISE:-}"
# Public signal of theta and the scope of lambda (2026-10-22)
export BANKRUN_THETA_PUBLIC="${BANKRUN_THETA_PUBLIC:-}"       # none | stale | tracks
export BANKRUN_THETA_PUBLIC_LEVEL="${BANKRUN_THETA_PUBLIC_LEVEL:-}"
export BANKRUN_THETA_PUBLIC_GAP="${BANKRUN_THETA_PUBLIC_GAP:-}"
export BANKRUN_THETA_PUBLIC_RHO="${BANKRUN_THETA_PUBLIC_RHO:-}"
export BANKRUN_THETA_PUBLIC_NOISE="${BANKRUN_THETA_PUBLIC_NOISE:-}"
export BANKRUN_LAMBDA_SCOPE="${BANKRUN_LAMBDA_SCOPE:-}"       # count | theta | both
export BANKRUN_SEEDING="${BANKRUN_SEEDING:-}"                 # task | common (2026-10-22)
export BANKRUN_N_INIT="${BANKRUN_N_INIT:-}"                   # 1 | 5 | 25
export BANKRUN_WITHDRAW="${BANKRUN_WITHDRAW:-}"               # all | partial (2026-10-22)
export BANKRUN_PARTIAL_MIN_SHARE="${BANKRUN_PARTIAL_MIN_SHARE:-}"
export BANKRUN_PARTIAL_STEPS="${BANKRUN_PARTIAL_STEPS:-}"         # grid step 1/n (2026-10-23)
export BANKRUN_DEPOSIT_CAP="${BANKRUN_DEPOSIT_CAP:-}"             # 0 = none | c = largest share cap (2026-10-23)
export BANKRUN_CARA="${BANKRUN_CARA:-}"                       # 0 = risk neutral | > 0 CARA (2026-10-22)

module load julia/1.8.0

# Fail fast if the loaded Julia does not match the Manifest that pins this
# project's dependency versions. On 2026-08-13 the tracked Manifest had been
# resolved under Julia 1.12.5 while this script loads 1.8.0; its JLD2 stack
# (ChunkCodecCore et al.) requires Julia >= 1.10 and cannot resolve here. That
# mismatch is invisible until a task actually tries to load a package, so it
# surfaces as a per-task failure deep in an array job rather than at submission.
# One comparison at startup turns it into a one-line message.
manifest_julia=$(sed -n 's/^julia_version = "\(.*\)"/\1/p' "${PROJECT_ROOT}/Manifest.toml" | head -1)
loaded_julia=$(julia --version 2>/dev/null | awk '{print $3}')
if [[ -z "$manifest_julia" || -z "$loaded_julia" ]]; then
    echo "ERROR: could not determine Julia version (manifest='${manifest_julia}' loaded='${loaded_julia}')" >&2
    exit 1
fi
if [[ "$manifest_julia" != "$loaded_julia" ]]; then
    echo "ERROR: Julia version mismatch — Manifest.toml pins ${manifest_julia}, module provides ${loaded_julia}." >&2
    echo "       Re-resolve the Manifest under ${loaded_julia}, or load the matching module." >&2
    exit 1
fi
echo "julia ${loaded_julia} matches Manifest pin"

TASK_DIR="${ARM_DIR}/task_${SLURM_ARRAY_TASK_ID}"
mkdir -p "$TASK_DIR"

# GEN_SEED must be unique per task. It seeds parameterGen.jl's RNG, which draws
# seed1/seed2 for the 50 runs; colliding GEN_SEEDs across arms would make the
# arms share draws and stop being independent replications.
# BANKRUN_SEEDING=common (2026-10-22): the same GEN_SEED in every task, so every
# cell of the arm runs the same banks (parameterGen.jl draws the seeds from their
# own stream). Arms compared with each other still differ by SEED_OFFSET.
if [[ "${BANKRUN_SEEDING:-task}" == "common" ]]; then
    GEN_SEED=$SEED_OFFSET
else
    GEN_SEED=$((SEED_OFFSET + SLURM_ARRAY_TASK_ID))
fi

read -r reserve depq sigma k p alpha mu lambdaI lambdaC \
    < <(sed -n "${SLURM_ARRAY_TASK_ID}p" "$PARAMS_FILE")

if [[ -z "${lambdaC:-}" ]]; then
    echo "ERROR: params line ${SLURM_ARRAY_TASK_ID} of ${PARAMS_FILE} is short or missing" >&2
    exit 1
fi

echo "======================================================================"
echo "arm=${ARM_TAG}  task=${SLURM_ARRAY_TASK_ID}  assign=${BANKRUN_ASSIGN_RULE}  mcDepth=${BANKRUN_MC_DEPTH}"
echo "public: alpha=${BANKRUN_PUBLIC_ALPHA:-0} bias=${BANKRUN_PUBLIC_BIAS:-0} rho=${BANKRUN_PUBLIC_RHO:-1} phi=${BANKRUN_WEIGHT_PHI:-1} fixDoubleCount=${BANKRUN_FIX_DOUBLE_COUNT:-true} freshClone=${BANKRUN_FRESH_CLONE:-false}"
echo "decision: tiebreak=${BANKRUN_TIEBREAK:-legacy} belief=${BANKRUN_BELIEF:-geometric} beliefP0=${BANKRUN_BELIEF_P0:-0.02} log=${BANKRUN_LOG:-full}"
echo "signals: publicMode=${BANKRUN_PUBLIC_MODE:-markup} publicRefresh=${BANKRUN_PUBLIC_REFRESH:-0} privateSignal=${BANKRUN_PRIVATE_SIGNAL:-none} privateNoise=${BANKRUN_PRIVATE_NOISE:-5} stayReturn=${BANKRUN_STAY_RETURN:-1}"
echo "balance: payoff=${BANKRUN_PAYOFF:-full} balance=${BANKRUN_BALANCE:-vault} fireDiscount=${BANKRUN_FIRE_DISCOUNT:-0.25} equity=${BANKRUN_EQUITY:-0.10} fundamental=${BANKRUN_FUNDAMENTAL:-none} return=[${BANKRUN_RETURN_LO:-0.9}, ${BANKRUN_RETURN_HI:-1.3}] thetaNoise=${BANKRUN_THETA_NOISE:-0.10}"
echo "theta public: mode=${BANKRUN_THETA_PUBLIC:-none} level=${BANKRUN_THETA_PUBLIC_LEVEL:-0.6} gap=${BANKRUN_THETA_PUBLIC_GAP:-0.0} rho=${BANKRUN_THETA_PUBLIC_RHO:-1.0} noise=${BANKRUN_THETA_PUBLIC_NOISE:-0.10} lambdaScope=${BANKRUN_LAMBDA_SCOPE:-count}"
echo "withdraw: mode=${BANKRUN_WITHDRAW:-all} partialMinShare=${BANKRUN_PARTIAL_MIN_SHARE:-0.01} partialSteps=${BANKRUN_PARTIAL_STEPS:-4}"
echo "risk: cara=${BANKRUN_CARA:-0}"
echo "deposits: cap=${BANKRUN_DEPOSIT_CAP:-0}"
echo "reserve=$reserve depq=$depq sigma=$sigma k=$k p=$p alpha=$alpha mu=$mu"
echo "lambdaI=$lambdaI lambdaC=$lambdaC  genSeed=$GEN_SEED  seeding=${BANKRUN_SEEDING:-task} nInit=${BANKRUN_N_INIT:-5}"
echo "outdir=${TASK_DIR}"
echo "started $(date)"
echo "======================================================================"

# Argument order is positional and consumed by parameterGen.jl via CLI_ARGS:
#   1 dataDir  2 genSeed  3 reserve  4 depq  5 distName  6 lognMu  7 sigma
#   8 k  9 p  10 alpha  11 mu  12 lambdaI  13 lambdaC
julia --project="$PROJECT_ROOT" "$PROJECT_ROOT/finMain0001.jl" \
    "$TASK_DIR" \
    "$GEN_SEED" \
    "$reserve" \
    "$depq" \
    "LogNormal" \
    "1.0" \
    "$sigma" \
    "$k" \
    "$p" \
    "$alpha" \
    "$mu" \
    "$lambdaI" \
    "$lambdaC"

echo "finished $(date)"
