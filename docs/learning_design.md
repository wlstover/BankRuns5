# Learning across episodes: design note (DRAFT, 2026-10-28)

Branch `individual-learning`, off `master` at dfb5afe. Status: design decided 10-28; ready to code L1. The
user's decisions of 2026-10-28 (voice note) are marked **[decided 10-28]** and collected in
§11; items still marked **[decide]** are the user's; items marked *(proposal)* are Claude's
suggestions.

Scope: **L1** (repeated episodes) and **L2** (individual learning of λ). **L3** (group
learning, re-running the warm-up between episodes) is described only so L1 leaves room for
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
- (L3 only) **Q4. Does the mix μ itself move?** That would make P6's "mixed population" an
  outcome rather than an input.

## 2. Terms

- **Episode:** one bank-run phase (exogenous shock, endogenous withdrawals, resolution).
- **Run:** a sequence of E episodes on one population (one network, one set of agents).
- **Cell, arm:** as now. A cell is 250 runs; an arm is a set of cells under one switch set.

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

### Rule B: payoff learning *[decided 10-28: not needed; one quick comparison arm after the rest]*

λ moves toward whichever extreme (λ = 0 or λ = 1) would have produced the ex-post right
action (withdraw if the bank failed, stay otherwise). This is closer to Arifovic-style
reinforcement learning. It needs each agent's counterfactual decision at λ = 0 and λ = 1,
so roughly 3× the decision cost. Not needed for §7. Once Rule A, the outputs and the pilots
are done, run one quick Rule B arm to see whether it differs meaningfully from Rule A.

## 5. L3 (not in this branch's first version)

Between episodes, re-run the warm-up for some ticks, with the episode's outcome feeding a
trait. For example, agents who ran and were right gain influence. Types (and μ) are then
re-derived. L1 should keep the warm-up state, not discard it, so L3 can resume from it.

## 6. Switches *(proposal)*

These follow `settings.jl`'s pattern. The defaults must reproduce today's outputs byte for
byte, with a test.

| switch | values | default |
|---|---|---|
| `BANKRUN_EPISODES` | E ≥ 1 | 1 (today's model) |
| `BANKRUN_EPISODE_RESET` | `bank` (A) / `wealth` (B) | `bank` |
| `BANKRUN_LEARN` | `none` / `precision` / `payoff` | `none` |
| `BANKRUN_LEARN_GRIP` | κ ∈ [0, 1] | 0 |
| `BANKRUN_LEARN_MEMORY` | η ∈ (0, 1] | 0.2 (decided 10-28; a later sweep axis) |

The manifest records the resolved values, and untagged runs with any switch set are refused
(as now).

## 7. Outputs

- **`bankRunEpisodes*.csv`:** one row per run × episode × type: P(fail) indicator, θ,
  withdrawal share, mean and s.d. of λ, mean MSE_x and MSE_y.
- **`bankRunLambda*.csv`** (`BANKRUN_LOG=full` only): λ trajectories for a fixed sample of
  agents.
- The existing per-run files (results, vault, types, timing, ...) are written for the last
  episode only, so the current checkers and analysis scripts keep working unchanged
  *(proposal; the user saw no problem, 10-28)*. Per-episode detail goes in the new files.

## 8. Pilot arms *(proposal; pilot before sweep)*

All on the reference bank: the r1k-none settings (fire-sale, θ fundamental, CARA 0.1,
σ 2.5 with the 1% cap). E = 20 to start.

| arm | switches | purpose |
|---|---|---|
| lrn-null | LEARN none | null check (§3) |
| lrn-k25, lrn-k50, lrn-k100 | precision, κ 0.25/0.5/1 | Q1: speed and extent of convergence of the type gap |
| lrn-k50-nopub | as k50, public signal none | learning with only the neighbour signal |
| lrn-k50-ins | as k50, insurance q 0.99 | Q2 |
| lrn-k50-wealth | as k50, RESET wealth | Q3, once A works |

What to look at first:
- the gap in mean λ between I and C by episode;
- P(fail) by episode;
- the I − C gap in withdrawal shares by episode.

**[decided 10-28]** No pre-registration for now: the pilots are exploratory.

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

## 11. Decisions (user, 2026-10-28, voice note)

1. **Bank across episodes:** a fresh bank each episode (A) for now.
2. **Rule A scores θ only.** Not the neighbour-count blend: neighbourhoods change over time
   and people move, so learning to trust one's neighbours is the weaker case. Ignore it for now.
3. **η and E:** η = 0.2 (a source's track record is roughly the last 5 episodes) and E = 20
   episodes per run (confirmed 10-28). η is a candidate sweep axis later, to see whether the
   memory length changes the results.
4. **Outputs:** old per-run files from the last episode only; new per-episode files.
5. **No pre-registration** for now.
6. **Rule B** not needed; one quick comparison arm after the rest is done.

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
