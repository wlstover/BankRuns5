# Pilot map — where the model is sensitive, before the systematic sweep

Started 2026-10-21. A running ledger of small pilot arms: what each asked, what it
found, and what that implies for the design of the systematic sweep. The rule
(2026-10-21): answer one question per pilot with the smallest paired arm set, map
transitions and saturation first, and design the large sweep only from what this
file records. Arms files (`arms/*.tsv`) carry the per-arm settings; this file
carries the results and their consequences.

## Conventions for pilots

- **Hold the banks fixed.** `GEN_SEED = SEED_OFFSET + array index`
  (`scripts/sweep_task.slurm`), and `GEN_SEED` draws the five initialisations
  (`paramSeed`) of a cell. A multi-cell arm therefore gives every cell different
  banks. To compare cells on the same banks, use single-cell arms at the same seed
  offset (task 1, `GEN_SEED` 1001 at offset 1000). Every pilot below does.
- **Pair the arms.** Arms that differ only in a switch, at the same seed offset, run
  the same `(paramSeed, seed)` pairs, so their differences are run-for-run.
- **One cell is 250 runs = 5 initialisations x 50 runs.** Between-initialisation
  variance is large (below), so a cell's P(run) is partly a statement about five
  banks. Report P(run) by `paramSeed` alongside the cell mean.
- Logs: `BANKRUN_LOG=summary`; replay a run with `scripts/replay_run.jl` for the full
  per-agent logs.

Reference cell (unless stated): k 6, p 0.05, q (insurance quantile) 0, warm-up
alpha 0.1, mu 0.5, lambda (0.1, 0.9), N = 1,000, MC depth 100, fresh clone, legacy
tie-break, geometric belief, R = 1.

## Ledger

| pilot | arms file | question | answer |
|---|---|---|---|
| p2 (2026-10-20) | `phase2_shock_gate.tsv` | at r 0.30, sigma 2, does an informative private signal steepen P(run) in n_exog? | **FAIL**: slopes +0.087 / +0.094 / +0.097 / +0.096 per 10 exogenous withdrawers (none, s 2, 5, 20); P(run) at n_exog 0 = 0.304 in every arm |
| p2 replay (2026-10-21) | `outputs/replay-p2/` | why? | two of five initialisations ran in every run of every arm: one depositor dominated each bank (753714: 56% of deposits, 1.9x the vault; 455326: 92% of the vault). The signal did shrink cascades (-5.7 / -3.7 / -1.3 agents at s 2 / 5 / 20) |
| p2b (2026-10-21) | `phase2b_sigma1.tsv` | the same gate at sigma 1 | **uninformative**: P(run) = 0 in all 1,000 runs; mean cascade 3 agents; arms indistinguishable |
| p2s (2026-10-21) | `phase2s_reserve_scan.tsv` | at sigma 1, where is the reserve transition? | between r 0.10 and 0.30 (table F3) |
| p2c (2026-10-21) | `phase2c_gate_r20_r25.tsv` | the gate at sigma 1, r 0.20 and 0.25 | **FAIL at r 0.20** (F8); r 0.25 has no runs. Every arm was submitted twice into the same directory (19:12, 20:18); the copies are identical run for run, so analyses use one copy |
| Celsius benchmark (2026-10-21) | `bank_runs_celsius/src/analysis/deposit_concentration.py` | what sigma does a real depositor base have? | ~2.55 (F7) |

## Findings

**F1. sigma is deposit concentration, and above ~2 it decides runs through single
depositors.** Deposits are `LogNormal(1, sigma)` (`parameterGen.jl` L75–78, mu = 1
fixed in `sweep_task.slurm`); the median is e at every sigma, the mean
exp(1 + sigma^2/2). The draw resets to `seed1`, so the same initialisation keeps its
depositor ranking across sigma (only the spread changes). Simulated at N = 1,000:

| sigma | largest deposit's share (median, p90) | top 1% share | P(largest > vault at r 0.30) |
|---|---|---|---|
| 1 | 1.5%, 2.4% | 9% | 0.000 |
| 2 | 8.6%, 19% | 34% | 0.032 |
| 3 | 23%, 52% | 65% | 0.33 |

Under the legacy tie-break a depositor whose deposit exceeds the vault withdraws
(P(full | WD) = 0) and fails the bank, so at sigma 3 a third of banks are decided by
one agent before any cascade.

**F2. The shock is small: failures need a cascade unless one deposit is huge.** The
exogenous withdrawers hold 0.6% of deposits at the median and 4.1% at the 99th
percentile (sigma 1). The shock alone empties the vault only at r 0.03 (2.8% of runs).

**F3. At sigma 1 the reserve transition is sharp and lies between r 0.10 and 0.30.**

| r | P(run) | mean endogenous withdrawers | mean ticks |
|---|---|---|---|
| 0.03 | 1.000 | 22 | 1.0 |
| 0.05 | 1.000 | 38 | 1.0 |
| 0.08 | 1.000 | 64 | 1.3 |
| 0.10 | 0.988 | 80 | 2.1 |
| 0.15 | 0.732 | 106 | 4.7 |
| 0.30 | 0.000 | 3 | — |

At r 0.15, P(run) by n_exog: 0.00 (0), 0.46 (1–3), 0.86 (4–7), 0.96 (8–12),
0.94 (13–20), 1.00 (21+): a strong shock response already under the uninformative
prior, with a ceiling by n_exog ~8.

**F4. At low reserves banks fail with no shock at all.** At r <= 0.08, P(run) = 1.00
at n_exog = 0. With R = 1 an agent withdraws unless every Monte Carlo draw pays in
full, and the uninformative prior alone predicts enough withdrawals to sink a
thin vault in some draw. Such cells cannot test any signal; R > 1 (the rung-1 R 1.25
arms) is the lever that should move this boundary.

**F5. Bank composition persists at sigma 1.** At r 0.15, the two formerly dominated
banks (455326, 753714) fail in 90% of runs, the other three in 62%. (The three sit at
exactly 31/50 and the two at 45/50; probably chance at 50 runs each, but recheck if it
recurs.)

**F6. Production-v2 (focused grid, 2,160 cells, sigma {2, 3}, r 0.15–0.40) is
saturated over much of its range, and its P(run) is substantially an
initialisation outcome.** First pass, from `outputs/production-v2`:

| r | P(run) sigma 2 | sigma 3 | cells saturated (P = 0 or 1), sigma 2 | sigma 3 |
|---|---|---|---|---|
| 0.15 | 0.914 | 0.997 | 6% | 77% |
| 0.20 | 0.688 | 0.971 | 0% | 29% |
| 0.25 | 0.407 | 0.887 | 1% | 11% |
| 0.30 | 0.240 | 0.762 | 4% | 1% |
| 0.35 | 0.150 | 0.626 | 17% | 1% |
| 0.40 | 0.064 | 0.482 | 44% | 1% |

Per initialisation (50 runs each): at sigma 2, 15% run in every run and 34% never
run; at sigma 3, 56% run in every run. In non-saturated cells the spread of
initialisation means is a median 19% (sigma 2) and 31% (sigma 3) of the cell's
binomial variance p(1-p), against ~2% expected from 50-run sampling noise alone.
Because every production cell has its own banks (convention 1), cell-to-cell
contrasts along mu and lambda mix the axis effect with a five-bank draw.

**F7. Celsius's depositor base matches sigma ~ 2.55, so a realistic bank is in the
whale regime.** `bank_runs_celsius/src/analysis/deposit_concentration.py` (Hopper,
2026-10-21; output `outputs/analysis/deposit_concentration/`), ~541K users with a
positive balance on 2022-05-07 at same-day prices (2022-04-20 and final-day prices
agree within 0.1). Over 2,000 random banks of N = 1,000 users, the log-normal sigma
matching each median is 2.45 (largest share), 2.40 (top 1%), 2.60 (top 10%), 2.60
(Gini), 2.55 jointly. Dust does not drive it: a $100 floor keeps 99.96% of dollars,
and sd(log) is then 2.03 (4.70 unfloored). The tail is heavier than log-normal (Hill
tail index ~0.89 on the top 10%), but at N = 1,000 sigma ~ 2.5 reproduces the
whale probability P(largest > r x total) within ~0.04:

| r | 0.10 | 0.15 | 0.20 | 0.25 | 0.30 | 0.40 |
|---|---|---|---|---|---|---|
| Celsius | 0.697 | 0.458 | 0.319 | 0.234 | 0.167 | 0.090 |
| log-normal sigma 2.0 | 0.379 | 0.180 | 0.090 | 0.052 | 0.036 | 0.015 |
| log-normal sigma 2.4 | 0.700 | 0.435 | 0.271 | 0.181 | 0.123 | 0.057 |
| log-normal sigma 2.55 | 0.780 | 0.518 | 0.342 | 0.229 | 0.157 | 0.086 |

External benchmarks point the same way: SCF 2022 household transaction accounts
(median ~$8,000, mean ~$62,410; secondary sources) imply sigma ~ 2.0 if log-normal;
business-heavy banks are far more concentrated (FDIC 2023: SVB's top depositors,
>= $49M, held 39% of deposits). And the largest and uninsured depositors are the ones
who run (Iyer, Puri & Ryan; Martin, Puri & Ufier; FDIC 2023), so the whale channel is
empirically real, not only a model artifact.

**F8. The phase 2 gate fails at sigma 1 too, and the reason is structural: a private
signal of the shock is redundant once the agent's sub-model already contains it.** At
r 0.20 (P(run) 0.092 with no signal) the slope of P(run) per 10 exogenous withdrawers
is +0.158 (se 0.033) with no signal, +0.152 / +0.154 / +0.120 at s 2 / 5 / 20: no arm
is above the no-signal arm. The informative signal *reduces* runs instead: P(run) 0.092
-> 0.076 / 0.076 / 0.072; paired run for run, s 2 turns 7 runs into non-runs and 3
non-runs into runs, and cuts withdrawers by 3.5 on average (s 5: -3.8, s 20: -2.2),
as in the sigma 2 replay (-5.7 / -3.7 / -1.3). At r 0.25 no bank fails in any arm,
so the sigma 1 transition is between r 0.15 (0.73) and 0.20 (0.09).

Why: the posterior draws replace the agent's draws of the run's *total*, centred on
the realised shock n_exog. Every decision state (fresh clone, stale view, stale clone)
already contains the shock, so alreadyOut >= n_exog, and an informed, mostly-private
agent forecasts max(0, ~n_exog - alreadyOut) = 0 further withdrawals: "the run is
over". The signal can only reassure. In Chapter 1 the private signal is about the
fundamental theta, which depositors do not observe; the vault-only ABM has no theta,
so it has nothing unobserved for a private signal to reveal. The gate cannot pass
until the model has a fundamental, which the fire-sale balance sheet (Ch 1's baseline,
decided 2026-10-21) supplies: the private signal should be of theta (the illiquid
asset's return), not of the shock.

## Implications for the systematic sweep (draft)

1. **sigma's realistic level is ~2.5 (F7), which is the whale regime.** sigma 1 is a
   no-whale counterfactual that isolates the cascade (useful for mechanism pilots
   such as the phase 2 gate), not a realistic level. At sigma ~2.5 a sixth to a third
   of banks hold a depositor the vault cannot cover, so the whale's decision rule
   decides those outcomes. Today it falls out of the tie-break (legacy: withdraw when
   P(full | WD) = 0; strict: stay) under an all-or-nothing payoff; a real large
   depositor takes a partial payment. Settle that rule deliberately before the
   sweep, and record per run whether a whale or a cascade failed the bank, so the two
   mechanisms can be analysed separately.
2. **Pack reserve levels around the transition, per sigma.** At sigma 1 the action is
   r 0.10–0.30 (F3); at sigma 2 it is r 0.20–0.35 (F6). Even 0.05 steps cross most of
   the transition in two levels.
3. **Hold banks fixed across cells (common random numbers).** Give every cell the
   same initialisations (seed by initialisation, not by array index) so that axis
   contrasts are paired. This needs a change in how `GEN_SEED` is formed for the
   sweep, not only single-cell arms.
4. **More initialisations per cell, fewer runs per initialisation.** With between-
   initialisation variance this large (F6), 5 x 50 spends most runs re-measuring
   five banks; e.g. 25 x 10 at the same cost estimates the cell mean better.
5. **Exclude cells that fail with no shock** (F4) from any signal or culture
   contrast, or move the boundary with R first.

## Open questions / next pilots

- Redesign the gate for the fire-sale model: a private signal of theta, not of n_exog (F8).
- Where is the sigma 1 transition for other mu and lambda pairs? (Does culture move
  the transition, or only P(run) within it?)
- R = 1.25: does it move the no-shock failure boundary (F4) and the transition (F3)?
- Initialisations per cell: a pilot at one non-saturated cell with 25 x 10 against
  5 x 50, to size the between-initialisation component directly.
- Insurance quantile q > 0 at sigma 1: the cap is a quantile of the theoretical
  distribution, so its bite on large depositors depends on sigma.
