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
| p2c (pending) | `phase2c_gate_r20_r25.tsv` | the gate at sigma 1, r 0.20 and 0.25 | — |

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

## Implications for the systematic sweep (draft)

1. **Decide what sigma represents before it is an axis.** At sigma 3 the model is
   mostly a single-depositor model (F1); at sigma 1 it is a cascade model. If the
   chapter's mechanism is the cascade, either keep sigma <= ~1.5 or make
   concentration an explicit treatment (e.g. a separate largest-depositor share
   axis), not a nuisance level.
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

- p2c: the gate at r 0.20 and 0.25 (pending).
- Where is the sigma 1 transition for other mu and lambda pairs? (Does culture move
  the transition, or only P(run) within it?)
- R = 1.25: does it move the no-shock failure boundary (F4) and the transition (F3)?
- Initialisations per cell: a pilot at one non-saturated cell with 25 x 10 against
  5 x 50, to size the between-initialisation component directly.
- Insurance quantile q > 0 at sigma 1: the cap is a quantile of the theoretical
  distribution, so its bite on large depositors depends on sigma.
