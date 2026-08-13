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
#   BANKRUN_ASSIGN_RULE    warmup | random | reverse (read by functions4.jl)
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
GEN_SEED=$((SEED_OFFSET + SLURM_ARRAY_TASK_ID))

read -r reserve depq sigma k p alpha mu lambdaI lambdaC \
    < <(sed -n "${SLURM_ARRAY_TASK_ID}p" "$PARAMS_FILE")

if [[ -z "${lambdaC:-}" ]]; then
    echo "ERROR: params line ${SLURM_ARRAY_TASK_ID} of ${PARAMS_FILE} is short or missing" >&2
    exit 1
fi

echo "======================================================================"
echo "arm=${ARM_TAG}  task=${SLURM_ARRAY_TASK_ID}  assign=${BANKRUN_ASSIGN_RULE}  mcDepth=${BANKRUN_MC_DEPTH}"
echo "reserve=$reserve depq=$depq sigma=$sigma k=$k p=$p alpha=$alpha mu=$mu"
echo "lambdaI=$lambdaI lambdaC=$lambdaC  genSeed=$GEN_SEED"
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
