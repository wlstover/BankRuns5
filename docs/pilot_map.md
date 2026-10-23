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
| p3 (2026-10-21) | `phase3_firesale_gate.tsv` | fire-sale bank: does a private signal of theta steepen P(run) in theta? | **PASS at both sigmas** (F9): paired slope differences -0.46 / -0.55 / -0.58 at sigma 1, -0.14 / -0.15 / -0.20 at sigma 2.5 (s 0.20 / 0.10 / 0.05) |
| fire-sale smoke (2026-10-21, local) | one cell via `finMain0001.jl`, depth 50 | does the fire-sale + theta model run end to end, and where does it fail? | 250/250 runs, 0 switch mismatches. At sigma 2.5, r 0.10, d 0.5, e 0.08, theta signal s 0.1: P(run) 0.06, all at theta <= 0.1 (dominance) bar one liquidity failure; cascades 30-90 of 1,000 agents against A* 0.13-0.32 of deposits. Recalibrated the phase 3 arms to r 0.05, d 0.6, e 0.06 (A* 0.05-0.20) |
| cal (2026-10-22) | `calib_d_scan.tsv` | at sigma 2.5, where do liquidity and insolvency failures sit in r x d? | d is the lever; r 0.05, d 0.6 has the widest coordination band (21%) over a small whale floor (4.7%) (F10). cal-r05-d60 reproduces p3-s25-theta-s10 run for run |
| r1t (2026-10-22) | `rung1_theta.tsv` | relational equivalence: do Ch 1's G1-G4 signs hold with stale y on the fire-sale bank? | **3 of 4 confirmatory tests support** (G1', G4', G2a'; G2b ordering holds). Pre-registered G3 counts against: it passes Holm pooled (p 0.034) but (0.3, 0.5) is wrong-signed (t -2.5); the channel-isolated G3c (post hoc) passes in every pair. corrects-y80-r50 sorts between stale and tracks and fades by tick 4 (F11) |
| whales (2026-10-22) | `bank_runs_celsius` deposit_concentration (sec. 4), whale_timing | can one depositor sink the platform, and how do large accounts exit? | no (largest account 0.94%, largest user-day 0.69%); exits grow more gradual with size (one-shot 85% small -> 35% top 0.1%). ABM: partial withdrawals (F12) |
| r1p (2026-10-22) | `rung1_partial.tsv` | do rung 1's signs survive partial withdrawals? | trivially: risk-neutral depositors never split, so head-count D, failure and the withdrawers match r1t run for run (F12b) |
| cara smoke (2026-10-22) | `scripts/cara_smoke.sh` (local, 75 runs per value) | does CARA make large depositors split, and at what cost to fragility? | yes from CARA 0.1; P(fail) rises with CARA, D does not move (F12b) |
| r1c (2026-10-22) | `rung1_cara.tsv` | rung 1 and rung-4 S1-S4 under CARA 0.1 | **rung 1 unchanged** (all four pooled tests as F11; G3's (0.3, 0.5) still wrong-signed). P(fail) +0.03 vs r1p, 108 failures added, 6 removed. **S1a, S2b, S3, S4a support; S1b and S4b count against** (F12c) |
| r4-s1 (2026-10-22) | `rung4_s1.tsv` | S1's sigma 1 control | no gradient (D10 - D1-5 -0.0007, vs -0.046 at sigma 2.5); S3, S4a hold (F12c) |
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

**F9. The theta gate passes on the fire-sale bank, at both sigmas; at sigma 2.5 a
liquidity channel the signal barely touches sits under it.** `arms/phase3_firesale_gate.tsv`
(r 0.05, d 0.6, e 0.06, R(theta) in [1.0, 1.4], R_stay 1.1; 250 runs per arm, theta
shared run for run). Slope of P(run) in theta, and the paired difference from the
no-signal arm (regressing run_signal - run_none on theta):

| sigma | no signal | s 0.20 | s 0.10 | s 0.05 |
|---|---|---|---|---|
| 1: slope | -0.519 | -0.978 | -1.066 | -1.102 |
| 1: paired difference (se) | | -0.459 (0.071) | -0.547 (0.074) | -0.583 (0.077) |
| 2.5: slope | -0.561 | -0.703 | -0.706 | -0.757 |
| 2.5: paired difference (se) | | -0.142 (0.045) | -0.145 (0.045) | -0.196 (0.047) |

The steepening rises as the noise falls at both sigmas. At sigma 1 the signal turns
the bank into a theta-sorted one: P(run) at theta 0.1-0.3 goes from ~0.03 to ~0.67
(s 0.05), withdrawers at theta > 0.7 fall from 20 to 12, and paired, 33-40 non-runs
become runs against 1-3 the other way. Informed runs at low theta are mostly
liquidity failures (the bank sells everything), the uninformed ones insolvency.

At sigma 2.5 the effect is a third the size and overall P(run) barely moves (0.196
-> 0.196 at s 0.05; 6 flips each way). Under the theta-sorted failures sits a floor
of liquidity failures at mid and high theta: with no signal, 13 liquidity failures at
theta >= 0.4 (11.8% of runs at theta 0.5-0.7, still 11.8% at s 0.05). Period-1
capacity is r + (1 - d)(1 - r + e) = 0.454 of deposits, and in the median sigma 2.5
bank the largest depositor alone holds 38% of that capacity (sigma 1: 4%), so a few
large withdrawals sell the bank out whatever theta is. This is the whale channel of
F1/F7 surviving the fire-sale bank through illiquidity: it no longer fails a bank by
itself, but concentration times a steep discount does.

Implications: (a) the build order's step 1 is passed, so the calibration pilots can
run while stale theta is built; (b) at realistic concentration the fire-sale
discount d (period-1 capacity) is a first-order axis, not a nuisance: the
calibration pilot should scan d at sigma 2.5 and record failType, since the
liquidity floor and the theta-sorted failures respond to different levers.

**F10. The fire-sale discount d is the lever; r 0.05, d 0.6 is the rung-1 setting.**
`arms/calib_d_scan.tsv` (sigma 2.5, theta signal s 0.10, mu 0.5, lambda (0.1, 0.9)).
Failure rates by theta region: the dominance region theta < theta_L (fails with no
withdrawals; ~96-100% everywhere), the coordination band theta_L <= theta < 0.4
(failures that need withdrawals), and the high-theta floor theta >= 0.4:

| r | d | band | floor |
|---|---|---|---|
| 0.05 | 0.2 / 0.4 / 0.6 / 0.8 | 0 / 0.04 / 0.21 / 0.44 | 0 / 0 / 0.047 / 0.42 |
| 0.10 | 0.2 / 0.4 / 0.6 / 0.8 | 0 / 0 / 0.12 / 0.28 | 0 / 0 / 0.007 / 0.15 |
| 0.20 | 0.2 / 0.4 / 0.6 / 0.8 | 0 / 0 / 0 / 0.04 | 0 / 0 / 0 / 0.007 |

At d <= 0.4 selling is cheap enough that withdrawals almost never sink the bank:
failures are the dominance region only, with nothing for culture to sort. Between d
0.6 and 0.8 the whale floor switches on (liquidity failures at sound
fundamentals). r 0.05, d 0.6 has the widest band over a small floor and is the
rung-1 setting; r 0.10, d 0.8 is the alternative (wider band, 15% floor).
Labelling caveat: band failures are almost all failType = liquidity, because
solvency is tested only after the cascade stops, so a run already past A*(theta)
continues until the bank sells out. failType records how a run ended, not what
caused it. To build: the tick at which promises first exceed assets at R(theta).

**F11. Rung 1: relational equivalence holds for who runs and for reassurance; G3 needs the base subtracted.**
`arms/rung1_theta.tsv`, 10 arms x 3,750 runs, read with `scripts/rung1_relational.py`
(pre-registered, docs/rung1_prereg.md) and `scripts/rung1_timing.py`
(corrects arm). Head-count D, g 0.1, CR1 SEs on 25 initialisations, t(24):

| test | pooled | t | Holm | per lambda pair (0.1, 0.9) / (0.2, 0.8) / (0.3, 0.5) |
|---|---|---|---|---|
| G1' | +0.033 | 10.7 | reject | +0.052 / +0.039 / +0.007 |
| G4' | -0.024 | -10.6 | reject | -0.042 / -0.028 / -0.002 |
| G2a' | +0.077 | 12.1 | reject | +0.131 / +0.093 / +0.009 (G2b ordering holds) |
| G3 (pre-registered) | +0.002 | 1.9 | reject (p 0.034) | +0.005 / +0.003 / **-0.001 (t -2.5, wrong sign: counts against)** |
| G3c (post hoc, exploratory) | +0.018 | 17.6 | not in family | +0.032 / +0.021 / +0.002 |

- G1' split by failure in the no-public arm: +0.047 (fails) vs +0.024 (survives).
  g 0.05 and 0.2 give the same signs. D$ agrees on G1', G4', G2a'; D$ G3 fails
  pooled (t -0.95), D$ G3c passes (t 8.3).
- Why G3 fails and G3c passes: G3 compares |D| levels, and D starts near -0.10
  (head-count channel), so optimistic-y sorting moves D toward 0 and shrinks |D|.
  G3c = |D_stale - D_none| - |D_tracks-g0 - D_none|, run for run.
- Scope arms: levels G1 at (0.1, 0.9) is -0.12 with lambda in the count blend only
  and +0.12 with lambda in the theta blend only. The theta blend carries Ch 1's sign;
  in the `both` arms the count blend dominates the levels, so the levels G1 is
  wrong-signed at sigma 2.5. At sigma 1 (no whales) it is right-signed (+0.009 /
  +0.012 / +0.004).
- P(fail) at (0.1, 0.9): stale-y20 0.41, none 0.29, tracks-g0 0.28, stale-y50 0.24,
  stale-y80 0.16, corrects-y80-r50 0.22. An accurate public signal barely moves
  failure; an optimistic stale one cuts it. P(fail) rises with lambda dispersion in
  every arm.
- corrects-y80-r50 (y gap halves each tick): (a) whole-run |D_arm - D_none| among
  |gap1| > 0.1 is between stale-y80 and tracks-g0 in every pair (pooled 0.035 /
  0.027 / 0.015). (b) Optimistic side, mean D_t - D_t(none) by decision tick:
  identical to stale at tick 1 (same y), corrects/stale ratio 0.77 at tick 2, 0.53 at
  tick 3, about 0 from tick 4 (stale still +0.002, t 3.2). It fades more slowly than
  the gap (0.5, 0.25), consistent with earlier decisions feeding the head count. The
  pessimistic side (theta > 0.9, 234 runs) has no detectable sorting at any tick in
  either arm. Caveat: D_t conditions on the run still going at tick t.

**F12. Large depositors: no single Celsius depositor could sink the platform, and
large accounts exit gradually; the ABM gets partial withdrawals (2026-10-22).**
`bank_runs_celsius` f5bd680: `deposit_concentration.py` section 4 and
`whale_timing.py` (Hopper, 2022-05-07 -> 06-12).
- Platform: the largest account held 0.94% of deposits; the top 1% held 55%, the
  top 10% 90%. The largest single-user net outflow in a day was 0.69% of deposits.
- Scaled down to N = 1,000 by aggregation (each agent = ~542 users), the top agent
  holds 29% (sigma 3.15 jointly), more whale banks, not fewer: the tail (Hill
  ~0.89) concentrates further as the population grows. With one depositor per
  agent at N = 1,000, a realistic distribution and no decisive depositor cannot
  both hold.
- Exit timing by anchor-balance group, share of exiters who left in one day:
  D1-D4 84-90%, D5 82%, D7 73%, D9 63%, D10 52%, top 1% 38%, top 0.1% 35% (median 2
  out days over 5; largest day 76% of the outflow). Top 0.1%: 29% full exit, 25%
  partial, 45% stayed. Caveat: one user's outflow is 5,266x their peak (a negative
  reconstructed balance); drop such users before quoting.
- Decision (user, 2026-10-22): individual agents, sigma a reported axis (Celsius
  ~2.5 a plausibility marker, not a target); platform-scale docking later if at
  all. **BANKRUN_WITHDRAW=partial** built (fractions of the remaining balance by
  expected value; a partial withdrawal counts as withdrawing). The one-shot share
  by size above is a candidate rung-4 statistic (fix it in advance, F13).
  Super-individuals (Scheffer et al. 1995: an agent = a cohort of ~542 users whose
  withdrawal is the share of members who run) are a separate later run.
- Test sample (tests/test_partial.jl, N = 60, sigma 2.5): of endogenous
  withdrawals by depositors holding > 10% of deposits, 11 of 25 were partial (mean
  fraction 0.85); none below the 1%-of-capacity cutoff, and the cutoff makes the
  same decisions as none in 30 of 30 runs. *(Corrected in F12b: these were the
  failing withdrawal's tie, not real splits.)*

**F12b. Risk-neutral depositors never split; CARA makes them (2026-10-22).**
- r1p (10 arms, 37,500 runs paired with r1t): about 5.7M large-depositor decisions
  valued the interior fractions and none chose one, except on the withdrawal
  that fails the bank. There every fraction from some f up drains the bank and
  pays what the bank has, and the tie went to the smallest. So the number of
  withdrawers and failure match r1t in every run, and the head-count rung-1 tests
  equal F11's to four decimals. D$ differed only through that recorded amount.
- Why: risk-neutral value V(f) = f + R(1-f)P(f), with P(f) the chance the rest is
  paid after withdrawing f. A large depositor's own withdrawal forces fire
  sales, so P falls in f and V lies on or below the chord from V(0) to V(1):
  all or nothing. Splitting needs a hedging motive.
- Built: a fraction the bank cannot pay in full is no longer offered, so the
  failing withdrawal is a full one, and risk-neutral partial now makes exactly
  all's withdrawals (tests/test_cara.jl C). **BANKRUN_CARA** = gamma: CARA utility
  with a = gamma / mean initial deposit, so a depositor holding the mean deposit
  has a*b = gamma (sigma 2.5: median a*b ~ 0.04 gamma; the largest ~170 gamma).
  Under partial every agent values the fractions; agents above the cutoff
  re-simulate each fraction, and the rest scale their stay draws.
- Smoke (`scripts/cara_smoke.sh`, reference bank, uninsured, no public signal,
  mu 0.25/0.5/0.75 x lambda (0.1, 0.9), 25 banks, same banks at every value):

  | CARA | P(fail) | W_I | W_C | D | deposits out | partial per run | runs with one | failure changed vs 0 |
  |---|---|---|---|---|---|---|---|---|
  | 0   | 0.293 | 0.101 | 0.207 | -0.106 | 0.143 | 0    | 0    | - |
  | 0.1 | 0.360 | 0.130 | 0.233 | -0.103 | 0.178 | 0.59 | 0.36 | 0.067 (5 runs, theta 0.37-0.47) |
  | 0.3 | 0.427 | 0.158 | 0.260 | -0.102 | 0.204 | 1.43 | 0.49 | 0.133 (10; two at theta 0.68, 0.90) |
  | 1   | 0.520 | 0.191 | 0.287 | -0.096 | 0.244 | 3.57 | 0.69 | 0.227 (17; five at theta >= 0.68) |

  (CARA 0.01 at 18 runs: identical to 0.) Every change adds a failure; none
  removes one. Sorting D is flat in CARA. Not looked at: splitting or
  withdrawal by size (rung-4 S1, S2b), so that CARA is chosen before them.

**F12c. r1c: rung 1 and S1-S4 under CARA 0.1 (2026-10-22).**
- Rung 1 (`scripts/rung1_relational.py`, `outputs/r1c-analysis`), pooled, Holm:
  G1' +0.0365 (t 14.8), G4' -0.0250 (t -10.4), G2a' +0.0819 (t 14.3), G3
  +0.0033 (p 0.012); r1t/r1p: +0.0328, -0.0241, +0.0774, +0.0023. Same verdicts
  as F11: G3 passes pooled but (0.3, 0.5) is wrong-signed (-0.0059, t -3.0); G3c
  +0.0195 passes, (0.3, 0.5) only at p 0.052. G2b ordering holds. The corrects
  arm again sorts between stale and tracks and fades by tick 4 (`rung1_timing.py`).
- Splitting (all 5 mu): 0.45 partial withdrawals per run, 20% of runs have one,
  0.09 agents per run end holding part of their deposit. Against r1p, paired:
  P(fail) 0.297 vs 0.269 in r1c-none (108 failures added, 6 removed); +0.03 to
  +0.026 to +0.037 in the other sigma 2.5 arms. stale-y50-s1 (sigma 1): 0.01 partial per run, failure
  identical to r1p.
- Rung 4 (`scripts/rung4_stats.py`; mixed cells, 2,250 runs, 25 clusters,
  one-sided):

  | stat | est | t | p | verdict |
  |---|---|---|---|---|
  | S1a one-shot share, D10 - D1-5 (< 0) | -0.046 | -3.8 | 0.0004 | supports |
  | S1b one-shot share, largest - D10 (< 0) | +0.006 | +2.9 | 0.996 | against |
  | S2b withdrawal rate, D10 - D1-5 (> 0) | +0.0016 | 1.8 | 0.041 | supports (barely) |
  | S2b in r1p, paired | -0.0003 | -0.3 | 0.61 | - |
  | S2b r1c - r1p (what CARA adds) | +0.0019 | 2.7 | 0.006 | - |
  | S3a slope of P(withdraw) in neighbours out (> 0) | +0.52 | 11.6 | <0.001 | supports (partly built in) |
  | S3b slope C - I (> 0) | +0.93 | 15.1 | <0.001 | supports |
  | S4a head-count share W (< 0.5) | 0.114 | -31 | <0.001 | supports; W < 0.5 in 93% of runs, 74% of failed runs |
  | S4b W$ - W (> 0) | -0.005 | -1.0 | 0.83 | against |

- S1 curve (pooled one-shot share of exiters): 1.000 in D1-D7, 0.997 D8, 0.995
  D9, 0.980 D10, 0.930 top 1%, **1.000 for the largest agent** (223 exits).
  Celsius: ~0.85, 0.52, 0.38, 0.35. The gradient has Celsius's sign and a small
  fraction of its size. Partial-exit share: 0.006 in D10, 0.030 in the top 1%,
  0 for the largest.
- Why the largest agent never splits: in every one of its 223 exits the bank
  fails by liquidity (balance file: largestWithdrew x failType), and it holds
  18% of deposits (39% of capacity at the start, median 32%). When it decides
  to go, every interior fraction already drains the bank, so the drain rule
  leaves only 0 or 1. In this bank the largest depositor is the last straw, not
  a gradual exiter.
- Withdrawal rates are flat in size (0.112-0.115 in every decile), which is why
  S2b is tiny and S4b fails: size does not change who runs here, only how.
- sigma 1 control (r4-s1-s10, the same banks at sigma 1; P(fail) 0.204): the S1
  gradient is gone, as predicted: one-shot D10 - D1-5 = -0.0007 (p 0.09), one-shot
  share >= 0.999 in every group, the largest agent 1.000 (170 exits). S2b -0.0001,
  S4b -0.0002 (both null). S3a +0.36, S3b +0.57 and S4a (W 0.076) hold. So S1's
  second "against" condition (the gradient as strong at sigma 1) is not met: the
  sigma 2.5 gradient comes from size relative to the bank.

## Implications for the systematic sweep (draft)

1. *(Settled 2026-10-22, F12: partial withdrawals; sigma a reported axis.)* **sigma's realistic level is ~2.5 (F7), which is the whale regime.** sigma 1 is a
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

## Build order to the systematic sweep (agreed 2026-10-21)

Built so far: the fire-sale bank with period-2 solvency (vault bank kept as the
default), expected recovery, theta with a private signal of it, STAY_RETURN (Ch 1's
R), neighbour and public withdrawal-count signals (accurate or stale, stale freezing
the agent's view), sigma calibrated to Celsius (F7), docking outputs, pipeline guards.

1. ~~**Read the phase 3 gate**~~ **PASSED 2026-10-21 (F9)** (`arms/phase3_firesale_gate.tsv`).
   If it passes, the calibration pilots (step 3's scans) can run while step 2 is
   built: they are single-cell fire-sale arms and need neither stale theta nor the
   seeding change. If it fails, calibration comes before step 2.
2. ~~**Public signal of theta (stale y)**~~ **BUILT 2026-10-22** (f0bbdf2):
   `THETA_PUBLIC` none|stale|tracks, `_LEVEL`, `_GAP`, `_RHO`, `_NOISE`; decision
   (user): one lambda governs both blends, `LAMBDA_SCOPE=both` in the rung-1 arms
   (count = published, theta = Ch 1 nest); the blend without culture uses mean lambda.
   Smoke property (tests/test_theta_public.jl F): an optimistic stale y keeps more
   in and moves collectivists more. Phase 3 baseline: with the private signal
   alone D = W_I - W_C ~ -0.10 at every theta (the count channel), so rung 1 tests
   the channel-isolated difference against the no-public arm too.
   Was: **Public signal of theta (stale y), the main missing model piece.** In Ch 1 the
   cultural weight is on theta, est_i = (1 - w_i) x_i + w_i y with y stale; in the
   ABM lambda weights only head-count beliefs (social vs own prior), and theta
   beliefs carry no culture. **Decision needed first:** does lambda govern the theta
   blend, the head-count blend, or both (both = a second weight).
3. Seeding and allocation **BUILT 2026-10-22** (4ef038e: `SEEDING=common`,
   `N_INIT=25`); calibration pilot submitted. Was: **Seeding and allocation, plus calibration.** Same banks in every cell (seed by
   initialisation, not array index; implication 3) and more initialisations per
   cell (e.g. 25 x 10 instead of 5 x 50; implication 4). Calibration pilots: where
   the fire-sale transition sits across reserves r and discount d (and e, R_stay),
   so the sweep's axes are packed around it.
4. **RUN and read 2026-10-22 (F11)**: 3 of 4 confirmatory tests support; G3 counts
   against (G3c, post hoc, passes). Drafted 2026-10-22: `arms/rung1_theta.tsv` (10 arms), `docs/rung1_prereg.md`
   (outline), `scripts/rung1_relational.py`. Was: **Redesign the rung-1 arms** (`arms/rung1_relational.tsv`, drafted on the vault
   bank with stale counts) on the fire-sale bank with stale theta, and pre-register
   the G1-G4 statistics, signs and contrasts.
5. **The systematic sweep.**

Alongside any step: **fix the who-runs loss accounting** (`scripts/who_runs_production.py`
assumes failed-bank stayers recover only insurance, L = 0; under firesale they
recover pro rata). To schedule: deposit size correlated with cultural type
(calibrated to Ch 2), an explicit withdrawal suspension (the Celsius freeze) as an
institutional lever, and whatever model support the outline's learning section needs.

## Open questions / next pilots

- **Super-individuals (later, separate run; user 2026-10-22):** the platform scaled
  down by aggregation, each agent a cohort of ~542 users with dispersed member
  signals, withdrawing the share of members who run. Sigma matched to the
  platform's top shares (F12: 3.15 jointly). Interest, not on the critical path.
- Partial withdrawals: a finer grid than {0, 1/4, 1/2, 3/4, 1} if results hinge on
  where "just short of tipping the bank" falls. Insurance under partial is a
  cumulative quantile cap (built 2026-10-22: a withdrawal the bank cannot pay in
  full uses cover equal to all it pays; bank-paid withdrawals use none). The
  adaptive scheme stays refused under partial (user).

- ~~Phase 3 gate~~ done: PASS (F9). It was (`arms/phase3_firesale_gate.tsv`, 2026-10-21): the fire-sale bank
  (BALANCE=firesale, PAYOFF=recovery, FUNDAMENTAL=theta; r 0.05, d 0.6, e 0.06,
  R(theta) in [1.0, 1.4], R_stay 1.1; theta_L ~ 0.10, A*(theta) 0.05-0.20) with no signal vs a theta signal at s 0.05 /
  0.10 / 0.20, at sigma 2.5 and 1. Read with `scripts/theta_response.py`.
- Where is the sigma 1 transition for other mu and lambda pairs? (Does culture move
  the transition, or only P(run) within it?)
- R = 1.25: does it move the no-shock failure boundary (F4) and the transition (F3)?
- Initialisations per cell: a pilot at one non-saturated cell with 25 x 10 against
  5 x 50, to size the between-initialisation component directly.
- Insurance quantile q > 0 at sigma 1: the cap is a quantile of the theoretical
  distribution, so its bite on large depositors depends on sigma.
