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

**✅ CRLF trap — guarded 2026-08-17** (`.gitattributes`, `-text` on the four files
+ `restart.jl`; `-text` rather than `eol=crlf` so no renormalisation diff lands on
Schuler's files before item 12 is sent). The manual check below is still required —
a `.gitattributes` stops *git* converting, not an *editor*. Original note:

**⚠️ CRLF trap, was unfixed.** Schuler's four files (`functions4.jl`,
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

## 📍 CURRENT STATE — 2026-08-19. **▶ START HERE.**

**Both arms landed and are verified.** Arrays `9392726` (production/warm-up) and `9392770`
(placebo/random), focused grid, 2,160 cells each, **2,160/2,160 with output in both**.
`params_sha=ef96a99c573fccc8` identical across arms — the contrast is well-defined, and
that was the one failure that would have been unrecoverable rather than merely expensive.
The two placebo NODE_FAILs (`_364`, `_365`) requeued and both hold a full 250 runs.

**The 249/250 is understood, fixed, and does not affect these arms** — see item 28. It cost
128 runs of 1,080,000 (0.012%). No re-run.

### ▶ START HERE — consolidate, then the contrast

```bash
git pull
# 0. the precondition — must pass before any of the rest means anything
python3 tests/check_endpoint_identity.py \
    --arm-a outputs/production --arm-b outputs/placebo --check-agents
# 1. then the pipeline
./scripts/run_all.sh --consolidate --tag production
./scripts/run_all.sh --consolidate --tag placebo
./scripts/run_all.sh --analyze --tag production --compare placebo
```

**Step 0 is not a formality.** At μ = 0 `nI = 0` and the `nI > 0 &&` guard short-circuits;
at μ = 1 `isI[sortIdx[1:nI]]` flags everyone whatever order `sortIdx` is in. So the
assignment rule cannot bite at the endpoints, and since `functions4.jl` re-seeds at every
stage (`seed1+2` for the placebo's `randperm`, `seed1+1` for the λ draws, `seed1` for
deposits, `mod.seed2` at line 358 for the run) the placebo's extra RNG consumption
perturbs nothing downstream. **The paired endpoint cells must therefore be bit-identical,
run for run** — expected value exactly 0 differences, not "small". Match on
`(task_id, seed1, seed2)`, never on `key`, which embeds `Dates.now()` and differs across
arms by construction.

⚠️ The check also samples interior μ as a **positive control**, and refuses to pass without
it: interior cells MUST differ, or `ASSIGN_RULE` never reached the model and endpoint
identity is trivially true. Validated on ten ground-truth worlds
(`tests/test_endpoint_identity.py`, 20 PASS / 0 FAIL), seven of which are false-green traps.

📌 **If step 0 passes, the chord cancels.** excess_J(μ) = rate_J(μ) − chord_J(μ), and equal
endpoints give chord_t ≡ chord_p, so

    excess_t(μ) − excess_p(μ)  ==  rate_t(μ) − rate_p(μ)      exactly

(verified to 1.1e-16). The headline P6b statistic is then simply the arm difference in
cascade size at interior μ, and the P6a-curvature confound that §6.4 worries about is
**absent from the contrast by algebra rather than by argument**. That is a stronger
statement of the 08-16 identification claim and it should replace it in §6.

⚠️ And the outcome is now cascade size: the headline files are suffixed `__cascade__`, with
`__binary__` retained so the legacy comparison survives (item 21).

Still open behind this: item 19 (cluster at `seed1`, or state the effective n — the
re-consolidation is when the numbers get rebuilt anyway) and items 1–4, which are the
legacy sweep rather than these arms.

---

## 📍 CURRENT STATE — 2026-08-15. (superseded — kept for the smoke-run narrative)

**The smoke run passed.** Job `9368644_1` COMPLETED in 51:48, stderr empty,
`check_recording.sh` returns **17 PASS / 0 FAIL / 0 WARN**, and check 6's decisive
assertion was genuinely exercised — 222 `bankRun == true` rows, all with
`nWithdrawn > 0`. `runSetSize()` is verified against real output and the pipeline has
produced its first trustworthy model output on HPC. Narrative in
`Daily Notes/2026-08-15.md`.

Three commits pushed to `origin/individualism`: `8eecffa` (gate reads `.err` first,
new INCONCLUSIVE exit), the 250-run correction, and the `analysis_p6.R` fixes.

### ▶ START HERE — the placebo smoke, then look at the analysis output

```bash
git pull
./scripts/run_all.sh --tag smoke-placebo --assignment random \
    --reserve 0.25 --depq 0.0 --sigma 2.0 --p 0.05 --alpha 0.1 --mu 0.5 \
    --lambda-i 0.1 --lambda-c 0.9 --time 0-02:00:00
./tests/check_recording.sh --tag smoke-placebo --rule random

# and, on the smoke arm that already passed, the analysis stage nobody has ever seen
./scripts/run_all.sh --analyze --tag smoke
```

The placebo is still **the only untested code path**. Check `agents*.csv` (cols: key,
idx, deposit, individualism, warmupLambda, agentType): in the **default** arm
`agentType == "I"` must be exactly the top-mu of `warmupLambda`; in the **placebo** arm
the two must be uncorrelated. That is the whole intervention.

✅ **Both done 2026-08-16.** The placebo smoke passed **17 PASS / 0 FAIL / 0 WARN**:
mean warm-up λ is 0.5157 (type I) vs 0.5118 (type C) against the treatment arm's 0.658
vs 0.369 — cultural type is decoupled from warm-up position with everything else held
fixed. The last untested code path is tested.

⚠️ But the single cell proves the *mechanism*, not the *hypothesis*. At μ = 0.5 the two
arms differ by 0.8 pp (88.8% vs 89.6%), z = 0.08 clustered. **A single cell has a minimum
detectable difference of ~29.5 pp at the median design effect, against a composition
effect of 16 pp** — it cannot test the placebo hypothesis even in principle. No
single-cell comparison in this design can support a claim about composition. That is the
argument for the full arm (item 6), not a null result.

✅ **`--analyze` now produces output** — for the first time ever. It had *two* walls, not
one: the four `analysis_p6.R` bugs fixed on 08-15, and then hopper's R 4.3.1 site library
having **no `data.table` at all**, which aborted the import block before line 1 of the
analysis. Fixed by `scripts/bootstrap_r_libs.sh` (project-local `.Rlib/<R version>`, run
once on the login node). The consolidated parameters round-trip correctly end to end —
flags → dump → consolidate → analysis, with the corrected column names — which is the
first verification of the 08-13 mapping fix against real output rather than source.

---

## 🔴 A cell is 250 runs over 5 initialisations, not 50 — and they are clustered

`parameterGen.jl:111` repeats the 5 sampled seeds 5x into 25 `seedFrame` rows, crossjoined
with `iteration 1:10` -> **250 runs per cell**. `iteration` never reaches the model.
Confirmed on the legacy sweep: 2,833 of 2,835 cells hold exactly 250 rows with exactly 5
distinct `seed1`. The "5 x 10 = 50" in `parameterGen.jl:39-42` has always been wrong.

Runs sharing a `seed1` share network, warm-up, lambda assignment and deposit vector
(`functions4.jl:28,82,92`), differing only in `seed2`. Measured over the 1,857 legacy
cells with interior failure rates: **ICC median 0.274, design effect median 14.4,
effective n per cell ~17 rather than 250.**

**19. Clustering — half done, and the remaining half is a different problem.** Aggregates
over ~2,800 cells survive; any CI about a single cell or a small stratum is roughly 3.8x
too tight.

✅ **"Cluster at `seed1`" is implemented.** `analysis_p6b.R` collapses to one row per
(stratum, μ, `paramSeed`) and bootstraps by resampling `paramSeed`s — and `paramSeed` *is*
`seed1` (`consolidate_results.py:13,175`).

🔴 **"State the effective n" is still owed, and it is a reporting decision.** `nRuns` =
540,000 will be read as the sample size; the independent unit is the initialisation, ~120
per stratum × μ. `excess_table` already emits `nSeeds` — print it next to every interval
and state the design effect once.

🔴 **The live problem is bigger: `analysis_p6b.R:420` assumes the arms are independent.**
They are paired by construction — `GEN_SEED = SEED_OFFSET + task_id` with the same offset
in both arms, so paired cells share network, deposits, warm-up, `seed1` and `seed2`.
`se = sqrt(se_t^2 + se_p^2)` drops the covariance, which is large and positive because both
arms sit on the same initialisations. **Conservative, not wrong-signed**, so it cannot
manufacture a P6b — but it discards exactly what the paired design was built to buy, since
the network draw is the dominant variance component (ICC 0.274). Fix by resampling each
initialisation once per replicate and taking *both* arms' outcomes for it. Do it only if
the headline comes back marginal; the point estimate and the sign test are unaffected.

🟠 Second-order: the bootstrap resamples `paramSeed`s independently within each μ, so a
replicate can draw a different parameter mix at μ = 0.25 than at μ = 0.5 — composition
imbalance entering as noise. The grid is fully crossed (6 r × 3 q × 2 σ × 2 p × 2 α × 3
λ-pairs = 432 blocks × 5 μ = 2,160), so **432 complete, fully-matched μ-curves per arm**
exist. Blocking on those removes the imbalance entirely. Worth it only if the headline is
marginal.

**✅ 20. RESOLVED 2026-08-16 — the non-monotonicity diagnostic is retired.**
`analysis_p6.R`'s `all(diff(failRate) >= 0)` flag was wrong in three ways, and the second
is the one that mattered:

1. A 5-value sequence is monotonic by chance only 2/120 = **1.67%** of the time, so
   `non_monotonic = TRUE` fires on **98.3% of pure noise**. The 08-15 fixture's "6 of 6
   non-monotonic on random data" was not a bug being caught — it is what noise predicts
   at 90.4%.
2. **P6b does not predict a non-monotonic curve.** It predicts an interior hump *above*
   the P6a baseline; the channels are additive, so a real hump under a steeper P6a
   decline flattens the curve without reversing it. Measured on a fixture with a **6 pp
   P6b hump built in, the old flag returns 0 of 18 non-monotonic** — essentially no power
   against its own alternative.
3. `all(diff(x) >= 0)` is vacuously TRUE in both directions on a length-1 vector, so a
   single-μ smoke arm printed `non_monotonic = FALSE` — "untestable" masquerading as
   "monotonic". Now `NA` with `nMuLevels` reported. Does *not* occur in a full sweep: all
   18 legacy strata carry all 5 μ levels.

Replaced by `scripts/analysis_p6b.R` (commit `a0f964e`): excess above the μ-endpoint
chord, cluster-bootstrapped on `paramSeed`, headline = the treatment-minus-placebo
contrast. Verified against four ground-truth fixtures at the real clustering depth.
Item 5 is unblocked.

**✅ 21. RESOLVED 2026-08-17 — the P6b outcome is now cascade size \|S*\|.**
`analysis_p6b.R` primary outcome is `nWithdrawn`; `bankRun` retained as a secondary so
the legacy comparison survives. Outputs suffixed `__cascade__`/`__binary__` and
`__headline__`/`__insurance__` — deliberately NOT reusing the old filenames, because
keeping a name while changing what it measures is this repo's signature failure.
Validated by `tests/test_p6b_continuous.R` (6 fixtures, 22 PASS / 0 FAIL), which is
committed this time — the 08-16 fixtures were built in-session and lost.
Three guards added while there: refuse blank `nWithdrawn` (legacy rows) rather than
dropping them, refuse mixed `mcDepth`, and refuse `--compare` against the arm's own tag.
Original reasoning:

μ and the λ-gap set **transmissibility** (individualists are firebreaks that are also
lightning rods — they absorb the signal at λ_I ≈ 0.1 but their private-signal tail draws
ignite; that dual role is where the μ(1−μ) product behind P6b comes from). But `r` is not
a density parameter — the vault is `r × total deposits`, so **`r` sets the cluster size
that counts as failure**. `bankRun` is therefore a *threshold indicator on a continuous
quantity*, and its sensitivity is maximal only when the threshold sits in the bulk of the
cascade-size distribution.

That reframes the whole saturation story: at r = 0.15 almost any cascade qualifies (~99%,
flat in μ — the ceiling that censors P6b), at r = 0.40 only near-spanning cascades do,
and sensitivity peaks at r = 0.25–0.30, which is exactly where the composition effect
peaks (25–27 pp) and where the excess-above-chord peaks in the legacy data. "P6b needs
intermediate cascade pressure" is not a brute fact about the model — it is what happens
when a continuous quantity is measured through a threshold.

P6b is a claim about cascade size. Test it on cascade size. `nWithdrawn` and
`depositWithdrawn` are already in the 4-column result row (the 08-13 \|S*\|
instrumentation) and the smoke run confirmed them populated and sane (0..639, every
`bankRun` row with `nWithdrawn > 0`). Not available for the legacy sweep —
`bankRunEndogenous*.csv` is the only source there and it is unconsolidated, which is a
further argument for item 3.

⚠️ Ch 2 dependency, and it is not optional: whether P6b-as-cascade-size is *coherent with*
the Goldstein–Pauzner formal structure or is instead an example of **what an ABM can ask
that the analytics cannot** turns on whether GP admits partial runs at all. In the σ → 0
limit that delivers uniqueness, the withdrawing fraction is degenerate and runs are
all-or-nothing by construction. Resolve this in `chapter2.tex` before §6 is rewritten —
the framing of the chapter's contribution depends on the answer. See the Ch 2 item below.

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

## 🟣 Chapter 2 dependency — does the formal structure admit partial runs?

**22. Resolve whether Goldstein–Pauzner can talk about cascade size, before §6 is
rewritten.** New 2026-08-16. This is a Ch 2 question that gates a Ch 3 framing decision,
so it is tracked here as well as there.

Item 21 moves the P6b outcome from the binary `bankRun` to cascade size \|S*\|. Whether
that is a *refinement of* the global-games framework or a *departure from* it depends on
whether GP admits a partial run at all:

- In the σ → 0 noise limit that delivers uniqueness, every late consumer withdraws below
  θ\* and none above it. The withdrawing fraction is degenerate and the run is
  all-or-nothing **by construction of the limit**, not by assumption about behaviour.
- Away from the limit (σ bounded away from 0) the withdrawing fraction is continuous in
  θ, so partial runs exist — at the cost of the uniqueness argument.
- ⚠️ **The interesting possibility, and it needs checking against `chapter2.tex` rather
  than asserting:** with heterogeneous λ the coupled fixed point gives two thresholds,
  s\*_I ≠ s\*_C. For θ between them one type runs and the other does not, so the
  withdrawing fraction is ≈ (1 − μ) — a partial run that survives the σ → 0 limit and is
  *generated by* the cultural heterogeneity this dissertation introduces. If that holds,
  P6b is coherent with the formal framework rather than outside it, and the model predicts
  a plateau of partial runs of size (1 − μ) over an interval of θ whose width scales with
  the λ-gap. That is a sharper and more falsifiable prediction than P6b as currently
  stated, and it is directly testable against the \|S*\| distribution.

**Two framings, and the evidence decides which:**

| If the bridge exists | If it does not |
|---|---|
| P6b is a prediction *of* the heterogeneous-λ global-games model; \|S*\| is the natural observable; the ABM computes what the analytics characterises | \|S*\| is a question the equilibrium concept cannot pose, and the ABM's contribution is exactly that it can — which is the Ch 3 thesis anyway |

Either is publishable and the second is already the chapter's stated position. What is
not acceptable is writing §6 without knowing which one we are claiming.

Source material: `chapter2.tex`, `theory/gp_walkthrough.tex` and `theory/fig_v.py` (the
2026-08-14 derivation from primitives, verified numerically), `REPOSITORY_REVIEW.md`
§Role in Endogenous Decision-Making for the coupled fixed point.

---

## 🟢 Done 2026-08-17 — the analysis chain

**23. `--compare <tag>` wired into `run_all.sh`.** Until today nothing in the pipeline
ever set `BANKRUN_COMPARE_DIR`, so the chapter's headline statistic was reachable only
by hand-exporting an environment variable. `analysis_p6b.R` now runs as its own SLURM
job (`bankrun-<tag>-p6b`, `--no-p6b` to disable), and `--compare` threads the contrast
arm through. Guards: refuses a self-compare (which would return an exactly-zero
difference that reads as a clean null), refuses a missing arm directory, and warns
loudly when run without `--compare` that the P6a curvature confound is *not*
differenced out.

**24. The insurance interaction is now estimated.** `analysis_p6b.R` emits a second
stratification adding `depQuantile`, giving `depQuantile × λ-gap` — the reduced-form
test of whether a deposit-insurance backstop dampens social-signal weighting. This
answers the committee's FDIC/social-learning question on the arms already running, at
zero simulation cost. ⚠️ Reduced form only: λ is assigned at warm-up and never learned;
the structural version is `future_work.md` item 1. ⚠️ And `depQuantile` is a share of
depositors **by count** — at σ = 3.0, q = 0.5 insures ~0.7% of deposit *value*.

**25. Plotting packages are no longer load-bearing.** `analysis_p6b.R` required
ggplot2+scales at preflight, so a missing *plotting* library aborted the run before any
number was computed — the exact shape of the 08-16 wall. data.table is now the only hard
requirement; figures degrade to a warning and every CSV is still written.

---

**26. Visualisation module for run dynamics — added 2026-08-17.**
`scripts/viz_cascade.py` + `scripts/viz/` + `scripts/dump_network.jl`, validated by
`tests/test_cascade_reader.py` (26 PASS). Four views of a single run: cascade timeline by
type, vault depletion, propagation distance, and the cascade on the real network (static
panels for the chapter, GIF for the defense).

⚠️ **`figures/fig5_network_snapshot.png` should be retired when view 4 first runs on real
data.** `make_figures.py:216` builds it from a fabricated `networkx` graph with an
illustrative BFS — no model output at all — and it calls `nx.watts_strogatz_graph` while the
model runs `newman_watts_strogatz`, so its caption is wrong in the same baked-into-the-PNG
way as `fig2`. That is the figure-side face of item 11.

📌 **View 3 is a diagnostic, not decoration.** It answers item 6's warning — whether this
model's contagion is spatial at all, or whether `blendedTotal`'s population term makes it
mean-field — on ONE cell, before the arms land. Validated two-sided against fixtures: a
non-spatial cascade returns rho = −0.113 ("mean-field"), a neighbour-driven one returns
rho = +0.643 ("spatial").

⚠️ The network is *regenerated* from the cell's genSeed, not recorded by the model.
`parameterGen.jl:37` seeds and nothing consumes the RNG before the graph call at line 107,
so it is exact — but only under the same Julia and Manifest, and it is **not verified
byte-identical to what the sweep used**. Airtight verification needs the model to emit an
edge hash per task: one line, worth batching with item 12. Captions must say "regenerated
from the cell's seed".

**✅ 27. NARROWED 2026-08-19 — the results files do NOT tear. The endogenous ones do.**
`tests/diagnose_short_cells.py` read every `bankRunResults*.csv` in both arms — 4,320
cells, ~1.08M rows — and found **zero malformed lines**. Tearing does not explain the
249/250 and does not touch the P6b outcome, because item 21 moved that outcome to
`nWithdrawn`, which lives in the 4-column results row.

⚠️ **What survives of this item:** `bankRunEndogenous1.csv` really is **1.69% malformed**
(3,656 blank, 3,652 one-field, 63 two-field of 435,934). Fifteen workers append with no
coordination; a results row is one line per *run* and an endogenous row is one line per
*decision*, so the collision rate differs by orders of magnitude. That still matters for
`scripts/viz_cascade.py` and for any legacy \|S*\| extraction (item 3), which have the
endogenous files as their only source. Strict readers only — a padding reader hides it.

**✅ 28. RESOLVED 2026-08-19 — the 249/250 was a check-off-before-write race.** New today.
`modelCall()` called `checkOff` *before* writing its result row and then waited on the
check-off with a `sleep(1)` poll, while `finMain0001.jl:149` exits the master loop the
instant `sum(completed)` reaches nrow and falls off the end of the script — tearing down
the worker pool with the last worker still inside that poll.

Diagnosed positionally, which is what separates it from tearing: **120 of the 128 missing
runs sit in the last 20 rows of the frame** (93.75% against an 8% positionally-random null,
35.8 sigma, p = 1.7e-120). All 128 are marked `completed` in the master's own ledger and
all 128 have their 1,000 agent rows on disk, so the run executed and only the result row
was lost. Fixed in `9be29d7`: write first, then check off, plus a future drain before the
master exits. Validated by *execution* — a reduction of both files loses exactly one row in
6 of 12 trials under the shipped order, never more than one, and zero in 12 of 12 under the
corrected order.

⚠️ **hopper needs `git pull` before the next arm is submitted.** The two finished arms are
unaffected and are **not** worth re-running: 128 lost runs of 1,080,000 is 0.012%, and a
249-run cell mis-states its own failure rate by at most 0.12 pp.

📌 One line for §5's methods, and it is the honest version of the caveat: the lost run is
by construction *the last to finish in its cell*, so the loss is selected on run duration
rather than random. The tail of the position distribution is the evidence — a run pulled at
frame position 179 that still finished last was ~5x the typical duration. At 0.012% of runs
this changes nothing, but it should be stated as selection rather than as attrition.

---

## 🟠 Open — new arms worth running once the smoke run passes

**6 (was 5, PROMOTED 2026-08-16). Warm-up placebo — this is the P6b identification
strategy, not a robustness check.** `./scripts/run_all.sh --assignment random --tag placebo`
(optionally `--assignment reverse --tag anti`).

P6a is a **composition** effect: it depends only on how many agents carry λ_I rather than
λ_C. P6b is a **position** effect: it needs individualists to ignite cascades that reach
collectivists, which depends on where they sit in the network. The placebo holds
composition exactly fixed — same count of each type, same λ distributions, same network,
same deposits, same shock — and destroys only the type↔position correlation. So P6a
survives it and P6b should not.

That makes `excess(treatment) − excess(placebo)` a targeted P6b estimate which **cancels
the P6a-curvature confound**, because P6a's shape is identical across arms by
construction. No statistic computed on a single arm's μ curve can do this: the chord
baseline assumes P6a is linear, §6.4 says it isn't, and a concave P6a produces positive
excess with no hump at all. Demonstrated on fixture B in `scripts/analysis_p6b.R` — a
world with **no P6b** but concave P6a returns a positive within-arm excess and a
contrast of −0.38 pp.

Assumption, and it is checkable: random assignment must leave P6a untouched. At μ = 0 and
μ = 1 only one type is present, so P6b is zero by construction and any between-arm gap
there is contamination. `analysis_p6b.R` writes it to `endpoint_contamination.csv` —
read it before trusting the contrast.

⚠️ Also a test of whether this model's contagion is **spatial at all.** `blendedTotal`
mixes in `totalWithdrawnPoint`, which is at least partly a population-level estimate
(item 9). If the signal is effectively mean-field, network position cannot matter and the
placebo returns nothing — which would not be a null result about culture, it would be a
finding about the model, and it would qualify the percolation framing in §6.9.

The symmetry with Ch 1's surname placebo is worth saying out loud when pitching it to
Schuler.

**5 (was 6, DEMOTED). P6b at k = 10, 50** (action 27).
`./scripts/run_all.sh --k 6 10 50 --tag p6b-density` (6,480 cells). §6.9 predicts the P6b
interior peak appears on dense networks and vanishes on sparse ones — and the focused
sweep pinned k = 6. Still worth running, but it is a conjecture about *where* P6b lives,
whereas the placebo is a design that detects it wherever it is. Run the placebo first.
⚠️ Do not run this arm until item 20 is closed — as of 2026-08-16 it is, so this is
unblocked.

**7. Depth sensitivity** (`--depth 1000 --tag depth1000`). Doubles as the regression check
against the legacy headline. ⚠️ **Needs a walltime far past 2h**: the smoke cell took
51:48 at depth 100 and the MC inner loop (`functions4.jl:433`, serial) is the dominant
cost. This is the likeliest explanation for the 2026-04 TIMEOUTs clustering at high
reserve, where runs last longest. MC standard error is ~0.016 at depth 1000 vs ~0.050 at 100;
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
| 11 | Newman–Watts vs classic Watts–Strogatz mislabel in §5's parameter table | `draft/paper_draft.md` |
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
| 18 | ✅ **CLOSED 2026-08-19.** `checkOff` is not under `rowLock` though `rowPull` is — but it cannot race. It runs on process 1 via `@spawnat`, master-side tasks are cooperatively scheduled on one thread, and the assignment has no yield point. Refuted empirically too: a dropped check-off would leave the row incomplete and the master would spin to walltime, and **no** missing run was unmarked. Asymmetric, not racy | none |

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
- **`draft/paper_draft.md` §5.1's "Monte Carlo depth D is fixed at 1,000"** is deliberately
  unchanged — it correctly describes the sweep that produced the current §6.6 numbers.
  Update it together with item 2, when new numbers land.
- **`draft/paper_draft.md` §7 / `draft/abm_chapter.tex`** carry an uncommitted edit removing the
  religiosity-channel sentences. Commit with the rest.
- **`future_work.md`** (tracked) holds the four proposed extensions: adaptive-λ social
  learning, NN surrogate for the MC inner loop, differentiable ABM, validation
  benchmarking.
