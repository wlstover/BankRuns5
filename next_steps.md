# Next Steps — Chapter 3 (ABM)

_Forward-looking tracker for `BankRuns5`, mirroring `celsius/next_steps.md`. Evidence and
dated narrative live in the daily notes; this file holds open items only.
Created 2026-08-13._

---

## ⏸️ SESSION PAUSED 2026-08-13 (laptop power cycle) — READ THIS FIRST

**Nothing is committed.** All of today's work is written to disk and survives the reboot,
but it is a single working tree with no checkpoint. `git status` in `BankRuns5/` should
show:

```
 M .gitignore  consolidate_results.py  finMain0001.jl  functions4.jl
 M parameterGen.jl  test_run.jl  sweep.slurm  scripts/analysis_p6.R  scripts/README.md
 M abm_chapter.tex  banking.bib  paper_draft.md        # pre-existing, not from today
 D gen_params.sh  gen_params_focused.sh  run_sweep.sh  # retired, superseded
 ?? next_steps.md  future_work.md
 ?? scripts/{run_all.sh,sweep_task.slurm,gen_params.sh,check_sweep_run.py}
 ?? test/{test_assignment_rules.jl,test_runsize.jl}
```
Plus `celsius/CLAUDE.md` and the top-level `CLAUDE.md` modified, and
`Daily Notes/2026-08-13.md` written (225 lines — that note is the evidence for
everything below).

**First move on resume: decide whether to commit.** A single commit covering the
orchestrator + recording fixes is the natural checkpoint, and it should happen before
anything touches HPC, so a smoke-run failure can be diffed against a known state.

### What was done today

1. **Axelrod → Flache–Macy** in `celsius/CLAUDE.md:302-310` (it loads every session, so
   the error was propagating). Also corrected the same sentence's claim that the warm-up
   crystallizes religiosity — the ABM has no religiosity channel.
2. **New HPC pipeline**, ported from `celsius/scripts/run_all.sh`: `scripts/run_all.sh`
   (orchestrator), `scripts/sweep_task.slurm` (payload), `scripts/gen_params.sh` (merged
   generator), `scripts/check_sweep_run.py` (verifier). Arms isolate to `outputs/<tag>/`;
   a manifest written at submission time is what kills the positional-parsing bug class.
3. **`consolidate_results.py` rewritten** — corrected mapping, manifest join, legacy
   fallback with warnings, carries σ / \|S*\| / mcDepth.
4. **Julia recording fixes**: σ + assignRule + mcDepth into the params dump (now **16
   columns**, was 12); `runSize()` → \|S*\| in the results row (now **4 columns**, was 2);
   `ASSIGN_RULE` switch for the placebo arms.
5. **MC depth is now a run parameter, default 1000 → 100** (`--depth N`).
6. **Parallelism surveyed**, nothing changed — see the Performance section below.

### Verification status

All local gates passed: shell/Python/Julia syntax; grid generator byte-identical to the
retired one; four arms dry-run to distinct roots and array ranges; guards reject bad
input; verifier fires on every synthetic defect; consolidator round-trips both paths;
P6a reproduced from the existing CSV (84.38 / 68.37 / 16.0 pp).

`test/test_assignment_rules.jl` and `test/test_runsize.jl` are preserved regression tests
— they extract blocks out of `functions4.jl` by text marker and eval them, so they test
the shipped source without needing project dependencies. Run from the repo root:
`julia test/test_assignment_rules.jl`.

**Untested anywhere:** the live model. Local Julia cannot run it (JLD2 absent, Manifest
pins unmatched, `~/.julia` unwritable in-sandbox). That is what the smoke run below is for.

### ❓ Open question put to WS, not yet answered

**Whether to delete the ~200 GB of legacy `outputs/task_*` on HPC.** Recommendation was
**no, not yet** — full reasoning in the boxed section below. Short version: it is not in
the way (arms are isolated), it is the only regression oracle for the rebuilt pipeline,
and σ is retroactively recoverable from it. If space is the constraint, extract first,
then delete.

---

## 📍 CURRENT STATE — 2026-08-13. **▶ START HERE.**

The HPC pipeline was rebuilt today (see `Daily Notes/2026-08-13.md`). Everything is
verified locally and `--dry-run`-tested; **nothing has run on HPC yet.** The one job
before anything else is a smoke run.

### ▶ THE ONE JOB LEFT — smoke run on HPC

Enough changed today (new orchestrator, new payload, rewritten consolidator, three
Julia edits, depth default 1000 → 100) that the next thing to happen must be a
single-cell run, not a sweep.

```bash
# 1. push code (outputs/ excluded — nothing local should overwrite HPC results)
rsync -av --exclude outputs/ ~/papers/bank_run_dissertation/BankRuns5/ \
          wstover2@hopper:/projects/tstratma/BankRuns5/

# 2. on HPC, dry-run FIRST — it prints every sbatch and submits none
ssh wstover2@hopper
cd /projects/tstratma/BankRuns5
./scripts/run_all.sh --dry-run

# 3. one cell, 50 runs, short walltime (depth=100 should be ~10x faster than the
#    depth-1000 sweep that needed 8h; 2h is generous)
./scripts/run_all.sh --tag smoke \
    --reserve 0.25 --depq 0.0 --sigma 2.0 --p 0.05 --alpha 0.1 --mu 0.5 \
    --lambda-i 0.1 --lambda-c 0.9 \
    --time 0-02:00:00
```

**Then check, in this order — do not skip to the sweep:**

| # | Check | Expected |
|---|---|---|
| 1 | `awk -F, '{print NF; exit}' outputs/smoke/task_1/bankRunParametersInit.csv` | **16** (was 12; +lognMu, lognSigma, assignRule, mcDepth) |
| 2 | `awk -F, '{print NF; exit}' outputs/smoke/task_1/bankRunResults*.csv` | **4** (was 2; +nWithdrawn, depositWithdrawn) |
| 3 | `grep -c . outputs/smoke/task_1/bankRunResults*.csv` | **50** (5 seeds × 10 iterations) |
| 4 | slurm log carries `Monte Carlo depth: 100` and `assignment rule: warmup` | both printed at startup |
| 5 | `check_sweep_run.py` chaser | `RESULT: OK` |
| 6 | `consolidated_results.csv` | `sigma`, `mcDepth`, `nWithdrawn`, `depositWithdrawn` all populated |
| 7 | `nWithdrawn` values | in `[0, 1000]`, and `> 0` on any row with `bankRun == true` |

**Then the placebo smoke**, which exercises the only remaining untested code path:

```bash
./scripts/run_all.sh --tag smoke-placebo --assignment random \
    --reserve 0.25 --depq 0.0 --sigma 2.0 --p 0.05 --alpha 0.1 --mu 0.5 \
    --lambda-i 0.1 --lambda-c 0.9 --time 0-02:00:00
```

Check `agents*.csv` (cols: key, idx, deposit, individualism, warmupLambda, agentType):
in the **default** arm `agentType == "I"` must be exactly the top-μ of `warmupLambda`;
in the **placebo** arm the two must be uncorrelated. That is the whole intervention, and
it is the one thing local testing could only verify against extracted source rather than
a live run.

### ⚠️ Do NOT delete `outputs/task_*` on HPC yet

The ~200 GB of legacy 2026-04 task directories are **not** in the way — every new arm
writes to `outputs/<tag>/`, so the smoke run and any sweep can proceed with them in
place. Deleting them is not required for anything currently planned.

What deletion would cost, permanently:

| File | Consolidated? | What is lost |
|---|---|---|
| `bankRunParametersInit/Fin.csv` | ✅ in `consolidated_results.csv` | nothing |
| `bankRunResults*.csv` | ✅ | nothing |
| `bankRunEndogenous*.csv` | ❌ | per-decision `wdProb`/`stayProb`/`tick`/`vault` — the **only** source of legacy \|S*\|, cascade timing, and the decision-margin distribution |
| `bankRunExogenous*.csv` | ❌ | the seeded shock per run |
| `agents*.csv` | ❌ | per-agent `warmupLambda` + `agentType` — the **only** record of warm-up output, and the natural baseline for the placebo comparison |

Two further reasons to keep them for now:

1. **They are the regression oracle.** The legacy sweep is the only thing that can tell
   us whether a difference in the rebuilt pipeline's output is the depth change, a code
   change, or a bug. Run `--depth 1000 --tag depth1000` and it should reproduce
   84.38% / 68.37% / 16.0 pp. Without the old data there is nothing to diagnose against.
2. **σ is retroactively recoverable from them.** `sweep.slurm` mapped
   `task_${SLURM_ARRAY_TASK_ID}` to line `${SLURM_ARRAY_TASK_ID}` of
   `params_focused.txt`, so a manifest can be reconstructed for the legacy sweep and it
   can be re-consolidated **with** σ — which resurrects Experiment 3 on data we already
   paid for. See item 3 below.

**If space is the real constraint**, the order is: reconstruct the manifest → re-consolidate
with σ → extract \|S*\| and the agents/warm-up data into small derived files → *then*
delete the raw dirs. That converts ~200 GB into a few hundred MB of the parts we need.

---

## 🔴 Open — blocking the chapter's numbers

**1. Re-consolidate the legacy sweep under the corrected mapping.** The mapping is
confirmed from `parameterGen.jl:135` and four independent value checks (2026-08-13 note).
This produces the numbers §6.2 and §6.6 need, and settles two small discrepancies against the
08-10 note: reserve swing 52.7 pp (note: 52.5) and `p` levels 76.16/77.74 (note:
71.40/73.09, same ~1.6 pp gap).

**2. Rewrite §5's parameter table, §6.2, and §6.6's P6b saturation argument.** (Actions
24, 9-extend.) §5 currently describes a grid that was never run — r = 0.2/0.4 and
k = 6,10,50 against an actual focused grid of r = 0.15–0.40, k = 6 — and calls `p`
"rewiring probability" when the code runs Newman–Watts (adds edges, so E[deg] = k(1+p)
and the k/p axes are confounded). §6.6's saturation argument is refuted by the corrected
data: the regime is saturated only at r ≤ 0.20, and composition *peaks* at 25–27 pp for
r = 0.25–0.30.

**3. Reconstruct the legacy manifest so σ is recoverable.** Build
`outputs/manifest.csv` from `params_focused.txt` line N ↔ `task_N`.
⚠️ **Verify before relying on it:** cross-check 8 of the 9 columns (k, p, r, q, α, μ,
λ_I, λ_C) from a sample of task dirs' own dumps against the params file line. If those
match, attaching the 9th (σ) is safe. If they don't, the array-to-line mapping was not
what `sweep.slurm` implies and this item is dead.

**4. Redraw Figure 2 and audit every figure legend.** (Actions 23, 28.)
`fig2_reserve_null.png` has the mislabelling baked into the PNG and asserts a null that
does not exist. `fig1_p6a_headline` is safe (μ, λ_I, λ_C were always labelled correctly);
**`fig4_p6a_p6b_schematic` has never been checked.**

---

## 🟠 Open — new arms worth running once the smoke run passes

**5. P6b at k = 10, 50** (action 27). `./scripts/run_all.sh --k 6 10 50 --tag p6b-density`
(6,480 cells). §6.9 predicts the P6b interior peak appears on dense networks and vanishes
on sparse ones — and the focused sweep pinned k = 6. **The experiment designed to find
P6b was run only where it should be weakest.** This is the leading explanation for P6b's
non-detection now that the saturation argument is gone.

**6. Warm-up placebo** (`--assignment random --tag placebo`, optionally
`--assignment reverse --tag anti`). Decomposes the 16 pp composition result into culture
vs. topology. Gradient survives ⇒ signal weighting, as claimed. Gradient dies ⇒ it
required individualists on bridges and the cultural reading is overstated. This is the
surname placebo applied to the ABM, and the symmetry with Ch 1's methodology is worth
saying out loud when pitching it to Schuler.

**7. Depth sensitivity** (`--depth 1000 --tag depth1000`). Doubles as the regression check
against the legacy headline. MC standard error is ~0.016 at depth 1000 vs ~0.050 at 100;
whether the extra decision noise raises or lowers aggregate P(run) is not obvious a priori.

**8. Simulate the §9.8 high-degree trigger proposition** (action 16). Proved in
`REPOSITORY_REVIEW.md` but never simulated, and it is the SVB mechanism — the most
policy-legible result in the chapter. Needs a seeding-rule change (highest-degree vs
uniform-random shock), which is not currently a flag.

---

## 🟡 Open — model documentation and correctness questions for Schuler

Batch these into one message; several have been queued since 2026-08-09.

| # | Item | Where |
|---|---|---|
| 9 | `additionalWithdrawals` subtracts a **local** neighbour count from a **population** estimate. Probably intentional ("how many *more*"), but the mixed scale should be confirmed, not explained on our feet | `functions4.jl:391` |
| 10 | `warmup.jl`'s header describes `w = 2·sim − 1` but `influenceWeight()` computes a normalised dot product. They agree at the ±1 poles and **disagree in the interior**, which is exactly where the λ tallies accumulate | `warmup.jl` |
| 11 | Newman–Watts vs classic Watts–Strogatz mislabel in §5's parameter table | `paper_draft.md` |
| 12 | Today's edits to his model code: σ + assignRule + mcDepth in the params dump, \|S*\| instrumentation, the `ASSIGN_RULE` switch (default path bit-identical to published) | `parameterGen.jl`, `functions4.jl`, `finMain0001.jl` |
| 13 | Diagnostic: under the dot product, moderate agents have w ≈ 0 and the tie (`w > 0` ⇒ adopt, else resist) sends w = 0 to **resist** — so moderates may be classified individualist on *weak opinions* rather than *boundary position* | `warmup.jl` |

---

## 🔵 Performance — surveyed 2026-08-13, nothing changed

Two levels of parallelism are implemented; the third and largest is not.

- **Level 1, SLURM array across cells** — embarrassingly parallel, fully exploited.
- **Level 2, `Distributed.jl` across the 50 runs in a cell** — hand-rolled master/worker
  queue, `cores=16` → 15 workers (`finMain0001.jl:13`).
- **Level 3, the Monte Carlo inner loop — serial, and it is the dominant cost.**
  `functions4.jl:433`, `for k in 1:depth`, running per agent per tick; draw k is
  independent of k'. ~2M clone-and-resimulate ops per tick at N=1000, depth=1000. This is
  also what `future_work.md` §2's NN-surrogate proposal targets.
- **Not parallelizable:** the cascade itself. Phase 2 is sequential by construction —
  agents decide in randomized order, each observing the vault left by prior withdrawals.
  That dependence *is* the strategic complementarity behind Theorem 3.

Known inefficiencies, none urgent:

| # | Item | Cost |
|---|---|---|
| 14 | Master busy-waits: `finMain0001.jl:149`'s loop has no `sleep` and spins on `isReady` | 1 of 16 CPUs burned for the full walltime, every task |
| 15 | Workers poll `rowPull`/`checkOff` at `sleep(1)` granularity | ~100 s dead time per task |
| 16 | Load-imbalance tail: 50 runs over 15 workers = 3.33 rounds, last round leaves ~10 idle | matters because run lengths are uneven — high reserve survives longer, which is where the TIMEOUTs clustered |
| 17 | `cores=16` hardcoded in `finMain0001.jl:13` **and** independently in `--cpus-per-task`; nothing enforces agreement | silent over/under-subscription if either changes |
| 18 | `checkOff` is not under `rowLock` though `rowPull` is | safe in practice (master-side green threads, no yield), but asymmetric |

`model3_ws_homogeneous.jl:222` already does Level 2 with a plain `pmap` and
`Sys.CPU_THREADS` — no busy-wait, automatic load balancing. It is the homogeneous-agent
variant so it lacks the cultural machinery, but it is the cleaner in-repo pattern if
Level 2 is ever revisited.

⚠️ Attacking Level 3 cannot be naive: threading the inner loop while keeping 15 worker
processes oversubscribes 16 CPUs. It needs an explicit split (fewer runs in flight,
`JULIA_NUM_THREADS` per worker, `--cpus-per-task` sized to the product).

---

## ⚪ Deferred / documented, not blocking

- **`restart.jl` is not wired in** (`finMain0001.jl:90`). `--restart` is therefore a
  *top-up*: a re-submitted task appends a fresh 50-run block under new keys rather than
  resuming. Documented in the header, warned at submit time, reported by the verifier.
  Wiring it back in is a real decision, not a bugfix — it truncates partial rows.
- **`sweep.slurm`** is marked deprecated in place; retire it once the new path has run
  clean on HPC once.
- **`paper_draft.md` §5.1's "Monte Carlo depth D is fixed at 1,000"** is deliberately
  unchanged — it correctly describes the sweep that produced the current §6.6 numbers.
  Update it together with item 2, when new numbers land.
- **`paper_draft.md` §7 / `abm_chapter.tex`** carry an uncommitted edit removing the
  religiosity-channel sentences. Commit with the rest.
- **`future_work.md`** (untracked) holds the four proposed extensions: adaptive-λ social
  learning, NN surrogate for the MC inner loop, differentiable ABM, validation
  benchmarking.
