#!/bin/bash
# =============================================================================
# ⚠️ DEPRECATED 2026-08-13 — superseded by scripts/run_all.sh.
#
# This file hardcodes --array=1-2160, params_focused.txt, and
# outputs/task_<N>/, so every arm it launches writes into the same namespace
# and overwrites the previous one. scripts/run_all.sh + scripts/sweep_task.slurm
# replace it: the array range comes from the params file, and each arm gets its
# own outputs/<tag>/ root.
#
# Kept ONLY until the new path has run clean on HPC once. Do not submit it.
#   Replacement:  ./scripts/run_all.sh --dry-run     # then drop --dry-run
# =============================================================================
#SBATCH --job-name=bankrun
#SBATCH --partition=normal
#SBATCH --array=1-2160%50        # submit all 2,160 tasks, max 50 running at once
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16        # 1 master + 15 workers (matches cores=16)
#SBATCH --mem=32G
#SBATCH --time=0-08:00:00         # 8 hours per task; increased for higher reserve ratios where bank survives longer
#SBATCH --output=/projects/tstratma/BankRuns5/logs/slurm_%A_%a.out
#SBATCH --error=/projects/tstratma/BankRuns5/logs/slurm_%A_%a.err

# ── Environment ───────────────────────────────────────────────────────────────
module load julia/1.8.0

PROJECT_DIR=/projects/tstratma/BankRuns5
PARAMS_FILE=$PROJECT_DIR/params_focused.txt

# Each task gets its own output directory to avoid filename collisions
# (finMain0001.jl writes per-worker CSVs like bankRunResults2.csv, agents2.csv, etc.)
TASK_DIR=/projects/tstratma/BankRuns5/outputs/task_${SLURM_ARRAY_TASK_ID}
mkdir -p "$TASK_DIR"

# GEN_SEED: unique per task, offset from 1000 to avoid clashing with test seeds
GEN_SEED=$((1000 + SLURM_ARRAY_TASK_ID))

# ── Read parameters for this task ─────────────────────────────────────────────
read reserve depq sigma k p alpha mu lambdaI lambdaC \
    < <(sed -n "${SLURM_ARRAY_TASK_ID}p" "$PARAMS_FILE")

echo "Task $SLURM_ARRAY_TASK_ID: reserve=$reserve depq=$depq sigma=$sigma k=$k p=$p alpha=$alpha mu=$mu lambdaI=$lambdaI lambdaC=$lambdaC"

# ── Run the model ──────────────────────────────────────────────────────────────
julia --project="$PROJECT_DIR" "$PROJECT_DIR/finMain0001.jl" \
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
