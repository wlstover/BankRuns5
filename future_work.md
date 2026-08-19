# Chapter 3 (ABM) — Suggested Extensions / Future Work

_Created 2026-07-14. Purpose: durably capture proposed additions to the agent-based-model
chapter so they don't evaporate between sessions (they were discussed once and never written
down). Each item is anchored to the concrete model mechanics in `draft/paper_draft.md` /
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
  test P6b** (`draft/paper_draft.md` §6.6, ~L466). Anything that cheapens or differentiates this
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

**Further leads added 2026-08-17 — ⚠️ UNVERIFIED (recalled, not checked against the
papers or the databases; confirm venue/year/claim before any draft use).** Prompted by
committee feedback on *social* vs *group* learning and the FDIC-expectations channel:

- **Iyer & Puri (2012), AER** — *Understanding Bank Runs: The Importance of Depositor-Bank
  Relationships and Networks.* The empirical anchor for this whole item: social-network
  transmission in an actual run, with deposit insurance moderating it. If one citation is
  added, this is it.
- **Iyer, Puri & Ryan (2016), JF** — *A Tale of Two Runs.* Depositor learning **across** runs
  at the same bank — the closest empirical analogue to adaptive λ.
- **Kelly & Ó Gráda (2000), AER** — *Market Contagion: Evidence from the Panics of 1854 and
  1857.* Irish immigrant social networks in New York bank runs; the historical case that
  culture-plus-network drives runs.
- **Chari & Jagannathan (1988), JF** — signal extraction with informed/uninformed depositors.
  The analytic ancestor of λ: learning from *others' withdrawals* rather than from fundamentals.
- **Centola & Macy (2007), AJS** — *Complex Contagions and the Weakness of Long Ties.* Why
  threshold/percolation contagion behaves differently from epidemic contagion; the sociology
  counterpart to the §6.9 percolation framing and to `watts2002simple`.
- **Brock & Hommes (1997, 1998)** — adaptive belief systems; agents switching information-
  weighting rules on past performance. The canonical economics formalism for an adaptive λ.
- **DeGroot (1974)**; **Golub & Jackson (2010), AEJ:Micro** — the naive-social-learning
  machinery the DeGroot variant of this proposal would actually use.

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

**Core obstacle — discreteness.** Three hard nondifferentiabilities, not two:

- the withdraw/stay **decision** (`P̂_WD > P̂_stay` is a step);
- the **failure** event (`Vault ≤ 0`) and the first-come-first-served payment `min`/`max`;
- **μ itself**, which is *not* a continuous knob — it enters as a rank threshold
  (`functions4.jl:62`, `sortperm(lambdas_warmup, rev=true)`, then a top-μ cut at L88). As μ
  rises continuously, agents flip type one at a time: at N = 1000 that is a 1000-step
  staircase whose derivative is a sum of spikes. Needs differentiable sorting (soft-sort /
  optimal-transport ranking), which is a real addition on top of everything below — and it
  sits on the exact axis P6a and P6b live on.

⚠️ Note the asymmetry: under `--assignment random` (the placebo arm) type assignment is an
i.i.d. Bernoulli draw and reparameterises cleanly. **The placebo arm is differentiable in μ
and the treatment arm is not.**

### Parameter triage — which of the eight sweep axes admit gradients at all

Assessed 2026-08-16 against the code. This split is itself substantive content: which
parameters of a *cultural-heterogeneity* ABM are differentiable and which are structurally
not is a claim about this model class, not bookkeeping.

| Parameter | How it enters | Differentiable? |
|---|---|---|
| λ_I, λ_C | Beta distribution centres | **Yes** — reparameterises cleanly |
| σ | log-normal deposits, `exp(σZ)` | **Yes** — textbook reparameterisation |
| r | vault initialisation | **Yes**, modulo `min`/`max` in sequential payment |
| q (`depQuantile`) | `quantile(depositDistribution, ·)`, `functions4.jl:235` | **Yes** — see correction below |
| **μ** | rank threshold on warm-up λ, `functions4.jl:62–88` | **Hard** — needs differentiable sorting (i.i.d. under the placebo rule) |
| k | integer node degree | **No** |
| p | Bernoulli edge presence (Newman–Watts) | Only under a relaxed / weighted-graph formulation |

Four clean, one awkward, two effectively out. An earlier version of this section listed all
eight as targets; that was wrong.

**📌 Correction 2026-08-17 — `q` was mis-triaged, and it is the one that matters most.** This
table previously read *"Awkward — piecewise-constant in the empirical sample."* That would hold
for `quantile(deposits_vector, q)`. The code does not do that: `objects.jl:46` declares
`depositDistribution::Distribution`, and `functions4.jl:235` calls `quantile` on the
**distribution object** — the analytic inverse CDF. For the log-normal that is
`exp(m + σ·Φ⁻¹(q))`, smooth in `q` *and* in `σ`; the empirical sample (`functions4.jl:93`) is
drawn separately and never enters the cap. So `q` belongs in the clean tier next to `r`,
subject only to the `min`/`max` in sequential payment, which are subdifferentiable and routine
for autodiff.

This matters because `q` is the **policy** parameter: the FDIC/deposit-insurance counterfactual
is the one gradient target with an external audience, and it turns out to be among the cleanest
rather than among the awkward.

**Also 2026-08-17: μ's "hard" verdict is rule-dependent.** The differentiable-sorting problem is
a property of the *warm-up* assignment rule. Under `--assignment random` the type draw is i.i.d.
Bernoulli(μ) and reparameterises cleanly. The placebo arm is therefore also the tractable
configuration for this item — worth exploiting rather than working around.

---

### What `dyer2023gradient` actually does, and how much of it transfers

Read in full 2026-08-16. Their case study is Rama Cont's (2007) volatility-clustering model:
N = 1000 agents, T = 100 periods, order `ρ_i(t) = 1[ε_t > v_i(t)] − 1[ε_t < −v_i(t)]` against a
**common** signal ε_t, excess demand `Z_t = Σ ρ_i(t)`, returns `r_t = Z_t/(Nη)`, thresholds
refreshed to `|r_t|` with probability s = 0.1. Initial thresholds `v_i(0) ~ f_γ = Gamma(α, β)`.

**Transfers directly:**

- **The discrete-decision fix is exactly our shape.** Their `ρ_i` is a threshold comparison
  producing a discrete choice; our withdraw/stay and `Vault ≤ 0` are the same object. They use
  a **straight-through** estimator (Eq. 14–16), `ρ_i = ρ̃_i + ϱ_i − ϱ_i.detach()`, with a
  sigmoid `ς_k` of steepness k = 5, plus Gumbel-Softmax at temperature τ = 0.1 for the discrete
  threshold update (Eq. 17).
- 📌 **The forward pass stays bit-identical to the discrete model.** This is their explicit
  design goal — gradients are introduced "in a way that does not entail changing the model
  itself, in order that the modeller remains free to specify the model in the way that they
  believe is most appropriate." **So an interior P6b peak cannot be an artifact of a relaxation
  temperature**; simulated outputs are untouched. The exposure is *gradient bias* from k and τ,
  which they flag in §5 as an unsolved hyperparameter-selection problem.
- **The heterogeneity structure maps almost one-to-one — the strongest reason to think this
  applies.** They draw agent thresholds i.i.d. from `f_γ` and calibrate **γ = (α, β), the
  parameters of the heterogeneity distribution**. We would calibrate **(μ, λ_I, λ_C)**, the
  parameters of a *mixture* of Betas over agent decision weights. Structurally the identical
  inference problem: recover the shape of the cross-agent distribution of a decision-weight.
- **The calibration stack is reusable off the shelf:** generalised variational inference
  targeting `π_w,y(θ) ∝ exp(−w·ℓ(y,θ))π(θ)`, loss ℓ = MMD with a Gaussian RBF kernel (median
  heuristic), normalising-flow variational family, via their BLACKBIRDS package. **MMD is a
  distributional distance**, so it suits a cascade-size distribution as naturally as it suits
  their returns series — which is the item-21 outcome variable.
- **The payoff number:** the pathwise (differentiable) estimator reaches the target posterior in
  ~10³ simulations while score-based/REINFORCE plateaus three orders of magnitude worse
  (log q(θ\*) = 0.16 vs −2.31, their Table 1). For a model where one cell costs ~51 minutes,
  that ratio *is* the argument.
- **Forward-mode AD matters more for us than for them.** Their Figure 5: at 1M agents, RMAD
  memory grows linearly in time-steps to **>30 GB** at 10³ steps, while FMAD stays flat at
  **17 MB**. FMAD cost scales with the number of *inputs* — we have ~8 parameters and a graph
  that would dwarf theirs, so their hybrid (FMAD for the ABM Jacobian, RMAD through the flow;
  their Eq. 28–29) is arguably a better fit for our model than for the one they demonstrate on.

**Does NOT transfer — and the paper says so itself.** From their §5, verbatim:

> "some components of ABMs may also require adaptation; for example, agent-agent interactions
> may need to be recast as message passing procedures on a graph"

- ⚠️ **Their model has no agent-agent interaction at all.** Agents observe only the common
  signal ε_t; they name "no social learning between agents is introduced" as a simplification.
  **Our entire cultural mechanism is neighbour observation on a Watts–Strogatz graph.** The
  paper's own stated limitation is our model's central feature. They point at Chopra et al.
  (2023), differentiable agent-based epidemiology, for the graph case.
- ⚠️ **Their model has no nested Monte Carlo.** Their agent decision is one threshold
  comparison, O(1). Ours is `depth` clone-and-resimulate draws of the *entire model* per agent
  per tick (`functions4.jl:433`). Their graph is ~10⁵ agent-steps and they already call RMAD
  memory prohibitive at that scale.
- ⚠️ **Their heterogeneity is i.i.d.; ours is rank-based** (the μ problem above).

**Verdict: a template for the calibration layer, not a drop-in for the simulator layer.** The
blocker is not the discrete decisions — that is solved, and the solution is clean. It is the
nested MC and the network. Which is exactly why **item 2 is the enabling step**: replacing the
clone-and-resimulate loop with a differentiable surrogate collapses both the nesting and the
memory problem, and then their whole stack applies.

**Two expectation-setters:**

1. **They calibrate to a pseudo-observation** generated from their own model at known
   θ\* = (0.1, 0.5, 0.5, 0.2) — a parameter-recovery exercise, not a fit to real market data.
   Even this paper does not demonstrate calibration to observed markets, so a Celsius or SVB
   calibration would be a step beyond what has been shown.
2. **Language mismatch.** BLACKBIRDS is PyTorch; our simulator is Julia. Their ref [2] is
   Arya et al.'s **StochasticAD**, which is Julia and which they name as the *unbiased*
   alternative to Gumbel-Softmax. That is the likelier stack for us, and it dodges the k/τ
   hyperparameter problem they leave open.

---

### What item 3 buys, restated after 2026-08-16

- **P6b is a claim about a derivative.** It says ∂P(run)/∂μ changes sign — an interior peak.
  The whole diagnostic problem of 2026-08-16 was trying to infer a derivative's sign change
  from 5 noisy grid points at DEFF ≈ 14 (see `next_steps.md` items 20–21). A differentiable
  model returns ∂P(run)/∂μ and ∂E[|S\*|]/∂μ **directly**, at any μ, with controllable variance.
  That converts P6b from shape-inference on a coarse grid into a point estimate.
- **Gradient-based sensitivity analysis** — local elasticities of fragility to each parameter,
  far richer than the experiment-by-experiment marginal plots of §6.2–6.9.
- **Calibration by optimization instead of grid search**, which is what turns "we swept a box"
  into "we fit the model."
- 📌 **The cross-chapter payoff, which the original version of this section missed.** Ch 1 and
  Ch 3 currently connect *narratively* ("the Celsius findings map onto the ABM's λ"). Calibrating
  (μ, λ_I, λ_C) to Celsius moments would make that a *quantitative* bridge — does the ABM,
  calibrated to Chapter 1's population, reproduce Chapter 1's observed dynamics? And the
  observable lines up: `REPOSITORY_REVIEW.md` §9.9 already says the model "predicts partial
  runs, not total collapse"; Celsius is itself a partial run (assets froze at a point, so the
  observable is a cascade size, not a binary failure); and Ch 2 turns out to admit partial runs
  analytically (2026-08-16 note). **|S\*| is the moment that connects all three chapters.**

**Bibliography (in `draft/banking.bib`, added 2026-07-14 from `~/ProtonDrive/Library/ABM`):**

- `dyer2023gradient` — Dyer, Quera-Bofarull, Chopra, Farmer, Calinescu & Wooldridge,
  *Gradient-Assisted Calibration for Financial Agent-Based Models*, ICAIF '23, pp. 288–296.
  **The most directly relevant cite**, read in full 2026-08-16; assessment above. J. Doyne
  Farmer as coauthor ties to `Axtell_and_Farmer_2025` already in the library.
- `querabofarull2023bayesian` — *Bayesian Calibration of Differentiable Agent-Based Models*,
  AI4ABM @ ICLR 2023. Generalised variational inference for **misspecification-robust**
  parameter inference on a differentiable COVID-19 ABM — the calibration-under-misspecification
  angle for item 4.
- `querabofarull2023challenges` — *Some Challenges of Calibrating Differentiable ABMs*,
  Differentiable Almost Everything @ ICML 2023. The methods caveats: Gumbel-Softmax bias and
  variance, StochasticAD as the unbiased Julia alternative, reverse- vs forward-mode
  trade-offs. Directly addresses the k/τ hyperparameter gap `dyer2023gradient` leaves open.

Secondary cites to source if item 3 is pursued seriously: **Chopra et al. (2023)**
(differentiable agent-based epidemiology — *promoted*: this is the graph/message-passing
adaptation `dyer2023gradient` §5 says our network case needs), **Arya et al. (2022)**
(StochasticAD), **Andelfinger (2021)** (continuous approximations of discrete ABM control
flow), **Cont (2007)** (the volatility-clustering model `dyer2023gradient` uses as its case
study), **Blondel et al.** on differentiable sorting/ranking for the μ problem.

**Effort:** High (research-grade; likely a paper of its own, or a clearly-scoped §7 "direction"
rather than a completed result). **Dependency:** now firmly established — build on the item-2
surrogate rather than autodiffing through the clone-and-resimulate loop.
**Cross-link:** items 2 and 4.

⚠️ Stale detail in the Anchor section above: it says `D = 1000`. The default was lowered to
**100** on 2026-08-13 (`scripts/README.md`); the 2026-04 production sweep ran at 1000. Graph-size
and memory arguments here should use whichever depth the arm actually ran at.

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

📌 **Updated 2026-08-16 after reading `dyer2023gradient` in full.** The item-2-before-item-3
dependency is no longer a preference, it is a requirement: their method assumes an O(1) agent
decision and *no* agent-agent interaction, so our nested Monte Carlo (`functions4.jl:433`) and
our network are the two things that do not transfer. Replacing the inner loop with a
differentiable surrogate removes both obstacles at once.

The calibration **target** is also now specific rather than aspirational: |S\*| (cascade size),
which is simultaneously item 21's outcome variable in `next_steps.md`, the observable in
`REPOSITORY_REVIEW.md` §9.9's SVB validation, the form Celsius actually takes (a partial run —
assets froze at a point), and — per the 2026-08-16 Ch 2 result — an object the
Goldstein–Pauzner structure admits. That makes item 4 a **cross-chapter** deliverable rather
than a Ch 3 robustness exercise.
