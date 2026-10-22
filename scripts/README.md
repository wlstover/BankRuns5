# BankRuns5 HPC pipeline

One argument-driven entry point — `scripts/run_all.sh` — submits the sweep and
chains verification, consolidation, and analysis behind it. The design is ported
from `bank_runs_celsius/scripts/run_all.sh` so both dissertation chapters are operated the
same way.

```
scripts/run_all.sh          orchestrator — the only thing you invoke
├── gen_params.sh           materialises the arm's parameter grid
├── sweep_task.slurm        array-task payload (one task = one parameter cell)
├── check_sweep_run.py      afterany chaser — did the tasks actually finish?
├── ../consolidate_results.py   afterany chaser — task dirs -> one CSV
├── run_analysis.slurm      afterok chaser — analysis_p6.R -> figures + CSVs
└── analysis_p6b.R          afterok chaser — the P6b test (see --compare)
```

## Tests and diagnostics live in `tests/`

`scripts/` is the pipeline — what SLURM runs. `tests/` is what a human runs to
check the work:

```bash
./tests/run_tests.sh          # every harness, one verdict
./tests/run_tests.sh --list   # what would run
```

⚠️ A suite that **could not run** is reported as SKIPPED and makes the overall
result non-green. An uninstalled `data.table`, or a Julia that does not match the
`julia/1.8.0` this repo pins, proves nothing about the code — treating it as a
pass is the 2026-08-16 failure in miniature.

Two verifiers stay in `scripts/` on purpose, because the pipeline invokes them:
`check_sweep_run.py` (submitted by `run_all.sh` as an `afterany` chaser) and
`sweep_status.sh` (mid-flight monitoring). A production sweep must not depend on
a `tests/` directory.

| Where | What |
|---|---|
| `tests/check_recording.sh` | acceptance gate for a single-cell smoke arm |
| `tests/check_endpoint_identity.py` | arms identical at μ ∈ {0,1}, differing inside |
| `tests/diagnose_short_cells.py` | locates the missing run in a 249/250 cell |
| `scripts/check_sweep_run.py` | post-hoc: did the array tasks finish and land data? |
| `scripts/sweep_status.sh` | mid-flight progress and failure readout |

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
| **Rerun named cells in full** (TIMEOUTs) | `./scripts/run_all.sh --tag production --tasks 387,1370 --time 0-04:00:00` |
| Top up under-filled cells | `./scripts/run_all.sh --tag production --restart` |
| Post-process only | `./scripts/run_all.sh --consolidate --analyze --tag production` |
| **The P6b test (headline)** | `./scripts/run_all.sh --analyze --tag production --compare placebo` |

Any axis can be overridden and is forwarded to `gen_params.sh`, which validates
it: `--reserve --depq --sigma --k --p --alpha --mu --lambda-i --lambda-c`.

`--depth N` sets the Monte Carlo draws per agent decision (default **100**).

## The P6b test — `--compare` and why a single arm cannot do it

`analysis_p6b.R` runs automatically as its own job (`--no-p6b` disables it). Its
headline statistic is

    excess(treatment) - excess(placebo)

which needs **two** arms, so it needs `--compare <tag>`:

```bash
./scripts/run_all.sh --analyze --tag production --compare placebo
```

Without `--compare` the job still runs, but within-arm only — and a within-arm
number cannot establish P6b. The excess is measured above a chord that assumes
P6a is **linear** in mu, while §6.4 reports the P6a decline is "steepest in the
interior and flatter at the boundaries". A concave P6a therefore produces a
positive excess with no P6b whatsoever, and no statistic computed on one arm's
mu curve can separate them: the confound is in the baseline, not the noise.

The placebo differences it out, because random assignment holds composition
exactly fixed (same type counts, same lambda draws, same network, same
deposits, same shock) and destroys only the type-to-position correlation. P6a
is a composition effect and survives; P6b is a position effect and should not.

⚠️ Read `endpoint_contamination__*.csv` first. At mu = 0 and mu = 1 only one
type exists, so P6b is zero by construction and any between-arm gap there is
P6a contamination — the contrast is not clean.

**The outcome is cascade size |S*| (`nWithdrawn`), not `bankRun`** — since
2026-08-17. The vault is `r x total deposits`, so a binary run indicator is a
threshold on a continuous quantity whose sensitivity varies with `r`, one of
the axes being stratified on. `bankRun` is retained as a secondary outcome.
Outputs are suffixed `__cascade__` / `__binary__` and `__headline__` /
`__insurance__` so the two can never be confused for one another.

The `__insurance__` block stratifies additionally on `depQuantile`, giving the
depQuantile x lambda-gap interaction — the reduced-form test of whether a
deposit-insurance backstop dampens social-signal weighting. Check `nSeeds` in
that output before quoting it: it pools proportionally fewer paramSeeds than
the headline. Disable with `BANKRUN_SKIP_INTERACTION=1`.

Validate any change to this script with `Rscript tests/test_p6b_continuous.R`
(6 ground-truth fixtures; fixture B is the one that matters — a curved P6a with
no P6b, which the contrast must refuse).

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

**For a TIMEOUT, use `--tasks`, not `--restart`.** `--tasks LIST` reruns the
listed cells from scratch with the arm's original seeds: it reads the
assignment rule, MC depth, seed offset and every `BANKRUN_*` switch from the
manifest (exporting them, and refusing a conflicting value in your shell),
refuses unless the checkout is the manifest's `git_commit` and clean, moves the
partial task directories to `outputs/<tag>/timeout_partial/`, and logs the
resubmission in `resubmissions.log` without rewriting the manifest. The runs
are deterministic, so the completed runs come back identical and the missing
ones are filled in; paired arms (same seed offset) stay paired. Run keys carry
the submission time as a prefix, so compare old and new runs on the seed part of
the key. Verified on production-v2 (2026-10-20): the 2,706 runs completed before
the 13 TIMEOUTs came back identical, and all 544 missing runs were filled. The slow cells
are the ones that time out, so raise `--time` for the rerun (2026-10-20: task
runtimes had a median of 3 min and a tail to ~60 min).

**`--restart` is a top-up, not a resume.** `restart.jl` is not wired in
(`finMain0001.jl` does not include it), so a re-submitted task appends a fresh 250-run block under
new keys. The extra runs are valid draws; they are not a continuation. This is the
mechanism behind the ~612-runs-per-cell surplus in the 2026-04 sweep against a
documented 50.

## ⚠️ Column names changed 2026-08-13

`consolidate_results.py` used to name the parameter columns positionally and the
positions were wrong — `parameterGen.jl` (the `bankRunParametersInit.csv` write) writes `(k, p, r, q)` where the old
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

Since 2026-10-15 the manifest also records the `BANKRUN_*` model switches
(`settings.jl`) in its switch columns (`public_alpha` … `log`): the raw
value exported by the submitting shell, empty meaning the published default.
Manifests written before that lack these columns; readers go by header name.

## Output size: `BANKRUN_LOG=summary` and replay (2026-10-15)

At N = 1000 the per-agent and per-decision logs (`agents<core>.csv`,
`bankRunEndogenous<core>.csv`, `bankRunExogenous<core>.csv`) are ~0.3 MB per run,
~150 GB per 2,160-cell arm. With `BANKRUN_LOG=summary` a task writes only the
run-level files (`bankRunResults`, `bankRunVault`) and the who-runs summary
`bankRunTypes<core>.csv` (one row per run × type: counts by how each agent left,
deposits, payouts, position in the withdrawal order), ~80 MB per arm.
`consolidate_results.py` writes it to `consolidated_types.csv`.

Every run is reproducible from its manifest row and key, so the full logs of any
run are regenerated on demand, with the same commit and Manifest (the manifest
records `git_commit`):

    julia --project=. scripts/replay_run.jl --manifest outputs/<tag>/manifest.csv \
          --task <N> --key '<key>' --out outputs/replay

`tests/test_replay.jl` checks that a replay reproduces the stored results, vault
and who-runs rows byte for byte and that the summary agrees with the full logs.
Default is `full` (unchanged behaviour); production arms use `summary`.

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

## ⚠️ R on hopper has no data.table — bootstrap the library once

This is why the analysis stage had never produced output. `run_analysis.slurm`
tries `R/4.2.0-hb`, then `R`, then `r`; on hopper the third wins and resolves to
`/opt/sw/other/apps/r/4.3.1/gnu-openblas`, **whose site library does not contain
`data.table`**. Every `--analyze` run aborted at `library(data.table)` before a
line of analysis executed. It presented as a 9-second FAILED with an empty `.out`
— the same signature as two unrelated bugs fixed the day before, which is what
made it hard to see.

One-time fix, on the login node:

```bash
cd /projects/tstratma/BankRuns5
./scripts/bootstrap_r_libs.sh
```

It installs `data.table`, `ggplot2` and `scales` into
`.Rlib/<R version>/` (project-local, gitignored, version-keyed so a module
change cannot load objects built against a different R). `run_analysis.slurm`
exports `R_LIBS_USER` to that path automatically. `dplyr` and `tidyr` are no
longer required — `analysis_p6.R` never used them.

`analysis_p6.R` now preflights its packages and prints the missing ones, the R
version and the `.libPaths()` to **stdout**, so the next instance of this is
readable in the `.out` instead of buried under Lmod chatter in the `.err`.

### Fallback: run the analysis locally

The analysis stage does not have to run on HPC. Its input is small — a
single-cell arm is 250 rows, the full 2026-04 sweep is 68 MB — so if CRAN is
unreachable from hopper, pull the CSV down and run it here:

```bash
rsync -av wstover2@hopper:/projects/tstratma/BankRuns5/outputs/<tag>/consolidated_results.csv ./outputs/<tag>/
BANKRUN_ARM_DIR="$PWD/outputs/<tag>" Rscript scripts/analysis_p6.R
```

## Docking outputs and the switch registry (2026-10-20)

**Switch registry.** `settings.jl`'s `SWITCH_DEFAULTS` is the one list of
`BANKRUN_*` switches. `scripts/switch_names.sh` reads it, and from it come
run_all.sh's untagged-arm guard (`--model` drops `OUTPUT_ONLY_SWITCHES` such as
`LOG`), the manifest's switch columns (`scripts/write_manifest.sh`) and
replay's column map. `finMain0001.jl` broadcasts the whole set as `SWITCHES`, and
`switchValue()` falls back to it. To add a switch:
1. Add a line to `SWITCH_DEFAULTS` and its parser entry in `parseSwitchesFromEnv()`.
   A combination the model must refuse goes in `switchComboError()`, which both
   the parser (at startup) and `modelRun` check.
2. Use it through `switchValue(:NAME)` in the model.
3. Write a log file only when it is non-default.
4. Export it in `scripts/sweep_task.slurm` (`export BANKRUN_X="${BANKRUN_X:-}"`)
   and add it to the echo lines there and to `finMain0001.jl`'s banner.
5. If it writes a switch file: add the file to `consolidate_results.py`'s
   `SWITCH_FILES` and to `switch_file_required()` (a prefix missing there raises
   `KeyError`), and the column to `tests/test_consolidate.py`'s `SWITCH_COLS`.
6. Add a test in the style of `tests/test_stay_return.jl` and list it in
   `tests/run_tests.sh`.

The registry readers (`switch_names.sh`, `write_manifest.sh`, `run_all.sh`,
`run_arms.sh`, `replay_run.jl`) need no edit. (Corrected 2026-10-21: this used
to say "nothing else needs editing", which missed items 4 and 5.)

**Fire-sale bank (2026-10-21).** `BANKRUN_BALANCE=firesale` (with
`PAYOFF=recovery`) is Chapter 1's baseline bank: withdrawals beyond reserves are
paid by selling the long asset at 1 − `FIRE_DISCOUNT`, and the bank fails at
period 2 if it cannot pay the stayers' promises (`STAY_RETURN` × deposit). With
`FUNDAMENTAL=theta`, θ ~ U[0,1] per run sets the long asset's return, and
`PRIVATE_SIGNAL=theta` gives agents a signal of it. Each run writes
`bankRunBalance*.csv` (θ, the balance sheet, `failType` none / liquidity /
insolvency, the largest depositor), gathered into `consolidated_balance.csv`;
`scripts/theta_response.py` reads the θ gate.

**Arm sets.** `scripts/run_arms.sh arms/<set>.tsv [--dry-run|--list|--only TAG]`
submits one `run_all.sh` call per row (tag, switches, flags). It refuses if the
calling shell already exports a model switch. `--grid reference` (15 cells) and
`--grid reference-r3` (45 cells) are the hypothesis-arm grids: the non-saturated
reference point r 0.30 (plus 0.15 / 0.40), σ 2, k 6, p 0.05, q 0, α 0.1, crossed
with μ and the three λ pairs. Every arm uses seed offset 1000, so arms on the
same grid are paired cell by cell.

**Docking outputs** (`functions4.jl` `dockRow` / `timingRows` / `wealthRows`,
written by `runRow`; gathered by `consolidate_results.py` into
`consolidated_{dock,timing,wealth}.csv`; checked by `tests/test_dock_outputs.jl`
and `tests/check_recording.sh` §8):

| File | Grain | Columns |
|---|---|---|
| `bankRunDock` | run | `nExog`, `depExogShare`, `reserveShare` (vault / deposits), `slack` ((vault − paid to the shock) / deposits: Ch 1's θ), `pubErr1` / `pubErrMean` (announced − true count at tick 1 / averaged over ticks; NaN with no announcement), `nTicks` |
| `bankRunTiming` | run × type | `tickSumEndog`, endogenous withdrawals in ticks `t1`…`t9`, `t10plus` (discrete-time hazard counterpart to Ch 2's Cox model) |
| `bankRunWealth` | run × type | `n_d1`…`n_d10` agents and `endog_d1`…`endog_d10` endogenous withdrawers by decile of the run's deposits |

`scripts/shock_response.py <arm> [...]` gives P(run) and I − C by shock size, plus
the slope of P(run) in n_exog. This is the gate for any θ mapping: production's
slope is only +0.03 to +0.05 per 10 exogenous withdrawers.
