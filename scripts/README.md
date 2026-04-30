# BankRuns5 HPC analysis pipeline

Two-stage workflow that keeps the 200 GB of raw simulation outputs on HPC and
ships only small derived artifacts back to local.

## Stage 1: Consolidate per-task outputs into a single dataset

The sweep produces one task directory per parameter combination
(`outputs/task_<N>/`), each with per-worker simulation CSVs:
`bankRunResults*.csv`, `bankRunEndogenous*.csv`, `bankRunExogenous*.csv`,
`agents*.csv`, `bankRunParametersInit.csv`, `bankRunParametersFin.csv`.

`consolidate_results.py` (in the BankRuns5 project root) walks these and
joins parametersInit + parametersFin per task, producing one row per
simulation run with every parameter + the binary `bankRun` outcome.

```bash
ssh wstover2@hopper
cd /projects/tstratma/BankRuns5
sbatch scripts/run_consolidate.slurm
# Returns a jid; monitor with: squeue -u wstover2
```

Output: `outputs/consolidated_results.csv` (~50 MB for 648K rows × 14 cols).
Walltime: ~15--30 min (mostly I/O across 12,960 task directories).

## Stage 2: Run the headline analysis

`analysis_p6.R` reads the consolidated CSV and produces:
- `outputs/analysis/p6_mu_lambdagap.png` — the central P6 figure: P(run) vs.\
  cultural composition $\mu$, stratified by $\lambda$-gap, faceted by reserve
  ratio. **This is what populates dissertation_proposal.tex slide 20.**
- `outputs/analysis/marginal_*.png` — six marginal failure-rate barcharts
  (one per parameter: reserve ratio, deposit insurance, $\alpha$, $\mu$,
  $\lambda_I$, $\lambda_C$). Sanity checks against §1.5 directional
  predictions.
- `outputs/analysis/cell_failure_rates.csv` — failure rate at every
  parameter combination. Tidy CSV for ad-hoc downstream filtering.
- `outputs/analysis/p6_nonmonotonicity_check.csv` — for each
  $(\lambda$-gap, reserve ratio) pair, identifies whether the $\mu$ curve
  is monotone increasing, monotone decreasing, or non-monotonic with an
  interior peak. **This is the primary test of P6.**

```bash
sbatch scripts/run_analysis.slurm
```

Walltime: ~5--15 min on the consolidated CSV. All outputs are small.

## Stage 3: Pull derived artifacts back to local

Only two things need to come back over the wire — both small:

```bash
# from local
rsync -av wstover2@hopper:/projects/tstratma/BankRuns5/outputs/consolidated_results.csv \
          ./outputs/

rsync -av wstover2@hopper:/projects/tstratma/BankRuns5/outputs/analysis/ \
          ./outputs/analysis/
```

Total: ~50 MB. Compare to ~200 GB if you tried to rsync the per-task raw
simulation outputs.

## Adding a new analysis question

1. Write a new `scripts/analysis_<topic>.R` that reads
   `outputs/consolidated_results.csv` (or a per-task subset if needed for
   cascade dynamics) and writes to `outputs/analysis/`.
2. Submit via:
   ```bash
   sbatch scripts/run_analysis.slurm scripts/analysis_<topic>.R
   ```
   The wrapper accepts an optional first argument to override the default
   `analysis_p6.R`.

## R module on hopper

`run_analysis.slurm` tries three module-name patterns in order
(`R/4.2.0-hb`, `R`, `r`) and warns if none succeed. If you find the actual
correct module name, edit the SLURM script's module-load block to skip the
fallbacks. Required R packages: `data.table`, `ggplot2`, `dplyr`, `tidyr`,
`scales`. If any aren't in the system R install, do a one-time:

```bash
ssh wstover2@hopper
module load <whatever R works>
R -e 'install.packages(c("data.table","ggplot2","dplyr","tidyr","scales"), repos="https://cloud.r-project.org")'
```

Installs to `~/R/<arch>/<R-version>/` by default; persists across SLURM jobs.

## Pushing this code to HPC

These four files (the .slurm wrappers, the R script, this README) need to
be rsync'd to the HPC project root before first use:

```bash
# from local
rsync -av ~/Projects/bank_run_dissertation/BankRuns5/scripts/ \
          wstover2@hopper:/projects/tstratma/BankRuns5/scripts/
```

`consolidate_results.py` is already on HPC (it was used during the existing
sweep development).
