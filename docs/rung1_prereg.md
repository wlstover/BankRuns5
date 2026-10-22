# Rung 1 pre-registration: OUTLINE (2026-10-22)

Status: decisions made by the user 2026-10-22 (below); prose by the user. Nothing in
`arms/rung1_theta.tsv` runs until this is signed off and r, d are set from the
calibration pilot (`arms/calib_d_scan.tsv`).

Analysis code, fixed before the runs: `scripts/rung1_relational.py` (the commit
that adds this file). Any change after the runs land is reported as a deviation.

## 1. Design (fixed)

- Arms: `arms/rung1_theta.tsv`, 10 arms × 15 cells (5 μ × 3 λ pairs) × 250 runs.
- Common random numbers: `SEEDING=common`, `N_INIT=25`, seed offset 1000 in every
  arm, so the same 25 banks × 10 runs, with the same θ and the same shocks, in every
  cell and arm.
- Fire-sale bank, θ ~ U[0,1], private x_i = θ + 0.10·Z, s_y = 0.10, one λ for
  both blends. r = 0.05, d = 0.6 (pilot_map F10), e = 0.06, R(θ) = 1 + 0.4θ, R_stay = 1.1,
  σ = 2.5 (σ = 1 in one arm).

## 2. Unit and statistic (fixed)

- Unit: one run in a mixed cell (μ ∈ {0.25, 0.5, 0.75}).
- W_J = endogenous withdrawers of type J / agents of type J not hit by the shock.
- D = W_I − W_C (> 0: individualists run more). Head count: primary (user, 2026-10-22).
- D$ = the same with deposits: W$_J = deposits withdrawn endogenously by type J /
  deposits of type J not hit by the shock. Secondary: reported for every test, not
  in the confirmatory family.
- D counts every withdrawal over the whole run (who runs, not when). Shock victims
  are in neither the numerator nor the denominator. Limitation: a liquidity failure
  stops the cascade mid-tick, so agents who had not yet decided count as stayers.
- gap = y₁ − θ (> 0: y optimistic). "Disagree" means |gap| > g, with g = 0.1.
- Failed = failType ≠ none (liquidity or insolvency).
- Standard errors are clustered on the initialisation (25 clusters).

## 3. Hypotheses: statistic, sign, contrast

| ID | Ch 1 source | Statistic | Arms | Predicted sign |
|---|---|---|---|---|
| G1 | Prop. partial-runs, case 1 | mean D, given gap > g and failed | stale-y20/50/80 | > 0 |
| G1′ | same, channel-isolated | mean (D_arm − D_none) run for run, given gap > g | stale arms vs none | > 0 |
| G4 | Prop. partial-runs, case 2 | mean D, given gap < −g and survived | stale arms | < 0 |
| G4′ | same, channel-isolated | mean (D_arm − D_none), given gap < −g | stale arms vs none | < 0 |
| G2a′ | Prop. two-type, cutoff gap; reassurance comparative static | slope of D on y₀ within run (run fixed effect; the same run in the three stale arms) | stale-y20/50/80 | > 0 |
| G2b | ω-odds gap | ordering of the G2a′ slope across λ pairs | stale arms | b(0.1, 0.9) > b(0.2, 0.8) > b(0.3, 0.5) |
| G3 | 2×2, "signals agree" | mean \|D_arm\| − \|D_tracks-g0\|, run for run | stale arms | > 0 |

Confirmatory family (Holm): {G1′, G4′, G2a′, G3}, each pooled across the 3 λ
pairs. G2b is the dose-response check alongside. G1, G4 (levels) are reported
for the aggregate findings. G1′ is also reported split by whether the bank fails
in the no-public arm (pre-treatment for the public signal), standing in for Ch 1's
"the bank fails" qualifier.

Why G2a′ and not a within-arm slope of D on the gap (user, 2026-10-22): within a
stale arm y₀ is fixed, so the gap y₀ − θ varies only through θ, and the slope
picks up anything that varies with fundamentals. The same run at three y₀ varies
y alone. The run fixed effect also absorbs the part of D that does not depend on
y, including the head-count channel.

Decisions (user):
- [x] **Decided (user, 2026-10-22):** G1′/G4′ are the tests for who runs and for the effect of heterogeneous signal weights, so that network heterogeneity is not conflated with cultural heterogeneity. The levels G1/G4 describe outcomes under all depositor heterogeneity together (P(run) and the other aggregate findings), and are reported alongside. Was: are the **levels** (G1, G4) or the **channel-isolated** versions (G1′, G4′) the primary test? Phase 3 shows D ≈ −0.10 at every θ with the private signal alone: the head-count channel makes collectivists herd. That biases the level G1 toward failure, and that channel has no counterpart in Ch 1.
- [x] **Decided (user, 2026-10-22):** one test per hypothesis, pooled across the 3 λ pairs; Holm across the confirmatory family; per-pair estimates reported; any pair significantly wrong-signed (unadjusted 5%) counts against. Inference: CR1 cluster SEs on the 25 initialisations, t(24) critical values. **Flag (user): check the literature for precedent on this methodology** (pre-registered ABM hypothesis tests, pooling across parameter cells, few-cluster inference). Was: the decision rule: one-sided z > 1.645 per test, with Holm across the family {G1′, G4′, G2a, G3} × 3 λ pairs? Or a sign-consistency count (e.g. support if ≥ 2 of the 3 λ pairs are significant and none is significant the wrong way)?
- [x] **Decided (user, 2026-10-22):** g = 0.1 (equal to the private noise s). Report g = 0.05 and 0.2 as robustness.
- [x] **Decided (user, 2026-10-22):** G2a′ replaces the within-arm slope; G2c (mean D among failed runs by y₀) is exploratory: it conditions on failure, and which runs fail changes with y₀.

## 4. Secondary / exploratory (declared now, not confirmatory)

- G2c: mean D among failed runs by y₀ (y20 → y50 → y80), descriptive.
- D$ (deposit-weighted) versions of every test.
- g = 0.05 and 0.2 versions of G1′/G4′.

- tracks-g20 (Ch 1's declined constant markup): is the sorting gap ≈ (ω_C − ω_I)·δ, and is there a single regime?
- corrects-y80-r50: is |D| between the stale-y80 and tracks-g0 values, and does it fade with the decision tick? (The tick-level split needs the timing output, by type.)
- Scope arms (y80-count, y80-theta vs y80): which blend carries the sorting.
- σ = 1 (stale-y50-s1 vs stale-y50): the sorting without the liquidity floor.
- P(run) by μ in every arm (the Ch 3 headline). Not a rung-1 test.

## 5. What would count against relational equivalence

- G1′ or G4′ significantly signed the wrong way in ≥ 2 λ pairs.
- G3 ≤ 0: sorting no larger when the signals disagree than when they agree.
- Report every outcome whatever the result. A failure points to a feature to examine on the relaxation ladder (feature list F10, 2026-10-20 note), not to re-tuning until it passes.
