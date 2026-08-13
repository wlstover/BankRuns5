# Chapter 3 (ABM) — Suggested Extensions / Future Work

_Created 2026-07-14. Purpose: durably capture proposed additions to the agent-based-model
chapter so they don't evaporate between sessions (they were discussed once and never written
down). Each item is anchored to the concrete model mechanics in `paper_draft.md` /
`functions4.jl` so the framing stays accurate._

**Provenance note:** items 1–4 below were reconstructed from a prior discussion that was not
saved. Only the *hooks* pre-existed in the draft (SVB validation §9.9; the "cultural
orientation is fixed within a run" limitation in §7); the developed framings here are new.
Correct/extend freely.

---

## Anchor: where these plug into the current model

The Phase-2 endogenous decision (per agent, per tick) is:

1. Observe neighbors → `n_withdrawn`, `π̂_withdrawn`, point estimate `Ŵ_total = round(π̂ · N)`.
2. **Belief blend (the λ mechanism, §4.4):**
   `blendedTotal_k = round((1−λ)·mcDraw_k + λ·Ŵ_total)`, `k = 1..D`, `D = 1000`.
3. **Monte Carlo solvency inference (Step 4):** for each of `D` draws, clone the model twice
   ("withdraw now" vs "stay and withdraw later"), resimulate, check whether agent `i` receives
   its full deposit `d_i`. Yields `P̂_WD`, `P̂_stay`.
4. **Decision (Step 5):** withdraw iff `P̂_WD > P̂_stay`.

Two facts drive most of what follows:

- **λ is fixed at warm-up and static within a run** (drawn once from a type-specific Beta,
  §4.3). This is the target of the *social/group learning* extension.
- **Step 3's `D = 1000` clone-and-resimulate per agent per tick is the dominant compute cost**
  and the reason the production sweep sits in the "aggressive-pressure" regime that **cannot
  test P6b** (`paper_draft.md` §6.6, ~L466). Anything that cheapens or differentiates this
  step (neural surrogate; differentiable ABM) directly unlocks the higher-reserve / lower-
  intensity sweep the paper already says it needs.

---

## 1. Social / group learning — adaptive λ within a run

**What's there now.** λ is assigned once in the warm-up and held constant. §7 already flags
this as a limitation: *"cultural orientation is fixed within a run; in reality, individuals'
weighting of social versus private information may shift under stress."* This item develops
that sentence into a modeled mechanism.

**Proposal.** Let each agent's weight on the social signal adapt *during* the run instead of
being frozen. Replace the fixed λ in the §4.4 blend with a state `λ_i(t)` updated by a social-
learning rule as the cascade unfolds. Candidate rules, in increasing ambition:

- **Bayesian precision updating.** Treat λ as the relative precision the agent assigns to the
  neighbor signal vs. its own MC prior, and update it via observed signal quality — e.g., how
  well the neighbor-implied `Ŵ_total` tracked realized withdrawals over recent ticks.
- **DeGroot / social-learning over beliefs (not just a fixed linear blend).** Iterate beliefs
  about `W_total` across neighbors each tick rather than applying a one-shot `(1−λ, λ)` mix;
  λ becomes the self-weight in the DeGroot matrix.
- **Reinforcement-style update.** Use the MC counterfactual payoffs (`P̂_WD` vs `P̂_stay`) as a
  within-run reward signal to nudge λ toward whichever information source would have been more
  reliable.

**Key design problem.** A single run is not repeated play, so the feedback signal must be
constructed carefully — realized neighbor outcomes as the cascade proceeds, or the MC
pseudo-payoffs, not an ex-post reward. State the feedback signal explicitly before coding.

**What it buys.** A "stress-amplification" channel: collectivists whose λ *rises* under
observed withdrawals give a micro-foundation for accelerating cascades, potentially sharpening
the P6 non-monotonicity. Directly closes the §7 limitation.

**Effort:** Medium. Touches the Phase-2 belief step in `functions4.jl` (~L425) only; no warm-up
change. **Dependency:** none. **Cross-link:** the reward-signal version overlaps item 2.

**Candidate literature (verified 2026-07-14).** The anchor is **Jasmina Arifovic**, who owns
"learning in bank-run coordination":

- `arifovic2013experimental` — Arifovic, Jiang & Xu, *Experimental evidence of bank runs as pure
  coordination failures*, JEDC 37(12):2446–2465 (2013). Bank runs as coordination failures,
  modeled with **individual evolutionary learning** against experimental data — the precedent that
  *learning dynamics*, not fixed rules, drive run/no-run.
- Arifovic (2019), sunspot-like behavior in agent-based bank-run economies — **already in the
  library** (`Arifovic-2019-...pdf`); evolutionary learning in a DD economy with extrinsic-signal
  (sunspot) coordination. *(bib entry not yet added — venue unconfirmed.)*
- Arifovic & Maschek (2006), Computational Economics — the **social- vs. individual-learning**
  distinction itself, which maps onto λ (social signal vs. private prior). *[verify exact title;
  two related A&M papers exist — not yet in bib.]*
- Arifovic (2025), *Social Learning and Monetary Policy at the Effective Lower Bound*, JMCB — social
  learning under a **policy backstop**; the closest existing hook to the FDIC/LOLR angle below
  (policy shaping *how* agents socially learn), though it is monetary policy, not deposit insurance.
- `santos2021dynamic` — dos Santos & Nakane, *Dynamic bank runs: an agent-based approach*,
  JEIC 16(3):675–703 (2021) — **already in the library**; fractional-reserve + neighborhood-
  influenced withdrawal in a DD frame. Our closest structural cousin.
- `ruano2026social` — Ruano & Rajan, arXiv:2602.15066 (2026) — depositors weight **fundamentals vs.
  social information** on a Twitter-calibrated network (SVB/First Republic validated). **Almost
  exactly our λ mechanism**; cite as the current frontier we differentiate from (they use an LLM;
  we derive λ from the warm-up). See item 2.
- Secondary contagion ABMs *[metadata unverified — behind paywall, not in bib]*: "Bank runs via
  social networks", JEIC (2025, doi …00452-4); Gong (2023), Int. J. Finance & Econ.

**⚠️ GAP = opportunity.** No paper found that models **FDIC / lender-of-last-resort specifically
dampening depositors' *social* learning**. The pieces exist separately (Arifovic on bank-run
learning; Arifovic 2025 on policy + social learning; DD on insurance) but the *combination* is
unclaimed. Frame this as a **contribution** of item 1, not a citable result. (One lead worth
chasing: "Investigating the Bank Run Phenomenon and the Effect of Deposit Insurance … Multi-Agent
Model," *J. Money and Economy* — deposit insurance in an interbank multi-agent model; verify
before relying on it.)

---

## 2. Neural network surrogate for the Monte Carlo solvency inference

**What's there now.** Nothing — no ML anywhere in the repo. Net-new.

**Proposal.** Replace (or shadow) the `D = 1000` clone-and-resimulate estimator of `P̂_WD` and
`P̂_stay` (Step 4) with a learned function approximator. A small network maps a state-feature
vector — vault level, `n_withdrawn`, `π̂_withdrawn`, `d_i`, `blendedTotal` distribution summary,
reserve ratio `r`, insurance cap `d̄_ins`, network-position features — to the pair
`(P_WD, P_stay)`. Train offline on labels generated by the existing MC procedure, then swap the
surrogate in for the inner loop.

**Two distinct motivations (keep them separate in the write-up):**

- **Computational.** The MC inner loop is the bottleneck that pins the sweep to the aggressive-
  pressure regime. A surrogate that is orders of magnitude cheaper enables the r ≥ 0.2 /
  lower-intensity sweep required to test **P6b** (§6.6). This is the pragmatic case.
- **Behavioral.** A learned heuristic is arguably a *more* realistic model of a boundedly-
  rational depositor than exact Monte Carlo integration over 1,000 clones. Framed this way the
  NN is not just an accelerator but a substantive agent-cognition assumption.

**Risk / gate.** The estimand is a full-deposit boundary probability; accuracy **in the tails**
(near vault ≈ `d_i`) is what determines the withdraw/stay flip. Validate the surrogate against
held-out MC labels *specifically in the boundary region* before trusting any sweep run on it —
a surrogate that is accurate on average but wrong at the decision margin will silently distort
run probabilities.

**Effort:** Medium–High. **Dependency:** needs a labeled MC training set (cheap to generate
from the current sim). **Cross-link:** the surrogate is naturally differentiable → feeds item 3.

**Candidate literature (verified 2026-07-14).** Keep three *distinct roles* for neural nets separate
in the write-up — only the third is what this item proposes:

1. **Learned policy as the agent decision rule.** `lussange2021modelling` — Lussange, Lazarevich,
   Bourgeois-Gironde, Palminteri & Gutkin, *Modelling Stock Markets by Multi-agent Reinforcement
   Learning*, Computational Economics 57(1):113–147 (2021). Each agent learns to act via RL in a
   calibrated financial ABM; explicitly framed as replacing "zero-intelligence" agents. **The
   canonical precedent for *learned* rather than *fixed* agent behavior in an economic ABM.**
2. **LLM as the agent decision function.** `ruano2026social` (a constrained LLM "maps each agent's
   information set into a discrete action" — and it's a *bank-run* ABM, so doubly on point) and
   `larooij2025social` — Larooij & Törnberg, arXiv:2508.03385 (2025), LLM agents inside an ABM
   (generative social simulation). **Both already in the library.**
3. **NN as a *surrogate* for the Monte Carlo solvency inner loop** — *this item's proposal.* None of
   the above do exactly this; cite roles 1–2 as the "learned-agent" tradition and position the
   surrogate as the new use. The differentiable-ABM trio (esp. `dyer2023gradient`) is the nearest
   neighbor, since a differentiable surrogate is what makes gradient-based calibration (item 3)
   tractable.

---

## 3. Differentiable agent-based model

**What's there now.** Nothing — the model is explored by discrete grid sweep (12,960 combos).
Net-new, and the most ambitious item.

**Proposal.** Make the simulator differentiable end-to-end so that gradients of an outcome
(failure probability, or the cascade size `E[|S*|]`) with respect to parameters
(`r`, `ι`, `μ`, `λ_I`, `λ_C`, Watts-Strogatz `k`/`p`, log-normal `σ`) are available via
automatic differentiation, rather than reconstructed by finite differences over the grid.

**Core obstacle — discreteness.** Two hard nondifferentiabilities:

- the withdraw/stay **decision** (`P̂_WD > P̂_stay` is a step) → relax with a temperature-scaled
  sigmoid / Gumbel-softmax on the withdrawal choice;
- the **failure** event (`Vault ≤ 0`) and the first-come-first-served payment `min/max` →
  smooth approximations of the vault dynamics.

**What it buys.**

- **Gradient-based sensitivity analysis** — local elasticities of fragility to each parameter,
  far richer than the current experiment-by-experiment marginal plots (§6.2–6.9).
- **Calibration by optimization instead of grid search** — directly minimize a distance between
  simulated and target moments (see item 4), which is what turns "we swept a box" into "we
  fit the model." This is the natural way to bring the model to the SVB / 1854 / Celsius data.

**Lit to position against (now in `banking.bib`, added 2026-07-14 from `~/ProtonDrive/Library/ABM`):**

- `dyer2023gradient` — Dyer, Quera-Bofarull, Chopra, Farmer, Calinescu & Wooldridge, *Gradient-
  Assisted Calibration for Financial Agent-Based Models*, ICAIF '23. **The most directly relevant
  cite** — a *discrete financial* ABM made differentiable and calibrated via gradient-assisted /
  probabilistic-ML methods. Note J. Doyne Farmer as a coauthor (ties to `Axtell_and_Farmer_2025`
  already in the library). This is the template for what item 3 + item 4 would do to our bank-run model.
- `querabofarull2023bayesian` — Quera-Bofarull, Chopra, Calinescu, Wooldridge & Dyer, *Bayesian
  Calibration of Differentiable Agent-Based Models*, AI4ABM Workshop @ ICLR 2023. Generalised
  variational inference for **misspecification-robust** Bayesian parameter inference on a
  differentiable COVID-19 ABM — the calibration-under-misspecification angle for item 4.
- `querabofarull2023challenges` — Quera-Bofarull, Dyer, Calinescu & Wooldridge, *Some Challenges of
  Calibrating Differentiable ABMs*, Differentiable Almost Everything Workshop @ ICML 2023. The
  **methods caveats** for item 3: differentiating through discrete randomness (Gumbel-Softmax
  reparametrisation and its bias/variance issues), StochasticAD (Arya et al.) as the unbiased
  alternative in Julia, and reverse- vs forward-mode AD trade-offs. Directly informs the "relax the
  discrete withdraw/fail steps" obstacle above.

Secondary cites these three point to, still to source if item 3 is pursued seriously: **Andelfinger
(2021)** (continuous approximations of discrete ABM control flow), **Chopra et al. (2023)**
(differentiable agent-based epidemiology, the GS-trick deployment), **Arya et al. (2022)**
(StochasticAD), **Bezanson et al. (2017)** (Julia — our sim language, relevant to which AD stack).

**Effort:** High (research-grade; likely a paper of its own, or a clearly-scoped §7 "direction"
rather than a completed result). **Dependency:** cleanest if built on the item-2 surrogate
(already differentiable) rather than autodiffing through the clone-and-resimulate loop.
**Cross-link:** items 2 and 4.

---

## 4. Validation benchmarking

**What's there now.** A **qualitative** SVB (March 2023) validation in
`REPOSITORY_REVIEW.md §9.9` (small-world topology; convergence to a *partial* run rather than
total collapse; Thiel/Founders Fund as the high-degree trigger; principal-safety not option-
exercise). §7 lists *"calibration to historical bank-run episodes (1854 New York panics —
Kelly & Ó Gráda 2000; 2023 SVB)"* as a "natural next step." Both are gestures, not benchmarks.

**Proposal.** Promote validation from narrative to a **quantitative benchmark**: a set of target
moments the calibrated model must reproduce, evaluated by indirect inference / method of
simulated moments (or, with item 3, gradient-based fitting).

- **SVB (primary).** Candidate target moments: run vs. no-run outcome; the *partial-run
  fraction* (share of deposits/ depositors that withdrew before resolution); cascade speed;
  sensitivity to removing the high-degree trigger.
- **1854 New York panics (secondary).** Kelly & Ó Gráda (2000) — a different information/network
  regime (pre-telecom, kin/ethnic-cluster networks), a genuinely out-of-sample second case.
- **Internal / cross-chapter validation.** Does the ABM reproduce the *Celsius* empirical
  patterns — individualists exiting earlier, the μ-composition effects? This is the bridge
  that ties Chapter 3 back to Chapter 1 and is the most defensible "validation" because it uses
  our own estimated facts as targets.

**What it buys.** Turns the parameter sweep from "we mapped a box of the parameter space" into
"the model reproduces observed panics at calibrated parameters," which is the credibility ask a
referee will make of any ABM.

**Effort:** Medium (SVB moment-matching) → High (full indirect-inference pipeline).
**Dependency:** strongest when paired with item 3 (differentiable calibration) or item 2 (cheap
enough evaluation to run the moment search). **Cross-link:** items 2, 3.

---

## Dependency / sequencing summary

```
item 2 (NN surrogate) ──► cheap inner loop ──► unlocks P6b sweep (§6.6) AND
       │                                        cheap evaluation for item 4
       └──► differentiable by construction ──► item 3 (differentiable ABM)
                                                     │
item 4 (validation benchmarks) ◄────────────────────┘ (gradient calibration to moments)

item 1 (adaptive λ / social learning) — independent; closes the §7 "fixed within a run" gap;
       its reinforcement variant shares machinery with item 2's training signal.
```

Natural order if pursued: **1** (self-contained, closes an existing limitation) → **2** (unlocks
the P6b sweep the paper already needs) → **4** (SVB moment-matching, feasible once 2 is cheap) →
**3** (research-grade; subsumes gradient calibration for 4).
