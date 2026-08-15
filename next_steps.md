# Next Steps — Chapter 3 (ABM)

_Forward-looking tracker for `BankRuns5`, mirroring `celsius/next_steps.md`. Evidence and
dated narrative live in the daily notes; this file holds open items only.
Created 2026-08-13._

---

## ✅ RESOLVED 2026-08-13 pm — committed, and HPC reconciled

The morning's work is committed (`accff7d`, `3c2889f`, `889b871`, `a9f97eb`,
`4fb48bd`) and pushed. Hopper is current for the first time since April.
Narrative in `Daily Notes/2026-08-13.md`; what carries forward:

**Julia/Manifest mismatch — was fatal, now guarded.** The repo's Manifest was
resolved under Julia 1.12.5 while `sweep_task.slurm` loads `julia/1.8.0`; its
JLD2 stack requires Julia ≥ 1.10 and could not resolve on hopper. Hopper's own
Manifest was the working one *and* the environment that produced the 2026-04
sweep, so it is now what's committed (`7e8410e`). `sweep_task.slurm` fails at
task startup on any mismatch. **The smoke run would have died on this
regardless of code correctness, and it would have looked like a code failure.**

**git is now the only code path to HPC.** Five rsync-delivered files were
sitting untracked on hopper, three of them months behind the repo with nothing
in `git status` to show it — hopper was still running the pre-fix positional
`consolidate_results.py`. ⚠️ **No consolidated artifact produced on hopper
before 2026-08-13 should be trusted until regenerated.** `outputs/` is now
gitignored in full and chapter figures live in `figures/`.

**⚠️ CRLF trap, unfixed.** Schuler's four files (`functions4.jl`,
`finMain0001.jl`, `parameterGen.jl`, `objects.jl`) are CRLF; ours are LF. The
morning's edits silently flipped three of them, inflating `functions4.jl`'s diff
from 62 lines to 1,122. Restored before staging, but there is no
`.gitattributes`, so **any future edit strips CRLF again**. Check
`git diff --stat -w` against `git diff --stat` before committing anything that
touches his files — item 12 is sending exactly these diffs to Schuler.

**Legacy `outputs/task_*` on HPC: still keep.** Question answered in the
negative for now — see the boxed section below. Untracked, so git never touches
it; `git clean -fd` on hopper would destroy it.

---

## 📍 CURRENT STATE — 2026-08-14. **▶ START HERE.**

The HPC pipeline was rebuilt 2026-08-13 (`Daily Notes/2026-08-13.md`). Its first smoke
run failed on a name collision in our own instrumentation; that is fixed and pushed
(`ff33ad3`, `Daily Notes/2026-08-14.md`). **The pipeline has still never produced a
single model output on HPC.** The one job before anything else is the smoke re-run.

### ▶ START HERE 2026-08-15 — collision fixed, smoke re-run pending

Job `9363073_1` **FAILED** — `sacct` says `FAILED`, `00:00:59` of a 2h slot, ExitCode
`1:0`. The 2026-08-13 note called it "completed"; that was inferred from the job
leaving the queue, not from `sacct`. Diagnosis and fix in `Daily Notes/2026-08-14.md`.

**Cause: a name collision in our own instrumentation, not a logic bug.**
`function runSize(mod::Model)` (our |S*| addition) collided with Schuler's global
`runSize=10` at `parameterGen.jl:42`. `functions4.jl` is included `@everywhere` first,
binding `runSize` as a const in `Main`; `parameterGen.jl` is included after and assigns
to it. Julia refuses, and the task dies before writing anything.

**Fixed in `ff33ad3` (pushed):** ours renamed `runSize` -> `runSetSize`; Schuler's
untouched. New `test/test_name_collisions.jl` closes the class, verified in both
directions. Only one collision exists across the whole include order.

▶ **Re-run, on hopper:**

```bash
git pull
rm -rf outputs/smoke/task_1        # empty, but the CSVs open append=true
./scripts/run_all.sh --tag smoke \
    --reserve 0.25 --depq 0.0 --sigma 2.0 --p 0.05 --alpha 0.1 --mu 0.5 \
    --lambda-i 0.1 --lambda-c 0.9 --time 0-02:00:00
./scripts/check_recording.sh       # after it finishes
```

⚠️ **Two traps when reading the result.**

1. **A sub-minute failure is an include-time error, and it lives in `.err`.** Check 4
   auto-discovers only the `.out` file, and its three assertions
   (`Manifest pin`, `assignment rule`, `Monte Carlo depth`) fire at
   `finMain0001.jl:49` and `:82` — *before* the includes and before any model code.
   **They passed on the failed job.** They prove the export path reaches Julia and
   nothing more; the 08-13 note's "environment, orchestrator and export path are
   proven" over-read them. Read `.err` first on any fast failure.
2. **Check 6 may WARN rather than PASS.** At reserve 0.25 the bank may survive every
   run, so `ntrue == 0` and the decisive `bankRun == true ⇒ nWithdrawn > 0` assertion
   is untestable — the gate exits 0 having proven nothing about `runSetSize`. That is
   a re-smoke at a lower reserve, **not** a pass.

**Then the placebo smoke**, still the only untested code path:

```bash
./scripts/run_all.sh --tag smoke-placebo --assignment random \
    --reserve 0.25 --depq 0.0 --sigma 2.0 --p 0.05 --alpha 0.1 --mu 0.5 \
    --lambda-i 0.1 --lambda-c 0.9 --time 0-02:00:00
./scripts/check_recording.sh --tag smoke-placebo --rule random
```

Check `agents*.csv` (cols: key, idx, deposit, individualism, warmupLambda, agentType):
in the **default** arm `agentType == "I"` must be exactly the top-mu of `warmupLambda`;
in the **placebo** arm the two must be uncorrelated. That is the whole intervention.

**Small follow-up:** add `.err` discovery to `check_recording.sh` check 4, so a fast
failure surfaces its error instead of three green PASSes.

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
