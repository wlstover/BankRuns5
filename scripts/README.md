# BankRuns5 HPC pipeline

One argument-driven entry point — `scripts/run_all.sh` — submits the sweep and
chains verification, consolidation, and analysis behind it. The design is ported
from `celsius/scripts/run_all.sh` so both dissertation chapters are operated the
same way.

```
scripts/run_all.sh          orchestrator — the only thing you invoke
├── gen_params.sh           materialises the arm's parameter grid
├── sweep_task.slurm        array-task payload (one task = one parameter cell)
├── check_sweep_run.py      afterany chaser — did the tasks actually finish?
├── ../consolidate_results.py   afterany chaser — task dirs -> one CSV
└── run_analysis.slurm      afterok chaser — analysis_p6.R -> figures + CSVs
```

## Quick start

```bash
ssh wstover2@hopper
cd /projects/tstratma/BankRuns5

./scripts/run_all.sh --dry-run      # ALWAYS first — prints every sbatch, submits none
./scripts/run_all.sh                # focused grid (2,160 cells), arm tag "production"
squeue -u $USER
```

## Arms

Every arm writes to `outputs/<tag>/` and tags every job name with `<tag>`. This
is what makes it safe to run a variant without destroying its own baseline.

| Arm | Command |
|---|---|
| Production (focused grid) | `./scripts/run_all.sh` |
| Full 12,960-cell design | `./scripts/run_all.sh --grid full --tag full-grid` |
| **P6b on denser networks** | `./scripts/run_all.sh --k 6 10 50 --tag p6b-density` |
| **Warm-up placebo** | `./scripts/run_all.sh --assignment random --tag placebo` |
| Anti-treatment | `./scripts/run_all.sh --assignment reverse --tag anti` |
| Top up under-filled cells | `./scripts/run_all.sh --tag production --restart` |
| Post-process only | `./scripts/run_all.sh --consolidate --analyze --tag production` |

Any axis can be overridden and is forwarded to `gen_params.sh`, which validates
it: `--reserve --depq --sigma --k --p --alpha --mu --lambda-i --lambda-c`.

`--depth N` sets the Monte Carlo draws per agent decision (default **100**).

## ⚠️ Monte Carlo depth is a modelling parameter, not a speed knob

The default was lowered from the model's original **1000 to 100** on 2026-08-13.
Each agent's withdraw/stay decision compares two Bernoulli means estimated over
`depth` clone-and-resimulate draws, so decision precision scales as
`1/sqrt(depth)`:

| depth | MC standard error at p=0.5 |
|---|---|
| 1000 | ~0.016 |
| **100** | **~0.050** |

An agent whose two probabilities sit within that band decides essentially at
random, so lowering depth injects noise into the cascade itself. Whether that
raises or lowers aggregate P(run) is not obvious a priori — it should be
measured, not assumed. A depth-sensitivity arm is one command:

```bash
./scripts/run_all.sh --depth 1000 --tag depth1000    # against the default 100
```

**The 2026-04 production sweep ran at depth 1000. Do not pool across depths.**
Depth is recorded in `manifest.csv`, in the parameter dump, and as the `mcDepth`
column of the consolidated CSV; it is blank for legacy rows, which are all 1000.

⚠️ `--tag` is **required** for any non-default arm. Untagged variant output would
be indistinguishable from the production baseline after the fact.

### The two arms worth running first

- **`--k 6 10 50`** — the focused sweep pins `k = 6`, and §6.9 predicts the P6b
  interior peak appears on *dense* networks and vanishes on sparse ones. The
  experiment designed to find P6b was run only where it should be weakest.
- **`--assignment random`** — in the published model, individualism and bridge
  position are the same variable: the Flache–Macy warm-up makes boundary agents
  type I. So varying μ moves the cultural channel and a pure topology channel
  together, and the composition result is jointly attributable. The placebo holds
  the number of individualists, both λ distributions, the network, the deposits
  and the shock fixed, and varies **only** the correlation between cultural type
  and network position. Survives ⇒ signal weighting, as claimed. Dies ⇒ topology.

## ⚠️ SLURM state is not a completion signal

The 2026-04 sweep's failure mode was **TIMEOUT at the walltime**, leaving task
directories with a fraction of their 50 runs. ~25% of runs carried no terminal
outcome record and it went unnoticed for months. Read the check job:

```bash
python3 scripts/check_sweep_run.py --arm-dir outputs/production \
        --manifest outputs/production/manifest.csv --job-id <array jid>
```

It reports per-task key counts, outcome coverage, duplicate keys, `sacct` states,
and the parameter-dump width. It exits nonzero only on FAIL — under-filled and
surplus cells are reported as warnings, deliberately, so the job going red always
means something.

**`--restart` is a top-up, not a resume.** `restart.jl` is not wired in
(`finMain0001.jl:90`), so a re-submitted task appends a fresh 50-run block under
new keys. The extra runs are valid draws; they are not a continuation. This is the
mechanism behind the ~612-runs-per-cell surplus in the 2026-04 sweep against a
documented 50.

## ⚠️ Column names changed 2026-08-13

`consolidate_results.py` used to name the parameter columns positionally and the
positions were wrong — `parameterGen.jl:135` writes `(k, p, r, q)` where the old
header read `(agtCnt, reserveRatio, depositInsurance, exogProb)`. Anything keyed
on `reserveRatio` was keyed on the Watts–Strogatz rewiring probability.

| Old name | Actually held | New name |
|---|---|---|
| `agtCnt` | Watts–Strogatz `k` | `k` |
| `reserveRatio` | Watts–Strogatz `p` | `p` |
| `depositInsurance` | reserve ratio | `reserveRatio` |
| `exogProb` | insurance quantile | `depQuantile` |
| — | *(never recorded)* | `mcDepth` |
| — | *(never recorded)* | `sigma` |
| — | *(never recorded)* | `nWithdrawn`, `depositWithdrawn` |

The data were always correct; only the labels were wrong. **Any figure generated
before this date is mislabelled at the axis level and must be redrawn, not
relabelled** — `fig2_reserve_null.png` in particular asserts a null that does not
exist (the true reserve axis spans 99.5% → 46.8% failure, a 52.7 pp swing; the
1.6 pp null belongs to `p`).

The durable fix is the **manifest**: `run_all.sh` writes `outputs/<tag>/manifest.csv`
at submission time with one row per array index carrying the full parameter tuple,
and consolidation joins on `task_id`. Positional parsing survives only as a
fallback for the legacy 2026-04 sweep, and warns when it is used.

## Pulling results back to local

Only derived artifacts need to travel — the per-task simulation CSVs are ~200 GB
and stay on HPC.

```bash
rsync -av wstover2@hopper:/projects/tstratma/BankRuns5/outputs/production/consolidated_results.csv ./outputs/production/
rsync -av wstover2@hopper:/projects/tstratma/BankRuns5/outputs/production/analysis/ ./outputs/production/analysis/
```

## Pushing code to HPC — use git, not rsync

```bash
# local
git push origin individualism

# hopper
cd /projects/tstratma/BankRuns5 && git pull
```

⚠️ **Do not rsync code to hopper.** Both paths were in use until 2026-08-13 and
they collided: files delivered by rsync arrive *untracked*, so git neither
updates them on pull nor reports them as stale. Hopper spent months running an
`analysis_p6.R` and a `consolidate_results.py` that had drifted from the repo —
including the pre-fix positional consolidator — with nothing in `git status` to
show for it. Recovering from it meant hand-diffing five untracked files against
their incoming versions before a pull would even proceed.

`outputs/` is gitignored in full, so a pull never touches simulation results and
the ~200 GB of `task_*` dirs stay invisible to git. Figures the chapter compiles
against are curated in `figures/`, deliberately, rather than being whatever
`analysis_p6.R` wrote into `outputs/` last.

Results still come back by rsync — that direction is fine, since nothing on the
local side is tracked:

```bash
rsync -av wstover2@hopper:/projects/tstratma/BankRuns5/outputs/<tag>/consolidated_results.csv ./outputs/<tag>/
```

## R module on hopper

`run_analysis.slurm` tries `R/4.2.0-hb`, then `R`, then `r`. Required packages:
`data.table`, `ggplot2`, `dplyr`, `tidyr`, `scales`. One-time install if missing:

```bash
module load <whatever R works>
R -e 'install.packages(c("data.table","ggplot2","dplyr","tidyr","scales"), repos="https://cloud.r-project.org")'
```
