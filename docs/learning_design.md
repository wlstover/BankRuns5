# Learning across episodes: design note (DRAFT, 2026-10-28)

Branch `individual-learning`, off `master` at dfb5afe. Status: L1 and Rule A built and piloted (10-28/29); Rule B decided and built 10-29 (pilots submitted 10-29); L3a built 10-29, piloted 10-30. The
user's decisions of 2026-10-28 (voice note) are marked **[decided 10-28]** and collected in
§11; items still marked **[decide]** are the user's; items marked *(proposal)* are Claude's
suggestions.

Scope: **L1** (repeated episodes) and **L2** (individual learning of λ). **L3** (social learning, L3a; group learning, L3b) is described so L1 leaves room for
it. Fills the 10-20 outline's §7, "Learning: social vs group"; until this exists, §7 claims
only the warm-up α and the insurance contrast.

## 1. What we want to learn from it

Today a run is one episode: the Flache–Macy warm-up assigns each agent a λ (its weight on the
social and public signals), then one bank-run phase plays out with λ fixed. The questions
learning adds (none pre-registered yet):

- **Q1. Does cultural heterogeneity survive experience?** If agents adjust λ toward whatever
  has been accurate, do individualists and collectivists converge, and how fast? If they
  converge completely, culture matters only for a population's first run; if not, the gap
  is persistent. Either answer matters for how Ch 2's single run generalises.
- **Q2. Does a backstop change what people learn?** Under deposit insurance, running rarely
  pays, so the feedback differs (Rob's question about an FDIC-style backstop, as mechanism
  rather than a static contrast).
- **Q3. Scarring.** Does one failure leave a population more run-prone in the next episode?
- (L3b only) **Q4. Does the mix μ itself move?** That would make P6's "mixed population" an
  outcome rather than an input.

## 2. Terms

- **Episode:** one bank-run phase (exogenous shock, endogenous withdrawals, resolution).
- **Run:** a sequence of E episodes on one population (one network, one set of agents).
- **Cell, arm:** as now. A cell is 250 runs; an arm is a set of cells under one switch set.
- **Individual, social, group learning [decided 10-30]:** individual = from the agent's own
  experience (Rule A, Rule B); social = from neighbours' outcomes (L3a imitation); group = the
  population re-deriving its culture: types, λ and μ (L3b). Neighbour withdrawals within an
  episode are the model's herding channel, not learning.

## 3. L1: the episode loop

**What persists across episodes:** the network, the agents, their types, and each agent's λ
(changed only by L2/L3).

**What is redrawn each episode:**
- the fundamental θ (`FUNDAMENTAL=theta`). Learning needs variation: with one fixed θ, the
  "right" action never changes;
- the exogenous shock;
- the private signals.

Each episode gets its own RNG stream, seeded from (run seed, episode), so episode e matches
across arms (common seeding, as in the rung-1 arms).

**The bank and deposits [decided 10-28: A for now]:**
- **(A) Fresh bank, same people**: each episode resets
  the vault, the long asset and deposits to the run's initial draw. Learning is the only
  thing carried over, so any change across episodes is learning.
- **(B) Carried wealth:** losses persist, so a depositor burned in episode 1 is smaller in
  episode 2. This is more realistic but mixes a wealth channel into the learning channel. A
  later switch value.

**Null check (must pass first):** with `LEARN=none`, a run of E episodes is E independent
draws on one population. P(fail) and the withdrawal shares by type must be flat across
episodes, and pooled they must match r1k-none's distribution.

## 4. L2: how λ updates

**The feedback** exists only between episodes, which is what makes this cleaner than the
within-run version in `future_work.md` §1 (no honest reward mid-cascade). After an episode
resolves, θ is revealed: the long asset's return is booked, so the bank's books show it.

### Rule A: precision learning *(proposal: primary)*

Each agent tracks how accurate each source has been and leans toward the more accurate one,
with culture as the prior:

    e_x = x_i − θ          (private signal error, this episode)
    e_y = y − θ            (public/social signal error; under stale y this is the staleness gap δ)
    MSE_x ← (1 − η)·MSE_x + η·e_x²          (η: memory; MSE starts at the signal variances)
    MSE_y ← (1 − η)·MSE_y + η·e_y²
    λ*_i = MSE_x / (MSE_x + MSE_y)          (the Bayesian weight on y given the track record)
    λ_i  = (1 − κ)·λ_i^culture + κ·λ*_i

- **κ ∈ [0, 1] is culture's grip:** κ = 0 is today's model; κ = 1 is pure learning, and
  every agent's λ converges to the same Bayesian weight. This is the knob Q1 is about.
- It connects directly to Ch 1, where λ is a precision ratio. Learning pulls λ toward the
  optimal precision weight; culture is the persistent deviation from it.
- It is cheap: no extra sub-simulations, only two numbers per agent.
- **[decided 10-28: θ only.]** Under `LAMBDA_SCOPE=both`, one λ is used for both the
  θ-blend and the withdrawal-count blend. Rule A scores only the θ signals. The user's
  reason: a depositor's neighbourhood changes over time (people move), so the case for
  learning how far to trust one's neighbours' withdrawals is weaker than for the public
  signal of θ. Revisit if the network is ever made dynamic.
- **[check against code]** Which variables are x_i and y in `thetaBelief` /
  `thetaPublicAt` under the reference settings, and whether every agent observes y.

### Rule B: payoff learning, the signal-direction rule *[decided 10-29; built 10-29]*

Rule A scores signal accuracy, so a backstop cannot change what it learns: the 10-29 pilot
`lrn-y50-k50-ins` had θ weights bit-identical to `lrn-y50-k50` (§12). A backstop changes
what running *pays*. Rule B takes its feedback from outcomes, so insurance enters it. It is
the individual half of Q2, and its payoff is what L3a's imitation compares (§5).

After each episode, for each agent, from what actually happened (no counterfactual
decisions):

    π_stay = R if the bank is solvent at the end, else max(ρR, insured share)
             (per unit of deposit; ρ = end-of-run assets / promises, 0 after a liquidity failure)
    π_wd   = 1 (withdrawing at par at the start)
    trust y if y pointed toward the better action: y > x_i and π_stay > π_wd,
                                                or y < x_i and π_stay < π_wd;  else trust x
    ω*_i ← (1 − η)·ω*_i + η·(1 if trust y, 0 if trust x)     (ω*_i starts at the cultural λ_i)
    ω_i  = (1 − κ)·λ_i^culture + κ·ω*_i
    no update on a tie in payoff (a fully insured stayer in a failed bank) or in the signals

- **[decided 10-29] Move toward the end that paid better, at speed η.** κ and η mean what
  they mean under Rule A, so the two rules' arms compare directly.
- **[decided 10-29] The signal-direction rule, from realised outcomes.** The weight end that
  "paid better" is the one that leans on the signal that pointed toward the action that
  paid. Considered and dropped: shadow agents with weights 0 and 1 replayed against the
  realised run (about 3× the decision cost), and tick-1 counterfactual decisions.
- **What it ignores:** it moves the weight even when both signals would have led to the same
  action, and it does not score the head-count blend (decision 2).
- **Insurance enters through π_stay.** An insured depositor's π_stay is at least 1, so it
  learns to trust whichever signal said "stay" (complacency). With partial coverage, insured
  and uninsured depositors in the same bank learn in opposite directions after a failure.
- Rule B needs agents who still run: at q 0.99 nobody withdraws endogenously (§12), so the
  backstop arms use partial coverage (§8).

## 5. L3: social (L3a) and group (L3b) learning

### L3a: imitation *[decided 10-29; built 10-29]*

The social half of Q1/Q2: agents learn from what worked for their neighbours, not only from
their own experience (the individual vs social distinction of Arifovic and Maschek 2006).
After each episode:

    pick one network neighbour j at random
    if π_j > π_i:  ω*_i ← (1 − η)·ω*_i + η·ω*_j          (move toward j's learned weight)
    ω_i = (1 − κ)·λ_i^culture + κ·ω*_i

- π is Rule B's realised payoff per unit of deposit (no counterfactual needed: each agent's
  own realised π).
- It moves the learned weight ω*, not the cultural λ, and only the θ weight (as Rule A/B).
- The backstop enters through π: under insurance, stayers are paid R and runners 1, so
  stayers' weights spread. That is the social half of Q2.
- **[decided 10-29]** one random neighbour (not the best neighbour); η shared with Rule B;
  synchronous update; a tie in π is no move; L3a runnable alone (`LEARN=imitate`) and with
  Rule B (`LEARN=payoff+imitate`), so individual, social and both compare on common seeds.
- As built: π_i = (what i was paid on its withdrawals + stay value × what it left in) / its
  deposit at the start of the episode; the update is synchronous (j's ω* from before the
  round); a tie in π is no move; under `payoff+imitate`, Rule B moves ω* first and imitation
  reads the result. The neighbour draws have their own stream from the episode seed, so the
  model's other draws are untouched (κ = 0 reproduces no learning file for file).
- Imitation alone can only mix the cultural weights: every ω*_i stays in [min λ, max λ].
  It moves weight between types (and within a type), it does not discover a new one.

### L3b: group learning, success-biased type switching *[decided 10-30; built 10-30]*

Q4: does μ move? μ is fixed by construction in L1–L3a: modelGenTyped makes the top μN by
warm-up score type I, and learning moves only ω, never the cultural λ. Re-running the warm-up
(the 10-29 sketch) would not free it either: the warm-up score is network position (the share
of an agent's interactions with culturally opposed neighbours), so payoffs have nothing to act
on, and the rank cut keeps n_I = μN. **[decided 10-30]** Instead, culture re-forms around
payoffs. After each episode:

    with probability ν (LEARN_TYPE_RATE):
        pick one network neighbour j at random
        if j is the other type and π_j > π_i:  i adopts j's type
            λ_i ← F_new⁻¹(F_old(λ_i))     (same quantile of the new type's Beta)
            ω*_i kept;  ω_i = (1 − κ)·λ_i + κ·ω*_i

- π is L3a's realised payoff per unit of deposit (insurance enters through the stay value).
- ν = 0.05 per episode, slower than η = 0.2: culture moves more slowly than learned weights.
- One random neighbour (as L3a); synchronous (types and payoffs from before the round); a
  payoff tie is no switch. Every agent makes the same two draws whatever happens, from its
  own stream off the episode seed, so ν = 0 is the no-learning model file for file.
- The switch changes the type label, the cultural λ (agent and learner) and so the
  head-count blend; μ_t = n_I / N is an outcome.
- Two configurations, each at q 0 / 0.5 / 0.9: **group alone** (`LEARN=type`, κ = 0: the θ
  weight is the cultural λ, so a switch changes it) isolates whether culture re-forms; **Rule
  B + group** (`LEARN=payoff+type`, κ 0.5, Rule B first) asks whether it survives individual
  learning. Rule B pulls both types' ω* toward a common value, so the payoff gap between types
  shrinks to the cultural half of the weight; slower drift in μ there would itself be a result.
- Expected direction (unclear, which is why it runs): in solvent episodes runners are paid
  less and C runs more endogenously, which pulls toward I; in failures runners do better,
  pulling toward C. Insurance turns failure comparisons into ties, so μ may drift up faster
  under a backstop.
- Vertical (generational) transmission is the same dynamics with replacement; later work.

## 6. Switches

| switch | values | default |
|---|---|---|
| `BANKRUN_EPISODES` | E ≥ 1 | 1 (today's model) |
| `BANKRUN_EPISODE_RESET` | `bank` (A) / `wealth` (B, not built) | `bank` |
| `BANKRUN_LEARN` | `none` / `precision` / `payoff` / `imitate` / `payoff+imitate` / `type` / `payoff+type` | `none` |
| `BANKRUN_LEARN_GRIP` | κ ∈ [0, 1] | 0 |
| `BANKRUN_LEARN_MEMORY` | η ∈ (0, 1] | 0.2 (a later sweep axis) |
| `BANKRUN_LEARN_TYPE_RATE` | ν ∈ [0, 1] (`type`, `payoff+type` only) | 0.05 |

`precision`, `none` and E built 10-28; `payoff`, `imitate` and `payoff+imitate` built 10-29;
`type` and `payoff+type` built 10-30 (`type` refuses κ ≠ 0).
The manifest records the resolved values, and untagged runs with any switch set are refused.

## 7. Outputs

- **`bankRunEpisodes*.csv`:** one row per run × episode × type: P(fail) indicator, θ,
  withdrawal share, mean and s.d. of λ, mean MSE_x and MSE_y; n per type (μ_t under L3b)
  and nJoined, the agents that switched into the type after the previous episode (10-30).
- **`bankRunLambda*.csv`** (`BANKRUN_LOG=full` only): λ trajectories for a fixed sample of
  agents.
- The existing per-run files (results, vault, types, timing, ...) are written for the last
  episode only, so the current checkers and analysis scripts keep working unchanged
  *(proposal; the user saw no problem, 10-28)*. Per-episode detail goes in the new files.

## 8. Pilot arms

All on the reference bank (r1k settings), E = 20, one mixed cell (μ 0.5, λ 0.1/0.9), common
seeding. Arms with the same coverage pair run for run with their no-learning control.

**Run 10-28 (read 10-29, §12):** lrn-null; lrn-y50-none, k25, k50, k100; k50-ins (q 0.99).

**Coverage, Rule A (no new code; `arms/learning_cov.tsv`, 10-29):** lrn-y50-none and k50 at
q 0.5 and 0.9. Checks that partial coverage keeps endogenous runners (q 0.99 kept none), and
is the Rule A baseline for the Rule B and L3a coverage arms.

**Rule B (`arms/learning_payoff.tsv`, 10-29):** lrn-y50-pay, -pay-q50, -pay-q90 (κ 0.5, η 0.2),
paired with lrn-y50-none and the coverage controls.

**L3a (`arms/learning_imitate.tsv`, 10-29):** at q 0 / 0.5 / 0.9, κ 0.5, η 0.2:

| arm | learning | question |
|---|---|---|
| lrn-y50-pay-q* | Rule B | Q2, individual |
| lrn-y50-imi-q* | L3a | Q2, social |
| lrn-y50-payimi-q* | Rule B + L3a | both |

**Rule B horizon (`arms/learning_horizon.tsv`, 10-30):** none and pay at q 0 / 0.5 / 0.9,
E = 60 (tag `-e60`): where ω* settles, and whether the coverage gap in ω* grows.

**L3b (`arms/learning_type.tsv`, 10-30):** type and paytype at q 0 / 0.5 / 0.9, ν 0.05, E = 60,
controls lrn-y50-none*-e60 (μ, P(fail)) and lrn-y50-pay*-e60 (does group learning change
what Rule B does).

What to read: by episode and by type, the θ weight, P(fail) and P(fail | θ), the withdrawal
gap; and by insured vs uninsured depositor within the bank (Iyer–Puri).

## 9. Cost

**Code:**
- an episode loop around `modelRun` in `runRow`, with a per-episode reset and reseed;
- Rule A in the belief step (a small change);
- the new outputs, the switches and tests.

About two to three working sessions, including the null check.

**Compute:** E× a single-episode cell. With the sparse sub-simulation, a 1,000-agent cell
takes about 4–8 minutes on the laptop, so E = 20 is roughly 1.5–3 hours per cell locally.
Pilots go on Hopper.

## 10. Literature (verify before citing; several from memory)

- Iyer, Puri and Ryan (2016), "A Tale of Two Runs", *Journal of Finance*. Depositors' behaviour
  across two runs at the same bank: the closest empirical analogue.
- Arifovic, Jiang and Xu (2013), *JEDC* 37(12): evolutionary learning in bank-run
  coordination experiments (verified 2026-07-14).
- Arifovic and Maschek (2006), *Computational Economics*: the social vs individual learning
  distinction (title to verify).
- Ruano and Rajan (2026), arXiv:2602.15066: weighting fundamentals vs social information on
  a calibrated network (the current frontier; verified 2026-07-14).
- Iyer and Puri (2012), *AER*: network transmission, moderated by insurance.

## 11. Decisions (user, 2026-10-28, voice note; 2026-10-29)

1. **Bank across episodes:** a fresh bank each episode (A) for now.
2. **Rule A scores θ only.** Not the neighbour-count blend: neighbourhoods change over time
   and people move, so learning to trust one's neighbours is the weaker case. Ignore it for now.
3. **η and E:** η = 0.2 (a source's track record is roughly the last 5 episodes) and E = 20
   episodes per run (confirmed 10-28). η is a candidate sweep axis later, to see whether the
   memory length changes the results.
4. **Outputs:** old per-run files from the last episode only; new per-episode files.
5. **No pre-registration** for now.
6. **Rule B** not needed; one quick comparison arm after the rest is done.

7. **[10-29] Q2 stays**, at the individual and the social level: Rule B (payoff learning)
   with partial-coverage arms, and L3a (imitation). Rule B moves toward the end that paid
   better at speed η. L3b is later work, with vertical transmission of the weights.

8. **[10-30] Terms:** individual / social / group learning as in §2.
9. **[10-30] Q4 (does μ move) in the dissertation:** L3b as success-biased type switching
   (§5), ν = 0.05, one random neighbour, synchronous, λ to the same quantile, ω* kept; run
   alone and with Rule B, at q 0 / 0.5 / 0.9. Vertical transmission stays later work.
10. **[10-30] ω* starts at λ** (default); a random start (ω* ~ U(0, 1)) only as a robustness
    arm (Rule B path independence; imitation with variation to copy), not a crossed axis.
11. **[10-30] Rule B horizon:** E = 60 for the Rule B arms and their controls.
12. **[10-30]** The differentiable ABM stays future work (stated direction in Ch 3).

## 12. Implementation status

**L1 built 2026-10-28** (branch `individual-learning`):
- `settings.jl`: `BANKRUN_EPISODES` (default 1) and `BANKRUN_EPISODE_RESET` (`bank` only;
  `wealth` is refused until built).
- `functions4.jl`:
  - `runRow` runs episodes 1..E−1 (`earlyEpisodes!`), then the last episode through the
    unchanged single-episode path.
  - `resetEpisode!` restores the bank, deposits and banked flags.
  - `episodeSeed` gives episode 1 the run's own seed2, and later episodes a derived,
    non-negative seed.
  - The early episodes' modelRun files go to a scratch directory that is deleted, so every
    per-run file describes the last episode.
  - `bankRunEpisodes<core>.csv` holds one row per run × type × episode: key, type, episode,
    seed2, θ, failed, n, nExog, nEndog, depTotal, depEndog, λ mean and s.d.
- `consolidate_results.py`: gathers `bankRunEpisodes` into `consolidated_episodes.csv`.
- `tests/test_episodes.jl` (80 checks, in `run_tests.sh`):
  - E = 1 reproduces dfb5afe byte for byte (default and reference bank);
  - at E = 3 the per-run files equal a single-episode run on episode 3's seed;
  - each episode row matches a single-episode run on that episode's seed;
  - seeds are distinct and non-negative.
  test_replay, test_dock_outputs, test_partial, test_switch_identity,
  test_neighbour_output and test_deposit_cap pass unchanged.
- `scripts/episodes_null.py`: the null-check reader.
- `arms/learning_l1.tsv`: the `lrn-null` arm (r1k-none + E = 20, one cell, μ 0.5,
  λ 0.1/0.9). Not yet submitted.
- **Local smoke** (6 runs × 20 episodes, reference bank, depth 10, one initialisation):
  - λ constant;
  - no visible trend in P(fail) or the I − C withdrawal gap;
  - about 0.8 s per episode.

**L2 Rule A built 2026-10-28** (same branch):
- `settings.jl`: `BANKRUN_LEARN` (`none` | `precision`), `LEARN_GRIP` (κ, default 0) and
  `LEARN_MEMORY` (η, default 0.2).
- Refused combinations:
  - precision needs `PRIVATE_SIGNAL=theta`, a `THETA_PUBLIC` signal and `LAMBDA_SCOPE`
    theta or both;
  - grip and memory need precision.
- **How "θ only" is implemented:** each agent carries a learned θ weight (`LearnState`)
  that replaces λ in the θ blend only (`modelRun(...; thetaWeight)`).
  - The cultural λ (`agt.individualism`) never changes.
  - The head-count blend keeps it.
  - λ̄ is the mean of the cultural λ.
- **Timing:** episode 1 uses the cultural λ (no experience yet), so it equals the
  no-learning model. The update follows each episode; y is scored at tick 1.
- `bankRunEpisodes` gains `weightMean`, `weightSd`, `msexMean`, `mseyMean` (the θ weight
  used in the episode and the squared errors entering it; NaN without learning).
- `tests/test_learning.jl` (98 checks):
  - κ = 0 equals no learning;
  - episode 1 equals no learning for any κ;
  - the learner replayed by hand matches the reported weights in every episode;
  - the update arithmetic;
  - the refused combinations.
  test_episodes, test_theta_public, test_switch_identity, test_replay, test_partial,
  test_balance_sheet and test_cara pass unchanged.
- `arms/learning_l2.tsv`: five one-cell arms on r1k-stale-y50, E = 20 — lrn-y50-none
  (control), k25, k50, k100, and k50-ins (q 0.99). The design note's `nopub` arm is
  dropped: Rule A needs y. Reader: `scripts/learning_pilot.py` (paired with the control).
- **Local smoke** (6 runs × 20, κ 0.5, η 0.2, depth 10): C's θ weight falls 0.90 → ~0.51
  by episode 5, which is ½·0.9 + ½·λ*, with λ* ≈ 0.11 because the stale y0 = 0.5 has
  MSE ≈ 1/12 against x's 0.01. I stays ~0.10–0.13. P(fail) and gap differences at this
  size are noise.

**Next:** submit `lrn-null` and the L2 pilots on Hopper.

**Pilots read 2026-10-29** (Daily Notes/2026-10-29.md):
- **lrn-null passes:** λ constant; episode 1 = r1k-none in 250/250 runs; P(fail), episodes
  2–20, 0.244 against 0.256 (z −0.50); no trend in P(fail) or the I − C gap.
- **Rule A:** C's θ weight 0.90 → 0.70 / 0.51 / 0.12 at κ 0.25 / 0.5 / 1; I and C converge at
  κ = 1 (~0.116). Episodes 2–5 overshoot (I 0.34 at κ = 1, episode 2): the MSE prior is the
  signal variance, which treats the stale y as a noisy θ signal.
- **Learning undoes the stale signal's reassurance**, monotone in κ. P(fail) at θ ∈ [0.1, 0.2):
  no public signal 0.70; y50 0.08; κ 0.25 0.19; 0.5 0.35; 1 0.63. The stale signal's
  failures at θ ≥ 0.8 (~0.02) go to 0.
- **The withdrawal gap persists at κ = 1** (C 0.107, I 0.065), through the head-count blend,
  which keeps the cultural λ by design (decision 2).
- **lrn-y50-k50-ins is degenerate:** no endogenous withdrawals at q 0.99, and θ weights
  identical to k50 (Rule A is outcome-blind). Hence Rule B and partial coverage (decision 7).

**L2 Rule B built 2026-10-29** (same branch):
- `settings.jl`: `BANKRUN_LEARN=payoff`, under the same refused combinations as precision.
- `functions4.jl`:
  - `RunRecord.endRho`: assets over the stayers' promises at the end of a fire-sale run
    (0 after a liquidity failure, Inf if nobody stayed);
  - `stayValue`, `payoffUpdate!`; `LearnState.learned` (ω*, from the cultural λ);
  - `earlyEpisodes!` applies Rule A or Rule B after each episode; the episode rows' squared
    error columns are NaN under Rule B.
- `tests/test_payoff_learning.jl` (111 checks, in `run_tests.sh`):
  - κ = 0 equals no learning; episode 1 equals no learning;
  - the learner replayed by hand from θ, x, y and each episode's end-of-run balance;
  - the update and stay-value arithmetic, insurance included;
  - insurance moves the learned weights (Rule A could not);
  - the refused combinations.
- `arms/learning_payoff.tsv`: three one-cell arms at q 0, 0.5, 0.9.

**L3a imitation built 2026-10-29** (same branch):
- `settings.jl`: `BANKRUN_LEARN=imitate` and `payoff+imitate`, under the same refused
  combinations.
- `functions4.jl`: `realisedPayoff`, `imitationRng`, `imitateUpdate!`; `earlyEpisodes!`
  applies Rule B and/or imitation after each episode.
- `tests/test_imitation_learning.jl` (137 checks, in `run_tests.sh`):
  - κ = 0 equals no learning, for both rules; episode 1 equals no learning;
  - the learner replayed by hand episode by episode (realised payoffs, the neighbour
    draws, Rule B first under payoff+imitate), and imitation alone staying in the λ range;
  - the update arithmetic (synchronous, only toward a better-paid neighbour, no move on ties);
  - payoff+imitate differs from payoff; the refused combinations.
- `arms/learning_imitate.tsv`: six one-cell arms, imitate and payoff+imitate at q 0, 0.5, 0.9.
