#!/bin/bash
#
# run_analysis.slurm — SLURM job to run the headline P6 analysis on HPC.
#
# Reads outputs/consolidated_results.csv (produced by run_consolidate.slurm)
# and writes plots + summary CSVs to outputs/analysis/. All outputs are
# small (< 5 MB total) and can be rsync'd back to local for the deck.
#
# Usage:
#   sbatch scripts/run_analysis.slurm                     # default analysis_p6.R
#   sbatch scripts/run_analysis.slurm path/to/other.R     # different R script
#
# Prerequisites:
#   - run_consolidate.slurm has produced outputs/consolidated_results.csv
#   - R available via module, and the analysis packages installed once by
#     scripts/bootstrap_r_libs.sh (hopper's R site library has no data.table)
#
# After it completes, rsync the analysis outputs:
#   rsync -av wstover2@hopper:/projects/tstratma/BankRuns5/outputs/analysis/ ./outputs/analysis/
#
#SBATCH --job-name=bankrun-analysis
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=0-01:00:00
#SBATCH --output=/scratch/%u/bankrun-analysis-%j.out
#SBATCH --error=/scratch/%u/bankrun-analysis-%j.err
#SBATCH --export=ALL

set -euo pipefail

PROJECT_ROOT="/projects/tstratma/BankRuns5"
SCRIPT="${1:-${PROJECT_ROOT}/scripts/analysis_p6.R}"

module load gnu10/10.3.0-ya
# Load whatever R the cluster provides; check `module avail R` to confirm.
# Common candidates on hopper: R/4.2.0-hb, R/4.3.0-foss, r/4.2.0.
# The first existing one wins; fall back to the bare `module load r` alias.
if module load R/4.2.0-hb 2>/dev/null; then
    echo "Loaded R/4.2.0-hb"
elif module load R 2>/dev/null; then
    echo "Loaded R (default)"
elif module load r 2>/dev/null; then
    echo "Loaded r (default)"
else
    echo "WARNING: no R module found; trying system R" >&2
fi

# Confirm R is available
which R || { echo "ERROR: R not in PATH after module load" >&2; exit 1; }
R --version | head -1

# ⚠️ hopper's R has no data.table in its site library — the reason this stage
# had never produced output (found 2026-08-16; the .err said
# "there is no package called 'data.table'" under the Lmod chatter, while the
# .out ended at the banner). The packages live in a project-local library
# installed once by scripts/bootstrap_r_libs.sh, keyed by R version so a module
# change cannot load objects built against a different R.
R_VERSION="$(Rscript -e 'cat(paste0(R.version$major, ".", R.version$minor))')"
export R_LIBS_USER="${PROJECT_ROOT}/.Rlib/${R_VERSION}"
mkdir -p "${R_LIBS_USER}"
echo "R_LIBS_USER=${R_LIBS_USER}"
if [[ -z "$(ls -A "${R_LIBS_USER}" 2>/dev/null)" ]]; then
    echo "NOTE: project R library is empty. If the analysis aborts on a missing" >&2
    echo "      package, run: ./scripts/bootstrap_r_libs.sh" >&2
fi

cd "${PROJECT_ROOT}"

# Tell the R script where the project root is (so it doesn't have to guess
# from sys.frame() in the SLURM batch context).
export BANKRUN_PROJECT_ROOT="${PROJECT_ROOT}"

echo "Starting analysis at $(date)"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "SCRIPT=${SCRIPT}"
echo ""

Rscript "${SCRIPT}"

echo ""
echo "Analysis complete at $(date)"
echo "Output files in outputs/analysis/:"
ls -lh "${PROJECT_ROOT}/outputs/analysis/"
