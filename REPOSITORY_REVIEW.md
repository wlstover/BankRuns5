# BankRuns5 — Repository Review

**Author:** John S. Schuler, Department of Computational and Data Sciences, George Mason University
**Last Updated:** May–June 2025
**Purpose:** Academic research project implementing and analyzing an agent-based bank run model as a replacement for the classical Diamond–Dybvig (1983) framework.

---

## Table of Contents

1. [Research Context and Motivation](#1-research-context-and-motivation)
2. [Repository Architecture Overview](#2-repository-architecture-overview)
3. [File-by-File Description](#3-file-by-file-description)
   - [Julia Simulation Code](#julia-simulation-code)
   - [R Analysis Code](#r-analysis-code)
   - [LaTeX Paper and Bibliography](#latex-paper-and-bibliography)
   - [Infrastructure and Configuration](#infrastructure-and-configuration)
4. [Model Description](#4-model-description)
   - [Agents and Network](#agents-and-network)
   - [Cultural Heterogeneity: Individualism and Collectivism](#cultural-heterogeneity-individualism-and-collectivism)
   - [The Bank](#the-bank)
   - [Model Dynamics: Exogenous Withdrawals](#model-dynamics-exogenous-withdrawals)
   - [Model Dynamics: Endogenous Decision-Making](#model-dynamics-endogenous-decision-making)
   - [Deposit Insurance](#deposit-insurance)
   - [Termination Condition](#termination-condition)
5. [Parameter Sweep Design](#5-parameter-sweep-design)
6. [Distributed Computing Architecture](#6-distributed-computing-architecture)
7. [Data Pipeline](#7-data-pipeline)
8. [Analysis and Results](#8-analysis-and-results)
9. [Theoretical Development](#9-theoretical-development)

---

## 1. Research Context and Motivation

This project is the codebase for an academic paper titled **"A Bank Run Model for the Twentieth Century"**. The central claim is that the canonical Diamond–Dybvig (1983) model has a fundamental modeling artifact: when agents decide whether to withdraw from a bank, they are effectively *buying an option* whose payoff is dominated by an insurance payout that is not a feature of real-world deposit banking. The paper argues this artifact—not any deep economic mechanism—drives the model's behavior.

The paper's response is to build a **replacement agent-based model (ABM)** grounded in the following observations:

- Agents care primarily about whether they can recover their full deposit, not about expected-utility maximization over complex contracts.
- Social networks play a meaningful role in bank runs (motivated in part by the 2023 Silicon Valley Bank collapse, where information spread through concentrated social networks).
- Focusing on *marginal agent behavior* rather than equilibria is a more productive modeling strategy.

The paper situates itself in a rich literature including Diamond & Dybvig (1983), Postlewaite & Vives (1987), Shell & Zhang (2019), Kinateder & Kiss (2014), Green & Lin (2000), Smith & Shubik (2014), and others.

---

## 2. Repository Architecture Overview

```
BankRuns5/
│
├── Simulation (Julia)
│   ├── objects.jl          # Data structure definitions
│   ├── functions4.jl       # Model logic, agent decisions, parallelism helpers
│   ├── warmup.jl           # Flache-Macy cultural dynamics warm-up phase
│   ├── parameterGen.jl     # Parameter sweep grid construction
│   ├── finMain0001.jl      # Main entry point; distributed execution controller
│   ├── test_run.jl         # Small-scale sanity-check sweep for individualism params
│   ├── modelStep.jl        # Minimal stub for running one model
│   ├── model3_ws_homogeneous.jl  # Model 3: closed-form, homogeneous deposits
│   ├── restart.jl          # Resume logic for interrupted sweeps
│   ├── jld2CSV.jl          # Convert JLD2 data files to CSV
│   ├── dataTools.jl        # Simple JLD2 loader utility
│   └── sysImage.jl         # Compile Julia system image for faster worker startup
│
├── Analysis (R)
│   ├── analysis.R          # Quick top-level failure rate summary
│   ├── analysis2.R         # Full analysis: withdrawals, failure by parameters, plots
│   └── workingAnalysis.R   # Extended analysis: vault percentages, run histories
│   └── finAnalysis.R       # (Legacy/other project — anti-trust model analysis)
│
├── Paper and Documentation
│   ├── REPOSITORY_REVIEW.md # Repository overview, model structure, theoretical development
│   ├── next_steps.md       # Forward tracker: open items, HPC runbook
│   ├── future_work.md      # Proposed extensions
│   └── draft/              # the paper (moved here 2026-08-19)
│       ├── paper_draft.md  # CANONICAL Ch 3 prose (Markdown)
│       ├── abm_chapter.tex # generated from paper_draft.md by scripts/convert_abm.py;
│       │                   #   \input{} by the dissertation — do not hand-edit
│       ├── draft.Rnw       # superseded Sweave source
│       ├── draft.tex       # superseded, compiled from draft.Rnw
│       ├── draft.pdf       # superseded, compiled PDF
│       └── banking.bib     # BibTeX references (Ch 3)
│
└── Infrastructure
    ├── run_sweep.sh        # Bash script to execute the full parameter sweep (local)
    ├── sweep.slurm         # SLURM batch script for HPC parameter sweep
    ├── params.txt          # Pre-generated parameter grid (12,960 combinations)
    ├── BankRuns5.Rproj     # RStudio project file
    └── .gitignore
```

**Language split:** The computationally intensive simulation runs in **Julia** (exploiting multi-process parallelism). Statistical analysis and visualization run in **R** (tidyverse, ggplot2, data.table).

---

## 3. File-by-File Description

### Julia Simulation Code

#### `objects.jl`
Defines the core mutable structs used throughout the simulation. There are two parallel type families: "real" types that represent the actual model state, and "sim" types used for Monte Carlo sub-simulations inside each agent's decision-making.

| Type | Fields | Purpose |
|------|--------|---------|
| `Agent` | `idx`, `deposit`, `banked`, `individualism` | Real agent in the main model |
| `simAgent` | `idx`, `deposit`, `banked`, `individualism` | Clone agent used in sub-simulations |
| `Bank` | `vault`, `bankingList`, `withdrawHistory` | Main bank state |
| `simBank` | `vault`, `bankingList`, `withdrawHistory` | Clone bank for sub-simulations |
| `Model` | `key`, `agtList`, `reserveRatio`, `theBank`, `depositInsurance`, `seed1`, `seed2`, `depositDistribution`, `network`, `probThresh`, `exogProb` | Full main model |
| `simModel` | `agtList`, `theBank`, `depositInsurance`, `depositDistribution` | Lightweight clone for sub-simulations |

The `individualism` field (λ ∈ [0,1]) controls the weight each agent places on the neighbor signal versus their own Monte Carlo prior during endogenous decision-making (see Section 4 for details).

The dual type hierarchy prevents agents from confusing their sub-simulation clones with the real model state.

---

#### `functions4.jl`
The heart of the simulation. Contains all model logic in ~536 lines.

**`LAMBDA_CONC` (constant)**
Concentration parameter (κ = 20) for the within-type Beta distributions used to draw each agent's individualism λ. At κ = 20, σ ≈ 0.09 for a type mean of 0.5, providing within-type heterogeneity while keeping the distribution tightly peaked near each type's mean.

**`modelGen(...)`**
Initializes a model from parameters. The function now takes four additional cultural heterogeneity parameters (`warmupAlpha`, `fracIndividualists`, `lambdaI`, `lambdaC`) and proceeds as follows:

1. **Warm-up phase:** Runs the Flache-Macy cultural dynamics (via `warmup()` from `warmup.jl`) on the Watts-Strogatz network, producing a per-agent warm-up λ score reflecting cultural position.
2. **Type assignment:** Ranks agents by warm-up λ (descending). The top `fracIndividualists` (μ) fraction becomes type I (individualist); the rest become type C (collectivist).
3. **Per-agent λ draws:** Each agent draws a continuous λ from a Beta distribution centred on their type mean — `Beta(λ_I·κ, (1−λ_I)·κ)` for type I, `Beta(λ_C·κ, (1−λ_C)·κ)` for type C — with `LAMBDA_CONC` as the shared concentration.
4. **Deposits:** Seeds the RNG to `seed1` (so deposit draws are unaffected by warm-up or λ draws) and draws deposits from `depositDistribution`.
5. **Agent construction and logging:** Creates `Agent` structs with the drawn λ as `individualism`. Writes to CSV with columns: `key`, `idx`, `deposit`, `individualism`, `warmupLambda`, `agentType`.
6. **Bank initialization:** Sets vault = `reserveRatio × sum(deposits)`.

**`neighborList(mod, agt)`**
Returns the neighbors of `agt` in the model's social network graph.

**`clone(mod::Model)` / `clone(mod::simModel)`**
Deep-copies the model state into a `simModel`, including the `individualism` field. Used extensively before each Monte Carlo sub-simulation to avoid mutating the true model state.

**`withdraw(mod, agt)`**
Executes one withdrawal. Determines the deposit insurance cap, removes the agent from the banking list, and debits the vault. If the vault balance is insufficient to pay the full deposit, the agent receives the lesser of their deposit or the deposit insurance maximum (or the vault balance if even that is unavailable).

**`exogWithdrawals(mod)`**
Draws a count of exogenous withdrawals from `mod.exogProb` (a truncated geometric distribution) and removes those agents from the bank before the endogenous decision phase begins. Logs each withdrawal to CSV.

**`subModelRun(mod::simModel, agt, withdrawingAgents, additionalWithdrawals)`**
Runs a single Monte Carlo trial for one agent's decision. Forces observed neighbor withdrawals, then draws `additionalWithdrawals` more agents to withdraw (representing expected unknown endogenous withdrawals), then simulates the focal agent withdrawing. Returns the payout and whether the payout was less than the full deposit.

**`modelRun(mod)`**
The main simulation loop:
1. Run exogenous withdrawals.
2. Clone the model for sub-simulation reference.
3. Loop over still-banking agents (shuffled each tick):
   - Observe what fraction of network neighbors have withdrawn.
   - Infer total expected withdrawals across the population (`totalWithdrawnPoint`).
   - **Blended belief formation:** Draw `depth` samples from the untruncated exogenous distribution (agent's own MC prior). Blend each draw with the neighbor-signal point estimate using the agent's λ: `blendedTotal = (1−λ) × mcDraw + λ × totalWithdrawnPoint`. This yields per-agent heterogeneous additional withdrawal estimates:
     - λ near 0 (individualist): ignores neighbor signal, relies on own MC prior.
     - λ near 1 (collectivist): follows neighbor signal, ignores own MC prior.
   - Run `depth=1000` Monte Carlo trials for both the "withdraw now" and "stay" strategies.
   - If P(get full deposit | withdraw now) > P(get full deposit | stay) **or** P(withdraw) == 0, withdraw.
   - Log the decision to CSV.
   - If the vault hits zero, declare bank failure and return `true`.
4. Repeat until no agent changes their decision (stable state) or failure. Returns `false` if no failure.

**Parallelism helpers: `rowPull`, `checkOff`, `modelCall`**
Implement a shared work queue pattern. `rowPull` (running on process 1, protected by a `ReentrantLock`) atomically grabs the next unstarted parameter row. `modelCall` (running on each worker) pulls a row, runs the full model, and writes results — now passing `warmupAlpha`, `fracIndividualists`, `lambdaI`, `lambdaC` to `modelGen`. `checkOff` marks a row complete on the master.

**`myCore(c)`**
Sets a worker-local global `workerCore` so each process writes its CSV output to separate files (avoiding write conflicts).

---

#### `parameterGen.jl`
Reads CLI arguments and constructs the full parameter grid (`jointFrame`) as a `DataFrame`. Each row represents one complete simulation run with a unique combination of:

- `seed1` (agent/deposit initialization seed)
- `seed2` (model dynamics seed)
- `iteration` (run index within a seed)
- `depositDist` (LogNormal or Pareto distribution object)
- `network` (a pre-generated Watts-Strogatz graph)
- `withdrawRV` (truncated Geometric distribution)
- `reserveRatio`
- `depositInsuranceQuantile`
- `warmupAlpha` (Flache-Macy learning rate α)
- `fracIndividualists` (μ: fraction of agents assigned type I)
- `lambdaI` (mean of individualist Beta distribution)
- `lambdaC` (mean of collectivist Beta distribution)

The grid is serialized as a `.jld2` file and the parameter metadata written to CSVs. A unique string `key` (timestamp + seed pair) identifies each run for later data joining. The `bankRunParametersInit.csv` output now includes columns for all cultural heterogeneity parameters.

CLI arguments consumed:
```
ARGS[1]  = data directory
ARGS[2]  = generation seed
ARGS[3]  = reserve ratio
ARGS[4]  = deposit insurance quantile
ARGS[5]  = distribution name ("Pareto" or "LogNormal")
ARGS[6]  = distribution param 1 (alpha or mu)
ARGS[7]  = distribution param 2 (theta or sigma)  [LogNormal only]
ARGS[8]  = Watts-Strogatz k
ARGS[9]  = Watts-Strogatz p
ARGS[10] = warmupAlpha (Flache-Macy learning rate)
ARGS[11] = fracIndividualists (μ: fraction type I)
ARGS[12] = lambdaI (individualist signal weight mean)
ARGS[13] = lambdaC (collectivist signal weight mean)
```

---

#### `finMain0001.jl`
The main controller script. Responsibilities:

1. Start 16 Julia worker processes (using a precompiled sysimage if available for faster startup).
2. Load all packages on all workers with `@everywhere`.
3. Broadcast CLI arguments (now 13 args including cultural heterogeneity parameters) to all workers.
4. Set `depth = 1000` (Monte Carlo trials per agent decision) globally on all workers.
5. Include `objects.jl`, `warmup.jl`, and `functions4.jl` on all workers.
6. Assign each worker its core ID via `myCore`.
7. Run `parameterGen.jl` on process 1 to populate `jointFrame`.
8. Execute the distributed work queue: loop until all rows are `completed`, dispatching `modelCall()` to each free worker core.
9. Write a final completion log CSV.

---

#### `modelStep.jl`
A minimal three-line stub (`modelRun(mod)` + print + `:complete`) used for testing a single model step interactively. Not part of the main sweep pipeline.

---

#### `restart.jl`
Handles recovery after an interrupted sweep. Loads all `.jld2` parameter files in the data directory, stacks them into a single `jointFrame`, cross-references against completed result files, and prunes dangling partial outputs (endogenous, exogenous, agent CSVs) for keys that did not complete. Updates `jointFrame.completed` for finished keys so the sweep can resume without re-running finished simulations.

---

#### `jld2CSV.jl`
A one-off conversion script that reads a JLD2 archive, extracts deposit distribution and withdrawal distribution parameters (as numeric columns), computes betweenness centrality for each network, and writes a supplemental CSV. Useful for loading graph-theoretic and distributional metadata into R for analysis.

---

#### `dataTools.jl`
Two-line stub: loads a `data.jld2` file. Appears to be a development utility.

---

#### `warmup.jl`
Implements the **Flache & Macy (2011) social influence model with negative influence** as a cultural warm-up phase. This module runs *before* the bank-run simulation and produces per-agent individualism scores that feed into the endogenous decision-making.

**Constants:**
- `WARMUP_FEATURES = 5` — cultural opinion dimensions.
- `WARMUP_MAX_TICKS = 500` — hard cap on warm-up iterations.
- `WARMUP_EPS = 1e-6` — convergence threshold (mean |Δopinion| per agent per tick).

**`CulturalAgent` struct:** Holds `idx`, `opinions` (Vector{Float64} in [-1, 1]), `adoptCount` (culturally aligned interactions), and `resistCount` (culturally opposed interactions).

**`influenceWeight(a, b)`:** Computes w_ij = (1/F) × Σ_f(a_if × a_jf) ∈ [-1, 1]. Positive for correlated opinion profiles (convergence), negative for anti-correlated (repulsion).

**`warmupInit(agtCnt, network, seed)`:** Creates cultural agents with opinions drawn uniformly from [-1, 1].

**`warmupRun!(agents, network; alpha)`:** Iterates Flache-Macy dynamics. Each tick, agents are visited in random order. Each agent selects one random neighbour, computes influence weight w_ij, and updates opinions: Δa = α × w_ij × (a_j − a_i), clamped to [-1, 1]. If w_ij > 0, adoptCount increments; otherwise resistCount increments. Converges when opinions reach ±1 extremes (full cultural polarisation).

**`computeLambda(agents)`:** Returns λ_i = resistCount_i / (adoptCount_i + resistCount_i) for each agent. Agents in homogeneous clusters accumulate high adoptCount → low λ (collectivist). Agents at cultural boundaries accumulate high resistCount → high λ (individualist). Isolated nodes receive λ = 0.5.

**`warmup(agtCnt, network, seed; alpha)`:** Full pipeline: initialise, run dynamics, return per-agent λ values.

The learning-rate parameter α (`warmupAlpha` in the sweep) controls how quickly cultural polarisation occurs; different α values yield different cluster assignments and λ distributions, making α a meaningful sweep parameter.

---

#### `test_run.jl`
A self-contained small-scale sanity-check sweep for the individualism/collectivism parameters. Runs with `julia --project=. test_run.jl` (no distributed workers, no CLI args). Sweeps over μ × (λ_I, λ_C) combinations with reduced scale (N=200 agents, depth=50 MC trials, 20 replications per cell). Prints a summary table of bank-run probabilities by parameter combination and writes `test_results.csv`. Key checks:

1. Higher λ gap (λ_C − λ_I) → stronger non-monotonicity in μ.
2. μ = 0 (all collectivist) vs μ = 1 (all individualist) set the floor/ceiling.
3. Within-type λ draws are continuous (validates Beta distribution centering).

---

#### `sysImage.jl`
Uses Julia's `PackageCompiler` to compile a precompiled system image (`sysimage.so`) bundling the main dependencies. This dramatically reduces worker startup time when running large sweeps on a cluster.

---

### R Analysis Code

#### `analysis.R`
The simplest analysis script. Reads all `bankRunResults*.csv` files from the data directory, combines them, and computes the overall mean failure rate. Provides a single top-level statistic.

---

#### `analysis2.R`
The primary analysis script. Reads all output CSVs, assembles full datasets, and produces:

- Scatter plot of agent-level `wdProb` vs `stayProb` colored by bank failure outcome.
- Tabular binned summary of decision probabilities.
- Failure probability grouped by `reserveRatio`.
- Failure probability grouped by graph parameters (`graphParams1`, `graphParams2`).
- Failure probability grouped by `depositInsuranceQuantile`.
- Histograms of endogenous and exogenous withdrawal counts by failure outcome.
- A stacked histogram combining both withdrawal types.
- A scatter plot of exogenous vs endogenous withdrawal counts with marginal histograms (via `ggExtra`).

---

#### `workingAnalysis.R`
A deeper, partially-completed analysis script. Extends `analysis2.R` with:

- Merging the Geometric and LogNormal parameter CSVs with the control file for richer filtering.
- Failure probability summaries grouped by network parameters, reserve ratio, and deposit insurance quantile.
- Computation of total deposit amounts and initial vault sizes.
- Exogenous and endogenous withdrawal volumes expressed as a percentage of the initial vault (key metric for characterizing severity of runs).
- A scatter plot of exogenous vs endogenous withdrawal percentages with a diagonal boundary line showing the vault depletion constraint.
- A `modHistory()` function skeleton for reconstructing the per-tick history of a given run.

---

#### `finAnalysis.R`
**Note:** Despite residing in this repository, this file analyzes an *anti-trust model*, not the bank run model. It reads data from `~/ResearchCode/antiTrustData`, defines a modified logit function, and builds analysis around a "privacy index." This appears to be a legacy file from a different project that was not removed.

---

### LaTeX Paper and Bibliography

#### `draft/draft.Rnw`
The main academic paper, written in **R Sweave** format (a mix of LaTeX and R chunks). The paper's argument structure:

1. **Introduction** — Bank runs as self-fulfilling prophecies; the role of psychology; the argument for agent-based modeling.
2. **Diamond-Dybvig and literature review** — Summary of DD (1983) and the main follow-on literature (Postlewaite & Vives 1987; Shell & Zhang 2019; Kinateder & Kiss 2014; Green & Lin 2000; Smith & Shubik 2014; Peck & Shell 2003; etc.).
3. **A Stochastic Process Version of DD** — Formal probabilistic restatement of Diamond-Dybvig; shows that agents are choosing a deposit level to maximize expected utility over a distribution over outcomes. Shows `P(failure) = ψ(p, ι, π)` where p is the exogenous withdrawal probability, ι is the insurance payout, and π is the investment return. **Key criticism:** in the DD framework agents are *buying an option*, and the behavior is driven by the insurance payout—an artifact absent from real banking.
4. **Bank Runs Revisited** — Motivates the ABM replacement. Key argument: the opportunity cost of unnecessary withdrawal is merely foregone interest (small relative to total deposits), so agents need not use full Von-Neumann-Morgenstern utility; a simple withdrawal-probability threshold suffices.
5. **A Simple Replacement Model** — Describes the ABM (1000 agents, LogNormal deposits, Watts-Strogatz network, truncated geometric exogenous withdrawals, Monte Carlo decision-making).
6. **Conclusion** — (Placeholder).

---

#### `draft/banking.bib`
BibTeX file with 16 references spanning the Diamond-Dybvig tradition, including Diamond (1983, 2007), White (1999), Postlewaite & Vives (1987), Kinateder & Kiss (2014), Nosal & Wallace (2009), Green & Lin (2000), Peck & Shell (2003), Smith & Shubik (2014), Galbraith, and Bookstaber.

---

### Infrastructure and Configuration

#### `run_sweep.sh`
The top-level shell script to execute the full parameter sweep. It iterates over all combinations of:

| Parameter | Values |
|-----------|--------|
| `RESERVE_RATIOS` | 0.2, 0.4 |
| `DEP_QUANTILES` | 0.1, 0.2, 0.3, 0.4 |
| `DIST_NAME` | LogNormal (fixed) |
| `LOGN_MU` | 1.0 (fixed) |
| `LOGN_SIGMAS` | 2.0, 3.0 |
| `WS_KS` | 6, 10, 50 |
| `WS_PS` | 0.05, 0.15 |
| `WARMUP_ALPHAS` | 0.1, 0.3, 0.5 |
| `MU_VALUES` (μ) | 0.0, 0.25, 0.5, 0.75, 1.0 |
| `LAMBDA_I_VALUES` (λ_I) | 0.1, 0.2, 0.3 |
| `LAMBDA_C_VALUES` (λ_C) | 0.5, 0.7, 0.9 |

This yields **2 × 4 × 2 × 3 × 2 × 3 × 5 × 3 × 3 = 38,880 jobs**, each launching a full Julia process with 16 worker cores. Each job runs `finMain0001.jl` with a unique generation seed (starting at 1001, incrementing per job) and 13 CLI arguments. Within each job, the parameter grid produces 5 seed repeats × 10 iterations = **50 simulation runs per job**, for a total of **1,944,000 model runs**.

---

#### `sweep.slurm`
SLURM batch submission script for running the full parameter sweep on an HPC cluster. Key configuration:

- `--array=2-12960%50` — submits 12,959 tasks (one per parameter combination, skipping line 1 as header), with at most 50 running concurrently.
- `--cpus-per-task=16` — matches the 16-process Julia setup (1 master + 15 workers).
- `--mem=32G`, `--time=0-03:00:00` — 32 GB RAM and 3-hour wall clock per task.

Each task reads its parameter combination from `params.txt` (line number = `SLURM_ARRAY_TASK_ID`), creates an isolated output directory `outputs/task_${SLURM_ARRAY_TASK_ID}/` to avoid per-worker CSV filename collisions, and launches `finMain0001.jl` with all 13 CLI arguments.

---

#### `params.txt`
Pre-generated file with 12,960 lines (one header + 12,959 parameter combinations). Each line contains space-separated values: `reserve depq sigma k p alpha mu lambdaI lambdaC`. Generated from the full factorial cross of the sweep parameters. Referenced by `sweep.slurm` to map SLURM array task IDs to parameter combinations.

---

#### `BankRuns5.Rproj`
Standard RStudio project configuration file. Sets the working directory and basic project metadata.

---

## 4. Model Description

### Agents and Network

The model contains **1,000 agents** (hardcoded in `finMain0001.jl`). Each agent has:
- A **deposit** drawn from a LogNormal or Pareto distribution.
- A **`banked` flag** (initially `true`).
- An **`individualism` score** (λ ∈ [0,1]) controlling the weight placed on the neighbor signal vs. own Monte Carlo prior during endogenous decision-making.

Agents are connected in a **Newman–Watts–Strogatz small-world network** with parameters `k` (baseline degree) and `p` (rewiring probability). This network serves dual roles: (1) it determines each agent's information set during the bank-run phase (an agent only observes whether its direct neighbors are banking or have withdrawn), and (2) it is the substrate for the Flache-Macy cultural warm-up dynamics that produce the individualism scores.

---

### Cultural Heterogeneity: Individualism and Collectivism

Agents are heterogeneous not only in deposit size but in their susceptibility to social influence during withdrawal decisions. This is implemented via a three-stage pipeline:

#### Stage 1: Flache-Macy Cultural Warm-Up (`warmup.jl`)

Before the bank-run simulation begins, agents undergo a cultural formation phase based on the Flache & Macy (2011) social influence model with negative influence. Each agent holds opinions on F = 5 cultural dimensions ∈ [-1, 1], initialised uniformly at random.

At each warm-up tick, agents interact with a random neighbour on the same Watts-Strogatz network used for the bank-run phase:
- **Influence weight:** w_ij = (1/F) × Σ_f(a_if × a_jf) ∈ [-1, 1]. Positive for culturally similar dyads (convergence), negative for dissimilar (repulsion).
- **Opinion update:** Δa_if = α × w_ij × (a_jf − a_if), clamped to [-1, 1]. The learning rate α (`warmupAlpha`) is a swept parameter.
- **Tally:** w_ij > 0 → `adoptCount++` (culturally aligned); w_ij ≤ 0 → `resistCount++` (culturally opposed).

The dynamics converge when opinions reach ±1 extremes (full cultural polarisation), producing stable cultural clusters. The raw warm-up λ is computed as:

$$\lambda_i^{\text{warmup}} = \frac{\text{resistCount}_i}{\text{adoptCount}_i + \text{resistCount}_i}$$

Agents embedded in homogeneous clusters accumulate high adoptCount → low λ (collectivist). Agents at cultural boundaries accumulate high resistCount → high λ (individualist).

#### Stage 2: Two-Type Assignment

Agents are ranked by their warm-up λ (descending). The top μ fraction (the `fracIndividualists` parameter) is assigned **type I** (individualist); the remainder is assigned **type C** (collectivist). The warm-up score determines *who* belongs to which type; μ controls *how many*.

#### Stage 3: Per-Agent λ Draws from Beta Distributions

Each agent draws a continuous λ from a Beta distribution centred on their type mean, with shared concentration κ (`LAMBDA_CONC = 20`):
- **Type I:** λ ~ Beta(λ_I·κ, (1−λ_I)·κ), with E[λ] = λ_I
- **Type C:** λ ~ Beta(λ_C·κ, (1−λ_C)·κ), with E[λ] = λ_C

The swept parameters λ_I and λ_C are constrained so that λ_I < λ_C (individualists are less susceptible to social signals than collectivists). The concentration κ = 20 yields σ ≈ 0.09 at a mean of 0.5, providing within-type heterogeneity while keeping the distribution tightly peaked.

#### Role in Endogenous Decision-Making

During the bank-run phase, each agent's λ controls belief formation about total population withdrawals. The agent draws `depth` samples from the untruncated exogenous Geometric distribution (its own MC prior), then blends each with the neighbor-signal point estimate:

$$\text{blendedTotal}_k = (1 - \lambda) \times \text{mcDraw}_k + \lambda \times \text{totalWithdrawnPoint}$$

- **λ near 0 (individualist):** Relies on own MC prior, ignores neighbor signal. Self-reliant; withdraws only when its independent estimate of risk is high.
- **λ near 1 (collectivist):** Follows neighbor signal, ignores own MC prior. Signal-driven; easily tipped by aggregate withdrawal information.

This produces a theoretical prediction for the fixed-point withdrawal thresholds:
$$s^*_I = \theta - \lambda_I \cdot f(\mu \cdot \Phi(s^*_I) + (1-\mu) \cdot \Phi(s^*_C))$$
$$s^*_C = \theta - \lambda_C \cdot f(\mu \cdot \Phi(s^*_I) + (1-\mu) \cdot \Phi(s^*_C))$$

Since λ_I < λ_C, individualists have a higher withdrawal threshold (s\*_I > s\*_C) — they require a stronger signal before withdrawing. The bank-run probability is predicted to be non-monotonic in μ: neither all-individualist nor all-collectivist populations necessarily minimise run risk; the interaction between types matters.

---

### The Bank

The bank is initialized with a **vault** equal to `reserveRatio × sum(all deposits)`. This represents fractional reserve banking: the bank keeps only a fraction of deposits on hand as liquid reserves. The bank maintains:
- `bankingList` — agents currently deposited.
- `withdrawHistory` — agents who have withdrawn.

The bank has no investment technology in this model; it is purely a liquidity pool. This simplification lets the model focus on the run mechanism rather than insolvency from asset losses.

---

### Model Dynamics: Exogenous Withdrawals

Before any agent decision-making, a random number of agents withdraw exogenously, drawn from a **truncated Geometric distribution** `Geometric(p=0.1)` truncated to `[0, 1000]`. These represent agents who need cash for reasons unrelated to bank solvency (e.g., consumption shocks). They are selected uniformly at random from the full agent list.

---

### Model Dynamics: Endogenous Decision-Making

After exogenous withdrawals, the remaining banked agents iteratively reconsider their position. Each tick:

1. The still-banking list is **shuffled** (random service order).
2. For each agent:
   a. **Observe neighbors:** Count how many network neighbors have withdrawn (`withdrawnNeighbors`).
   b. **Infer population state:** Scale to estimate total withdrawals population-wide as `propWithdrawn × N` (`totalWithdrawnPoint`), clamped to [0, N−1].
   c. **Blended belief formation:** Draw `depth = 1000` samples from the untruncated exogenous Geometric distribution (the agent's own MC prior). Blend each draw with the neighbor-signal point estimate using the agent's individualism λ: `blendedTotal = (1−λ) × mcDraw + λ × totalWithdrawnPoint`. Compute additional withdrawals as `max(0, blendedTotal − withdrawnNeighborCount)`. Individualists (low λ) rely on their own prior; collectivists (high λ) follow the neighbor signal.
   d. **Monte Carlo: "withdraw now" strategy:** For each of the 1,000 blended samples, clone the current model state and simulate the focal agent withdrawing immediately. Record whether the payout equals the full deposit.
   e. **Monte Carlo: "stay" strategy:** For each sample, additionally force the sampled additional agents to withdraw, then simulate the focal agent withdrawing. Record whether the payout equals the full deposit.
   f. **Decision rule:** If `P(full payout | withdraw now) > P(full payout | stay)` or if `P(full payout | withdraw now) == 0`, **withdraw**. Otherwise, stay.
   g. Log both probabilities and the decision to CSV.
3. If any agent withdrew this tick, repeat from step 1 (other agents may re-evaluate). If no agent withdrew, the model has reached a stable state.

The decision rule avoids Von-Neumann-Morgenstern utility. Agents simply compare their probability of recovering their full deposit under the two strategies. This is behaviorally motivated: the cost of unnecessary withdrawal is only foregone interest (small), while the cost of failing to withdraw from a failing bank is the total deposit loss.

---

### Deposit Insurance

Deposit insurance is parameterized as a **quantile of the deposit distribution** (e.g., `depositInsuranceQuantile = 0.2` means the maximum insured amount is the 20th percentile of the deposit distribution). The insurance cap is computed as `quantile(depositDistribution, depositInsuranceQuantile)`.

When a withdrawal occurs:
- If the vault has enough to pay the full deposit: agent gets the full deposit.
- If the vault is insufficient: agent receives `max(0, vault, min(deposit, insuranceCap))`.

This models partial deposit insurance covering small depositors but not large ones.

---

### Termination Condition

The simulation terminates when either:
- **No agent changes state** in a full pass (stable equilibrium reached) → `modelRun` returns `false` (no failure).
- **The vault reaches zero or below** → `modelRun` returns `true` (bank failure).

---

## 5. Parameter Sweep Design

Each model run is uniquely identified by a `key` string (timestamp + two random seeds). Parameters varied across the sweep:

| Parameter | Role | Values Swept |
|-----------|------|-------------|
| `reserveRatio` | Bank liquidity buffer | 0.2, 0.4 |
| `depositInsuranceQuantile` | Insurance coverage depth | 0.1, 0.2, 0.3, 0.4 |
| `sigma` (LogNormal) | Deposit inequality | 2.0, 3.0 |
| `k` (Watts-Strogatz) | Network connectivity | 6, 10, 50 |
| `p` (Watts-Strogatz) | Network randomness | 0.05, 0.15 |
| `warmupAlpha` | Flache-Macy learning rate | 0.1, 0.3, 0.5 |
| `fracIndividualists` (μ) | Fraction type I (individualist) | 0.0, 0.25, 0.5, 0.75, 1.0 |
| `lambdaI` (λ_I) | Individualist signal weight mean | 0.1, 0.2, 0.3 |
| `lambdaC` (λ_C) | Collectivist signal weight mean | 0.5, 0.7, 0.9 |
| `seed1` | Deposit draw randomness | 5 random seeds |
| `iteration` | Run replication | 10 per seed |

The λ_I and λ_C ranges are non-overlapping (max λ_I = 0.3 < min λ_C = 0.5) so that λ_I < λ_C holds for every combination. This ensures individualists are always less susceptible to the neighbor signal than collectivists.

This yields **2 × 4 × 2 × 3 × 2 × 3 × 5 × 3 × 3 = 12,960 jobs**, each launching a full Julia process with 16 worker cores. Each job runs `finMain0001.jl` with a unique generation seed (starting at 1001, incrementing per job) and 13 CLI arguments. Within each job, the parameter grid produces 5 seed repeats × 10 iterations = **50 simulation runs per job**, for a total of **648,000 model runs**.

**Fixed parameters:**
- Agent count: 1,000
- Deposit distribution: LogNormal(μ=1.0, σ=varied)
- Exogenous withdrawal distribution: truncated Geometric(p=0.1)
- Monte Carlo depth: 1,000 trials per agent decision
- Decision threshold: implied by the comparison of withdrawal vs. stay probabilities
- Warm-up hyperparameters: F = 5 cultural dimensions, max 500 ticks, ε = 1e-6 convergence
- Within-type Beta concentration: κ = 20

---

## 6. Distributed Computing Architecture

The model runs with **Julia's `Distributed` module** using a **master-worker** pattern:

```
Process 1 (master)
  ├─ Holds jointFrame (parameter grid)
  ├─ rowPull() — atomically assigns next unstarted row (ReentrantLock protected)
  ├─ checkOff() — marks row as completed
  └─ Monitors loop until all rows completed

Processes 2..16 (workers)
  └─ modelCall() — in a loop:
       1. @spawnat 1 rowPull()   → get a parameter row
       2. modelGen(...)          → initialize model
       3. modelRun(...)          → run simulation
       4. @spawnat 1 checkOff()  → mark complete
       5. CSV.write(...)         → write results to worker-local file
```

Each worker writes to its own CSV files (suffixed by `workerCore`) to avoid file-write conflicts. Post-hoc R analysis combines these files with `rbindlist`.

A precompiled Julia system image (`sysimage.so`, built by `sysImage.jl`) is used when available to reduce the startup time of each worker process.

---

## 7. Data Pipeline

```
run_sweep.sh
    └── finMain0001.jl (×38,880 jobs)
            ├── warmup.jl          (cultural warm-up on each worker)
            ├── parameterGen.jl → bankRunParametersInit.csv
            │                     bankRunlogNormal.csv
            │                     bankRunGeometric.csv
            │                     key*.jld2
            └── modelCall() × N_runs
                    ├── agents{core}.csv          (deposit, λ, warmupLambda, agentType per agent)
                    ├── bankRunExogenous{core}.csv (exogenous withdrawal events)
                    ├── bankRunEndogenous{core}.csv (endogenous decision events)
                    └── bankRunResults{core}.csv   (per-run failure outcome)

restart.jl (optional)
    └── Loads *.jld2, cross-references Results CSVs, prunes orphan partial outputs

jld2CSV.jl (optional)
    └── supplemental.csv (network centrality + distribution params)

R Analysis
    ├── analysis.R         → overall failure rate
    ├── analysis2.R        → failure by parameters, withdrawal scatter plots
    └── workingAnalysis.R  → vault-percentage analysis, run history reconstruction
```

**New columns in output files (vs. base model):**

| File | New Columns | Description |
|------|-------------|-------------|
| `bankRunParametersInit.csv` | `warmupAlpha`, `fracIndividualists`, `lambdaI`, `lambdaC` | Cultural heterogeneity parameters per run |
| `agents{core}.csv` | `individualism`, `warmupLambda`, `agentType` | Per-agent drawn λ, raw warm-up score, and type label (I/C) |

---

## 8. Analysis and Results

The R scripts compute the following key outcomes:

### Primary Outcome: Bank Failure Rate
Each model run produces a binary `result` (true = failure, false = no failure). The analysis scripts compute failure probabilities stratified by:

- **Reserve ratio** (`reserveRatio`): Higher reserve ratios protect against failure by giving the bank more liquidity.
- **Network parameters** (`graphParams1 = k`, `graphParams2 = p`): Denser networks (higher `k`) may propagate panic faster; more random networks (higher `p`) could accelerate or dampen runs depending on community structure.
- **Deposit insurance quantile** (`depositInsuranceQuantile`): Deeper insurance coverage reduces the expected loss from bank failure, which changes agent incentives.
- **Deposit inequality** (`sigma` of the LogNormal): Heavier-tailed distributions create more heterogeneity in depositor stakes.

### Secondary Outcomes: Withdrawal Dynamics
- **Exogenous withdrawal count:** Distribution of the exogenous shock that initiates the run process.
- **Endogenous withdrawal count:** How many agents chose to withdraw based on their Monte Carlo calculations. In failure cases, this reflects a self-fulfilling cascade.
- **Vault depletion percentage:** Both exogenous and endogenous withdrawals expressed as percentages of the initial vault, showing whether failure was driven primarily by the initial shock or by the endogenous cascade.

### Key Analytical Plots
1. **`wdProb` vs `stayProb` scatter** (colored by failure): Shows the relationship between individual agent withdrawal and stay probabilities and final bank outcome.
2. **Exogenous vs endogenous withdrawal scatter** (with marginal histograms): Distinguishes runs driven by large shocks vs. self-fulfilling panics.
3. **Withdrawal counts by failure outcome** (histograms): Shows the distributions of both withdrawal types conditional on failure.
4. **Vault percentage plot**: Characterizes whether total withdrawals exceed the vault capacity, and the relative contributions of endogenous vs exogenous withdrawals.

---

## 9. Theoretical Development

### 9.1 Overview

The paper makes three main contributions:

1. **Critique of Diamond-Dybvig:** By formalizing DD as a stochastic process, the paper shows that the model's insurance payout (not the run mechanism) is the primary driver of its results. Agents are effectively buying an insurance option, an artifact absent from real-world banking.

2. **A Behaviorally-Grounded Decision Rule:** Rather than requiring full utility maximization, agents in the replacement model compare probabilities of recovering their full deposit. This is motivated by the asymmetry of costs: the cost of unnecessary withdrawal (foregone interest) is trivially small relative to the potential loss of the deposit itself.

3. **Network-Mediated Information:** Agents observe only their local network neighborhood and use this as a sample of the broader population. They explicitly model uncertainty about unobserved withdrawals using a Monte Carlo procedure seeded by a Geometric distribution. This generates realistic informational cascades without assuming global information or representative-agent symmetry—features essential for modeling phenomena like the 2023 SVB collapse.

The result is an ABM where bank runs emerge endogenously from rational (but bounded-information) agent behavior on a social network, with calibratable parameters for reserve requirements, deposit insurance design, network topology, and deposit inequality.

### 9.2 The DD Critique — Theorem 0 (Fragility Inflation)

**Setup (follows White 1999):**
- N agents, deposit normalized to 1 each.
- Long-term investment: 1 unit at t=1 → R > 1 at t=3, or r < 1 if liquidated at t=2.
- Early withdrawal contract pays c₁ = 1 + r₁ per unit (r₁ ≥ 0 is the insurance premium).
- Sequential service; fraction f withdraws at t=2.
- Bank liquidates fc₁/r of investment to meet early withdrawals.
- Late withdrawers' payoff: c₂(f) = R(1 − fc₁/r) / (1−f).

**Core argument:** The DD bad equilibrium is driven by c₁ = 1 + r₁ > 1. This makes early withdrawal intrinsically rewarding — agents are exercising a put option, not fleeing a failing bank. This premium is a model artifact: real demand deposits pay at most the principal on early withdrawal.

**Theorem (DD Fragility Inflation).** The good equilibrium (only type-1 agents, fraction λ, withdraw) is locally stable if and only if λ < f\*(c₁), where

$$f^*(c_1) = \frac{r(R - c_1)}{c_1(R - r)}$$

The stability gap between the realistic contract (c₁ = 1, r₁ = 0) and the DD contract (c₁ = 1 + r₁, r₁ > 0) is

$$\Delta f^* = f^*(1) - f^*(1+r_1) = \frac{rR\,r_1}{(1+r_1)(R-r)}$$

with Δf\* > 0 for all r₁ > 0, strictly increasing in r₁, and Δf\* → 0 as r₁ → 0.

**Proof.**

*Step 1: Stability condition.* A marginal type-2 agent prefers to stay iff c₂(λ) > c₁:

$$\frac{R\left(1 - \frac{\lambda c_1}{r}\right)}{1 - \lambda} > c_1$$

Rearranging: R − c₁ > λc₁(R − r)/r, hence λ < r(R − c₁)/(c₁(R − r)) = f\*(c₁). Requires R > c₁.

*Step 2: Monotonicity in c₁.*

$$\frac{df^*}{dc_1} = -\frac{rR}{c_1^2(R-r)} < 0$$

*Step 3: Stability gap.*

$$\Delta f^* = \frac{r}{R-r}\cdot\frac{r_1 R}{1+r_1} = \frac{rR\,r_1}{(1+r_1)(R-r)}$$

**Two key observations:**
1. The bad equilibrium exists under BOTH contracts (when the vault runs out, staying gives zero regardless of c₁). The artifact does not create the bad equilibrium — it artificially shrinks the basin of attraction of the good one.
2. Under c₁ = 1, stability depends only on technology (r, R), not contract design. Under DD, the contract itself introduces fragility proportional to r₁.

---

### 9.3 Lemma 1 — Binary Payoff (Homogeneous Deposits)

**Setup.** N agents each with deposit δ > 0. Vault initialized at Cδ where C = ⌊ρN⌋ ∈ ℤ≥0. Each withdrawal reduces the vault by exactly δ.

**Lemma.** P(partial payment) = 0 exactly. Agent payoffs are Bernoulli: δ with probability p_S, 0 otherwise.

**Proof.** After k withdrawals the vault is V_k = (C − k)δ, so V_k ∈ {0, δ, 2δ, …, Cδ} at every point in time. Agent i's payoff upon withdrawal is min(δ, V_k). Since V_k is always an integer multiple of δ, the event 0 < V_k < δ is empty. Therefore payoffs are in {0, δ}. □

**Corollary.** E[payoff] = p_S · δ, so maximising expected payoff is equivalent to maximising p_S = P(full deposit). This justifies the decision rules in Model 3 (closed-form p_S) and Model 4 (Monte Carlo).

For heterogeneous deposits, the partial payment region has positive probability but the dominance direction is preserved: going earlier weakly reduces both P(partial) and the expected partial amount. The binary payoff approximation holds approximately, with error bounded by δ_i · P(partial).

---

### 9.4 Lemma 2 — Queue Dominance (Any Deposit Distribution)

**Lemma.** For any agent i, any simulation state, and any deposit distribution:

$$E\bigl[\min(\delta_i, \mathcal{V}_{k_0})\bigr] \geq E\bigl[\min(\delta_i, \mathcal{V}_{k_0+m})\bigr] \quad \forall\; m \geq 1$$

where k₀ is the current withdrawal count ("withdraw now") and k₀ + m is the position after m additional withdrawals ("wait").

In particular: P(V_{k₀} ≥ δ_i) ≥ P(V_{k₀+m} ≥ δ_i).

**Proof.** Each withdrawal weakly reduces the vault: V_{k₀} ≥ V_{k₀+m} a.s. The function v ↦ min(δ_i, v) is weakly increasing, so min(δ_i, V_{k₀}) ≥ min(δ_i, V_{k₀+m}) a.s. Taking expectations preserves the inequality. The probability statement follows by applying the argument to the indicator 𝟙(v ≥ δ_i). □

**Corollary (Heterogeneous Deposits).** Lemma 2 holds for any deposit distribution without modification. Partial payment terms E[V · 𝟙(0 < V < δ_i)] need not vanish; they cannot overturn the comparison because Lemma 2 applies to the total payoff.

---

### 9.5 Theorem 1 — Monotone Response (Model 3)

**Setup.**
- Representativeness mapping (m = degree of node i, x = withdrawn neighbours):

$$\tau(x, m, N) = \left\lfloor \frac{Nx}{m} \right\rceil \in \{0, 1, \ldots, N\}, \qquad \tau = 0 \text{ if } m = 0$$

- Survival probability (0 < q < 1, 0 ≤ τ ≤ C < N):

$$p_S(\tau, C, N, q) = \frac{1 - q^{C+1-\tau}}{1 - q^{N-\tau}}, \qquad p_S = 0 \text{ if } \tau > C$$

- Agent i withdraws iff p_S < 1.

**Theorem.** The withdrawal decision is monotone non-decreasing in x: if agent i withdraws given x withdrawn neighbours, they also withdraw given any x' > x.

**Proof.**

*Step 1.* τ(x, m, N) is weakly increasing in x for fixed m, N (nearest-integer rounding preserves order).

*Step 2.* p_S(τ, C, N, q) is weakly decreasing in τ for τ ≤ C. Set a = C + 1 − τ > 0 and b = N − τ > a. Then p_S = (1 − q^a)/(1 − q^b). Incrementing τ by 1 sends a ↦ a − 1 and b ↦ b − 1. Cross-multiplying:

$$(1 - q^{a-1})(1 - q^b) \leq (1 - q^a)(1 - q^{b-1})$$

Expanding and cancelling: q^{a−1}(q − 1) ≤ q^{b−1}(q − 1). Since q − 1 < 0, dividing and reversing: q^{a−1} ≥ q^{b−1}. Since a − 1 < b − 1 and 0 < q < 1, this holds. □

*Conclusion.* More withdrawn neighbours ⟹ weakly higher τ ⟹ weakly lower p_S ⟹ withdrawal triggered weakly sooner.

---

### 9.6 Theorem 2 — Reserve Ratio Monotonicity (Model 3)

**Theorem.** In Model 3, p_S(τ, C, N, q) is strictly increasing in C for τ ≤ C < N − 1, and the expected endogenous withdrawal count is weakly decreasing in ρ.

**Proof.** Incrementing C by 1 sends a = C + 1 − τ ↦ a + 1, leaving b = N − τ unchanged. Then:

$$p_S(C+1) - p_S(C) = \frac{q^a(1 - q)}{1 - q^b} > 0$$

for τ ≤ C < N − 1. Hence p_S is strictly increasing in C. Since C = ⌊ρN⌋ is non-decreasing in ρ, higher ρ ⟹ larger C ⟹ higher p_S for all τ ⟹ fewer agents cross the withdrawal threshold ⟹ weakly smaller cascade. □

**Conjectured corollary.** There exists ρ\* ∈ (0, 1) such that for ρ > ρ\* the expected endogenous cascade size is zero. ρ\* depends on N, p₀, and the exogenous shock distribution. *(To be formalised.)*

---

### 9.7 Theorem 3 — Cascade Fixed Point (Full Network Model)

**Setup.** N agents with deposits {δ_i} on network G = ([N], E). Let S ⊆ [N] be a withdrawal set. For i ∉ S, let x_i(S) = |{j ∈ S : (i,j) ∈ E}| be the number of withdrawn neighbours and m_i = deg(i).

Define the (deterministic) best-response map:

$$\mathcal{B}(S) = S \cup \bigl\{i \notin S : P(\text{full} \mid \text{WD now}, S) > P(\text{full} \mid \text{stay}, S)\bigr\}$$

**Theorem.** The cascade dynamics converge to the unique minimal fixed point S\* ⊇ S₀ (where S₀ is the exogenous withdrawal set) satisfying:

1. ∀ i ∈ S\* \ S₀: P(full | WD now, S\* \ {i}) > P(full | stay, S\* \ {i})
2. ∀ i ∉ S\*: P(full | WD now, S\*) ≤ P(full | stay, S\*)

**Proof.**

*Step 1: Monotonicity of B.* Let S ⊆ S'. For any i ∉ S': more agents have withdrawn under S' than S, so V^{S'} ≤ V^S a.s. By Lemma 2, the gap P(full | WD now, S') − P(full | stay, S') is weakly larger under S' than S. Therefore i ∈ B(S) ⟹ i ∈ B(S'), giving B(S) ⊆ B(S').

*Step 2: Fixed point existence.* (2^{[N]}, ⊆) is a complete lattice. B is monotone (Step 1). By Tarski's fixed point theorem, B has a least fixed point S\*.

*Step 3: Convergence.* Define S₀ ⊆ S₁ ⊆ ⋯ by S_{t+1} = B(S_t). The sequence is non-decreasing and bounded above by [N], so it stabilises in at most N steps at a fixed point. Since S₀ ⊆ S\* and B is monotone, every S_t ⊆ S\*, so the limit is S\*. □

**Corollary (No-Run Condition).** S\* = S₀ iff for all i ∉ S₀: P(full deposit | WD now, S₀) = P(full deposit | stay, S₀) = 1.

**Extension to stochastic best responses (Model 4).** In Model 4, P(full | ·) is estimated via Monte Carlo with depth = 1000. The estimators are unbiased by the law of large numbers. The expected best-response map is monotone, and Tarski applies. The cascade E[|S_t|] is non-decreasing, bounded by N, and converges to E[|S\*|]. □

**Contrast with DD.** The DD bad equilibrium is the *maximal* fixed point of a coordination map, selected by sunspot. S\* here is the *minimal* fixed point, selected by rational network updating. These are structurally opposite solution concepts.

---

### 9.8 Proposition — High-Degree Trigger

**Proposition.** Let |S₀^{hub}| = |S₀^{unif}| = n₀. Suppose S₀^{hub} consists of the n₀ highest-degree nodes and S₀^{unif} is a uniform random sample of n₀ nodes. Then:

$$E\left[|S^*(S_0^{\text{hub}})|\right] \geq E\left[|S^*(S_0^{\text{unif}})|\right]$$

**Proof sketch.**

*Step 1: Degree FSD.* The degree distribution of shocked nodes under S₀^{hub} first-order stochastically dominates that under S₀^{unif}.

*Step 2: Cascade monotonicity in shocked-node degree.* Withdrawing node j raises τ_i by N/m_i for each neighbour i of j, affecting deg(j) agents simultaneously. By Theorem 1, each affected agent i has weakly higher probability of withdrawing. Hence the marginal contribution of node j to E[|S\*|] is weakly increasing in deg(j).

*Step 3: FSD coupling.* By Steps 1 and 2 and the monotonicity of B (Theorem 3), construct a coupling such that each shocked node in S₀^{hub} has degree ≥ the corresponding node in S₀^{unif}. The cascade under S₀^{hub} then dominates sample-path-wise. □

**Note.** Step 3 requires a formal coupling construction; this is the least complete step in the proof.

---

### 9.9 SVB Validation (March 2023)

The 2023 collapse of Silicon Valley Bank directly validates specific model features:

- **Network topology:** The tech startup ecosystem is a Watts-Strogatz small-world — highly clustered locally (VC portfolio companies) with long-range shortcuts (major VCs connected across clusters). The rewiring parameter p captures exactly this structure.

- **Cascade fixed point:** The run did NOT spread to all depositors — it converged to S\*, the minimal rational withdrawal set. Some depositors stayed. The model predicts partial runs, not total collapse.

- **High-degree trigger:** Peter Thiel's Founders Fund was a high-degree node — its withdrawal was simultaneously observed by hundreds of portfolio companies, triggering the cascade. Directly instantiates the High-Degree Trigger Proposition.

- **Principal safety, not option exercise:** No SVB depositor was exercising an insurance option. Everyone was asking: will I get my money back? This is the replacement model's mechanism, not DD's.

- **Depositor homogeneity:** Tech startups with similar risk profiles and information sources approximates the model's assumptions.

---

### 9.10 Paper Narrative Arc

1. DD is the wrong model — models option exercise not principal safety, no network.
2. Replacement model is theoretically grounded — Lemmas 1–2, Theorems 1–3, Proposition 1.
3. SVB confirms the mechanism — high-degree trigger, small-world propagation, convergence to partial run.

---

### 9.11 Outstanding Theoretical Work

- Work through DD artifact theorem algebra formally (f\* calculation under c₁ = 1).
- Formalize the critical ρ\* corollary from Theorem 2.
- Fill in Model Results and Deposit Insurance subsections in draft/draft.tex.
- Fill in Literature Review section in draft/draft.tex.
- Simulation results to accompany theorems (Model 3 sweep already done).
- Proposition on high-degree trigger needs simulation validation.
