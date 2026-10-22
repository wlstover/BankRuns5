# Rung 4 pre-registration: OUTLINE (started 2026-10-22)

Status: S1 decided by the user 2026-10-22 (below); prose by the user. Rung 4 is Ch 2
indirect calibration (pilot_map feature list F13–F15): Ch 2 evaluates the ABM, it never
shapes it, so every statistic is fixed here before the arms that test it run.
First statistic: S1, the one-shot exit share by depositor size (F12). Others to add
later: the near-full-exit gap by type, timing/hazard (F13).

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
- These arms run **after** this file is decided and the output below is built.
  r1p-* (submitted 2026-10-22) does not record S1, and is not used for it.

### Output to build (before the arms)
`bankRunExitShape`: per run × type × size group (D1–D10, top 1%, top 0.1%): agents,
endogenous exiters, one-shot exiters, partial exiters. A partial run only.

### What would count against
- The top decile's one-shot share is not below D1–D5's (no gradient) at sigma 2.5.
- The gradient appears at sigma 1 as strongly as at sigma 2.5. That would mean it
  is not driven by size relative to the bank.
