#!/bin/bash
#
# run_consolidate.slurm — SLURM job to consolidate per-task ABM outputs.
#
# Walks /projects/tstratma/BankRuns5/outputs/task_*/ directories, joins the
# per-task bankRunParametersInit.csv + bankRunParametersFin.csv, and writes
# the consolidated row-per-run dataset to outputs/consolidated_results.csv.
#
# Output is small (~50 MB for 648K runs × 14 cols), suitable for rsync back
# to local for downstream analysis. The big per-task simulation CSVs
# (bankRunResults / bankRunEndogenous / agents / bankRunExogenous, ~200 GB
# total) stay on HPC.
#
# Usage:
#   sbatch scripts/run_consolidate.slurm
#
# After it completes, rsync the consolidated CSV back:
#   rsync wstover2@hopper:/projects/tstratma/BankRuns5/outputs/consolidated_results.csv ./outputs/
#
#SBATCH --job-name=bankrun-consolidate
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=0-01:00:00
#SBATCH --output=/scratch/%u/bankrun-consolidate-%j.out
#SBATCH --error=/scratch/%u/bankrun-consolidate-%j.err
#SBATCH --export=ALL

set -euo pipefail

PROJECT_ROOT="/projects/tstratma/BankRuns5"

module load gnu10/10.3.0-ya
module load python/3.10.1-5r

cd "${PROJECT_ROOT}"

echo "Starting consolidation at $(date)"
echo "PROJECT_ROOT=${PROJECT_ROOT}"
echo "Task directories present:"
ls outputs/ | grep -c "^task_" || echo "0"

python consolidate_results.py

echo ""
echo "Consolidation complete at $(date)"
echo "Output file:"
ls -lh outputs/consolidated_results.csv

echo ""
echo "Row count:"
wc -l outputs/consolidated_results.csv
