# Rung 2: the nested one-shot limit (design note, 2026-10-31)

Rung 2 of the docking ladder (Axtell et al. 1996): configure the ABM so that it is
Chapter 1's game, and check that it reproduces the numbers of Chapter 1's solver
(`bank_runs_theory/sims/ch1_eta_solver.py`). Rung 1 (pilot_map F11) established
relational equivalence (signs); rung 2 asks for numerical identity. The relaxation
ladder (F10) then starts from this nest and relaxes one assumption at a time.

## Decisions (Walter, 2026-10-31)

1. **Belief: as is, first.** The nest keeps the ABM's own Monte Carlo belief about
   how many others withdraw. Chapter 1's cutoffs are an equilibrium (each type's
   cutoff a best response to the other's); the ABM's sub-simulations draw others'
   withdrawals from the agent's prior, which nothing ties to that equilibrium in a
   one-shot game. So the test asks whether the ABM's decision rule lands on Ch 1's
   equilibrium. A gap is a finding, located in the belief law. Best-response
   iteration across episodes (the EPISODES machinery) only if the gap is large.
2. **Uniform noise switch in the ABM** (not a Gaussian solver), so the solver stays
   as Chapter 1 states it.
3. Suspension of convertibility is in (separate build, after rung 2's code; it is
   one more rung on the ladder: Chapter 1's rationing footnote, −(1 − L)·min{1, K/A}).

## The nest

| | Chapter 1 | ABM switch / setting |
|---|---|---|
| Timing | one simultaneous decision | **new** `TIMING=oneshot`: every agent decides once against the same post-shock state; no ticks, no reconsideration |
| Fundamental | θ, R(θ) | `FUNDAMENTAL=theta`, θ ~ U[0, 1], R(θ) = R_lo + (R_hi − R_lo)·θ |
| Private signal | x_i = θ + e_i, e_i ~ U[−ε_x, ε_x] | `PRIVATE_SIGNAL=theta`; **new** `THETA_NOISE_DIST=uniform`, `THETA_NOISE` read as the half-width ε_x |
| Public signal | y, stale level; δ = y − θ varies | `THETA_PUBLIC=stale`, `THETA_PUBLIC_LEVEL` = y; `THETA_PUBLIC_NOISE` read as ε_y under uniform |
| Blend | θ̂_i = ω_J·y + (1 − ω_J)·x_i | λ on the θ blend (`LAMBDA_SCOPE=theta`); λ_I, λ_C as ω_I, ω_C (degenerate Beta, or report the type means) |
| Belief about θ | θ \| θ̂ ~ U[θ̂ ± w_J], w_J = (1 − ω_J)ε_x + ω_J ε_y | `thetaBelief` already has this window; uniform replaces the truncated normal (truncated to [0, 1]) |
| Impatient share | η (the solver's eta) | the exogenous shock, as a share of N |
| Depositors | identical, risk neutral, all or nothing | σ = 0 (`LogNormal(μ, 0)` gives equal deposits; checked), `CARA=0`, `WITHDRAW=all`, `DEPOSIT_CAP=0` |
| Bank | Rochet–Vives: pays every runner, fails in period 2 | `BALANCE=firesale`, `PAYOFF=recovery`; d small enough that no liquidity failure occurs in the nest's cells (checked per cell) |
| Payoffs | v = R − 1 if the bank survives, −(1 − L) if it fails | `STAY_RETURN` = R; see open item 2 for L |
| Population | continuum, shares μ, 1 − μ | N agents, μ; the network is irrelevant once open item 1 is settled |

### A*(θ) of the ABM's bank

Chapter 1 leaves A*(θ) general; the solver's assumption A1 makes it linear. The
ABM's fire-sale bank implies its own. Per unit of deposits: cash r, long asset
1 − r + e, discount d, stayers promised R_s per unit. With A withdrawn at par:

- A ≤ r: cash r − A, long asset unchanged;
- A > r: sell (A − r)/(1 − d) of the long asset, cash 0;
- liquidity failure (not in the nest) if A > r + (1 − d)(1 − r + e);
- solvent in period 2 iff cash + long·R(θ) ≥ R_s·(1 − A).

A*(θ) is the largest A that stays solvent: piecewise linear in A, by cases. The
bridge (F8) passes this A*(θ) to the solver in place of A1, and θ_L, θ_H follow
(A*(θ_L) = 0, A*(θ_H) = 1).

## What is compared (F8, F9)

- Solver: c_I, c_C (cutoffs in x), t_I, t_C (in θ̂), the failure threshold θ*, and
  A(θ), at the cell's parameters.
- ABM (F9): each type's empirical cutoff from the logged decisions (withdraw vs
  x_i, by type; a logistic or isotonic fit, with the switch point and its SE across
  runs), the empirical failure threshold in θ, and the withdrawal share against θ.
- Identity: solver values inside the ABM's 95% intervals, cell by cell, over a small
  grid (λ gap, μ, y, ε_x). The grid and the tolerance are fixed before the runs.

## Open items: decided 2026-10-31 (Walter, all four as recommended, for the docking with Chapter 1)

1. **The head-count belief in the nest.** In a one-shot game nobody observes others,
   but the ABM agent's neighbours include exogenous withdrawers. Recommendation:
   under `TIMING=oneshot` the head-count belief is the prior draws only (neighbour
   weight 0), so the network carries no information Chapter 1's agents lack.
2. **The failure payoff.** Chapter 1: a stayer in a failed bank gets L. ABM: it gets
   max(ρR, L), pro-rata recovery included. Options: (a) an ABM switch that pays
   failed-bank stayers L only, so the solver stays Chapter 1's (recommended: any gap
   is then the belief law's); (b) the solver adopts the ABM's recovery (a
   generalisation of Chapter 1, not Chapter 1).
3. **L ∈ (0, 1) at σ = 0.** The quantile cap is all or nothing with equal deposits
   (q = 0 gives cap 0, L = 0; any q > 0 covers the whole deposit, L = 1). The first
   cells run at L = 0; interior L needs a cap stated as a share of the deposit.
4. **Tie-break** at the margin (`TIEBREAK`): legacy, schuler or strict. Recommend
   strict for the nest (stay on a tie, as the solver's G = 0 is measure zero).

## Build steps

1. ~~`THETA_NOISE_DIST`~~ **BUILT 2026-10-31**: `normal` (default) | `uniform`;
   `thetaNoiseDraw` (modelRun and `episodeThetaDraws`, one draw per agent either
   way), `thetaBelief(...; uniform)` = U[est ± w] truncated to [0, 1], Rule A's prior
   MSE s²/3 under uniform (`thetaNoiseVar`). tests/test_balance_sheet.jl I.
2. `TIMING=oneshot` in `modelRun`, tests: one tick, every non-exogenous agent decides
   once against the same frozen state; the default path byte-identical.
3. Open items 1, 2 (and 3 if interior L is wanted) as switches.
4. F9 cutoff estimator (LOG=full on small arms), F8 bridge (A*(θ) above into the
   solver), a nest arm file, then the comparison.
