# Rung 4 pre-registration: OUTLINE (started 2026-10-22)

Status: S1 decided by the user 2026-10-22 (below; under CARA 0.1); prose by the user. Rung 4 is Ch 2
indirect calibration (pilot_map feature list F13–F15): Ch 2 evaluates the ABM, it never
shapes it, so every statistic is fixed here before the arms that test it run.
Statistics: S1, the one-shot exit share by depositor size (F12); S2–S4, stylized
facts from the bank-run literature, tested by sign (added 2026-10-22, the user
approved the scorecard). Still to add: the near-full-exit gap by type, and
timing/hazard (F13).

## S1. One-shot exit share by depositor size

### Claim
Larger depositors exit more gradually. Celsius (F12, `whale_timing.py`): the share
of exiters who left in one day falls from ~85% (D1–D5) to 52% (D10), 38% (top 1%)
and 35% (top 0.1%). The ABM under `WITHDRAW=partial` should produce the same
gradient, because only depositors large enough to move the bank gain from an
interior fraction. Note that the gradient was not used to build the rule: the rule is
the expected-value comparison, and the size cutoff is a computational shortcut that
makes the same decisions as no cutoff (tests/test_partial.jl E).

### Definitions
| | Celsius | ABM |
|---|---|---|
| Unit | user with a positive balance on 2022-05-07 | agent not hit by the exogenous shock |
| Size | `bal_total_same` on 2022-05-07 | deposit at the start of the run |
| Size groups | deciles of ~541K users; top 1%; top 0.1% | deciles of the bank's own 1,000 deposits; top 10 agents (1%); the largest agent (0.1%) |
| Exiter | retained < 0.95 by 2022-06-12 (`bal_total_last`) | withdrew anything endogenously (f > 0) |
| One-shot | the largest single-day net outflow ≥ 0.95 of its total outflow (days with outflow > 1% of peak) | every endogenous withdrawal in one tick (an agent decides once per tick, so: one withdrawal) |
| Data | `whale_timing.py` at ae057b1 (negative-balance users dropped), Hopper rerun | new per run × type × size-group output (to build; see below) |

Known asymmetries, stated now:
- A Celsius day can hold several decision rounds, so Celsius's one-shot is the
  looser definition. At equal behaviour the ABM's one-shot share is biased *down*.
  The relational test (the sign of the gradient) is not affected.
- In the ABM, agents below 1% of the bank's capacity cannot choose a fraction, so their
  one-shot share is 1 by construction. Celsius small depositors sit at ~0.85.
  **Levels at the small end are therefore not a test**; the gradient is.

### Test
- [x] **Decided (user, 2026-10-22). Primary (relational):** the one-shot share among exiters is lower in the top
  decile than in D1–D5 pooled, and lower for the largest agent than in the top
  decile. Pooled over runs; CR1 SEs clustered on the initialisation (as rung 1);
  one-sided.
- [x] **Secondary (plausibility, F15):** is Celsius's curve (D6–D10, top 1%, top
  0.1%) inside the ABM's run-to-run distribution of the same curve? It is reported,
  not pass/fail, until F15's acceptance-region method is fixed.
- [x] **Decided (user):** also report the partial-exit share (exiters who keep part of their balance)
  by size. Celsius top 0.1%: 25% partial vs 29% full exit.

### Arms and cells
- [x] **Decided (user):** the rung-1 reference setting under `WITHDRAW=partial` (r 0.05, d 0.6, e 0.06,
  R_stay 1.1, theta signal s 0.10, uninsured), pooled over the mixed cells
  (mu 0.25 / 0.5 / 0.75) and the 3 lambda pairs. Primary sigma 2.5; sigma 1
  reported (prediction: little or no gradient, since no depositor moves the bank).
- [x] **Decided (user):** primary arm has no public signal (THETA_PUBLIC=none), so
  the size gradient is not mixed with the y effects.
- [x] **Decided (user, 2026-10-22): CARA 0.1** (BANKRUN_CARA; pilot_map F12b).
  Risk-neutral depositors never split (r1p), so S1 is run under CARA. The value
  was chosen from the smoke's P(fail), D and splitting counts, before any
  statistic by size (S1, S2b) was looked at.
- Primary arm (sigma 2.5): **r1c-none** in arms/rung1_cara.tsv (the same
  switches); sigma 1: r4-s1-s10 in arms/rung4_s1.tsv.
- These arms run **after** this file is decided and the output below is built.
  r1p-* does not record S1, and is not used for it.

### Output (built 2026-10-22)
`bankRunExitShape` (functions4.jl exitShapeRows; `consolidated_exitshape.csv`): per
run × type × size group (D1–D10, top 1%, top 0.1%): agents not hit by the shock,
endogenous exiters, one-shot exiters (a single endogenous withdrawal), partial
exiters (part of the deposit still in at the end). Written by partial runs only.
tests/test_neighbour_output.jl D.

### What would count against
- The top decile's one-shot share is not below D1–D5's (no gradient) at sigma 2.5.
- The gradient appears at sigma 1 as strongly as at sigma 2.5. That would mean it
  is not driven by size relative to the bank.

## S2–S4. Stylized facts from the bank-run literature (signs)

Added 2026-10-22: the user approved testing these as signed hypotheses. The
statistics below are drafted for the user's review. There is no usable aggregate
benchmark, such as the probability of a run or the share of a population that
runs: crisis-frequency data do not map to "one bank, conditional on a shock". So
these are individual-level facts, tested by sign as in rung 1. Sources are cited
from memory; check them before citing.

| ID | Fact | Source | ABM statistic | Predicted sign | Data |
|---|---|---|---|---|---|
| S2 | Uninsured and larger depositors are likelier to run | Iyer & Puri (2012, AER); Martin, Puri & Ufier (deposit flows in failing banks) | (a) withdrawal rate of uninsured minus insured (insured = deposit <= cap), run for run; (b) withdrawal rate of the top size decile minus D1–D5 | > 0 | types (nInsured, nEndogInsured), wealth deciles |
| S3 | A depositor is likelier to run when its network contacts have run | Iyer & Puri (2012); Kelly & Ó Gráda (2000), county-of-origin networks in the 1854/1857 Emigrant Savings Bank panics | slope of P(withdraw at a decision) in the share of neighbours already out (bankRunNeighbour bins) | > 0 | bankRunNeighbour (built 2026-10-22) |
| S4 | Runs are partial and outflows concentrate in large accounts | Cipriani, Eisenbach & Kovner (NY Fed, the March 2023 runs); Iyer, Puri & Ryan (2016, JF) | (a) head-count share who withdraw < 0.5 among survivors of the shock; (b) deposit share withdrawn minus head-count share (W$ − W) | (a) holds; (b) > 0 | types (nEndog, depEndog) |

Stated now:
- **S3 is partly built in.** Depositors weight the neighbour signal by λ, so a
  positive slope is close to mechanical. The informative part is the cultural one:
  the slope should be steeper for collectivists. Report the slope by type, and
  test C > I as S3b.
- S2a needs insured arms (the fire-sale sweep's insurance axis). S2b, S3 and S4 use
  the S1 arms.
- The ABM statistics are pooled over the mixed cells, with CR1 SEs clustered on the
  initialisation and one-sided tests, as in S1.
- Not testable, listed in the scorecard as such: Ch 2's threshold reactivity (P1),
  since the ABM has no discrete public events (F17, parked); run speed in calendar
  time, since ticks are not days.

## The scorecard (the validation figure)

One row per Ch 2 finding and stylized fact (S1–S4, Ch 2's P1–P3, the timing
result). The columns are the sign in Ch 2 or the literature, the ABM's sign and
estimate with its CI, and the verdict. Rows that cannot be tested are kept and
marked. Companion figures: S1 by size, and exit timing by type (the ABM's
cumulative exits by tick, next to Ch 2's Kaplan–Meier curves).
