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
   - [The Bank](#the-bank)
   - [Model Dynamics: Exogenous Withdrawals](#model-dynamics-exogenous-withdrawals)
   - [Model Dynamics: Endogenous Decision-Making](#model-dynamics-endogenous-decision-making)
   - [Deposit Insurance](#deposit-insurance)
   - [Termination Condition](#termination-condition)
5. [Parameter Sweep Design](#5-parameter-sweep-design)
6. [Distributed Computing Architecture](#6-distributed-computing-architecture)
7. [Data Pipeline](#7-data-pipeline)
8. [Analysis and Results](#8-analysis-and-results)
9. [Theoretical Contribution](#9-theoretical-contribution)

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
│   ├── parameterGen.jl     # Parameter sweep grid construction
│   ├── finMain0001.jl      # Main entry point; distributed execution controller
│   ├── modelStep.jl        # Minimal stub for running one model
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
├── Paper (LaTeX/Sweave)
│   ├── draft.Rnw           # Main paper source (R Sweave / LaTeX)
│   ├── draft.tex           # Compiled LaTeX
│   ├── draft.pdf           # Compiled PDF
│   ├── draft.bbl           # Bibliography (compiled)
│   └── banking.bib         # BibTeX references
│
└── Infrastructure
    ├── run_sweep.sh        # Bash script to execute the full parameter sweep
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
| `Agent` | `idx`, `deposit`, `banked` | Real agent in the main model |
| `simAgent` | `idx`, `deposit`, `banked` | Clone agent used in sub-simulations |
| `Bank` | `vault`, `bankingList`, `withdrawHistory` | Main bank state |
| `simBank` | `vault`, `bankingList`, `withdrawHistory` | Clone bank for sub-simulations |
| `Model` | `key`, `agtList`, `reserveRatio`, `theBank`, `depositInsurance`, `seed1`, `seed2`, `depositDistribution`, `network`, `probThresh`, `exogProb` | Full main model |
| `simModel` | `agtList`, `theBank`, `depositInsurance`, `depositDistribution` | Lightweight clone for sub-simulations |

The dual type hierarchy prevents agents from confusing their sub-simulation clones with the real model state.

---

#### `functions4.jl`
The heart of the simulation. Contains all model logic in ~475 lines.

**`modelGen(...)`**
Initializes a model from parameters. Seeds the RNG (`seed1`), draws deposits from `depositDistribution`, constructs all agents, initializes the bank vault as `reserveRatio × total_deposits`, and writes agent data to CSV.

**`neighborList(mod, agt)`**
Returns the neighbors of `agt` in the model's social network graph.

**`clone(mod::Model)` / `clone(mod::simModel)`**
Deep-copies the model state into a `simModel`. Used extensively before each Monte Carlo sub-simulation to avoid mutating the true model state.

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
   - Infer total expected withdrawals across the population.
   - Run `depth=1000` Monte Carlo trials for both the "withdraw now" and "stay" strategies.
   - If P(get full deposit | withdraw now) > P(get full deposit | stay) **or** P(withdraw) == 0, withdraw.
   - Log the decision to CSV.
   - If the vault hits zero, declare bank failure and return `true`.
4. Repeat until no agent changes their decision (stable state) or failure. Returns `false` if no failure.

**Parallelism helpers: `rowPull`, `checkOff`, `modelCall`**
Implement a shared work queue pattern. `rowPull` (running on process 1, protected by a `ReentrantLock`) atomically grabs the next unstarted parameter row. `modelCall` (running on each worker) pulls a row, runs the full model, and writes results. `checkOff` marks a row complete on the master.

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

The grid is serialized as a `.jld2` file and the parameter metadata written to CSVs. A unique string `key` (timestamp + seed pair) identifies each run for later data joining.

CLI arguments consumed:
```
ARGS[1] = data directory
ARGS[2] = generation seed
ARGS[3] = reserve ratio
ARGS[4] = deposit insurance quantile
ARGS[5] = distribution name ("Pareto" or "LogNormal")
ARGS[6] = distribution param 1 (alpha or mu)
ARGS[7] = distribution param 2 (theta or sigma)  [LogNormal only]
ARGS[8] = Watts-Strogatz k
ARGS[9] = Watts-Strogatz p
```

---

#### `finMain0001.jl`
The main controller script. Responsibilities:

1. Start 16 Julia worker processes (using a precompiled sysimage if available for faster startup).
2. Load all packages on all workers with `@everywhere`.
3. Broadcast CLI arguments to all workers.
4. Set `depth = 1000` (Monte Carlo trials per agent decision) globally on all workers.
5. Include `objects.jl` and `functions4.jl` on all workers.
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

#### `draft.Rnw`
The main academic paper, written in **R Sweave** format (a mix of LaTeX and R chunks). The paper's argument structure:

1. **Introduction** — Bank runs as self-fulfilling prophecies; the role of psychology; the argument for agent-based modeling.
2. **Diamond-Dybvig and literature review** — Summary of DD (1983) and the main follow-on literature (Postlewaite & Vives 1987; Shell & Zhang 2019; Kinateder & Kiss 2014; Green & Lin 2000; Smith & Shubik 2014; Peck & Shell 2003; etc.).
3. **A Stochastic Process Version of DD** — Formal probabilistic restatement of Diamond-Dybvig; shows that agents are choosing a deposit level to maximize expected utility over a distribution over outcomes. Shows `P(failure) = ψ(p, ι, π)` where p is the exogenous withdrawal probability, ι is the insurance payout, and π is the investment return. **Key criticism:** in the DD framework agents are *buying an option*, and the behavior is driven by the insurance payout—an artifact absent from real banking.
4. **Bank Runs Revisited** — Motivates the ABM replacement. Key argument: the opportunity cost of unnecessary withdrawal is merely foregone interest (small relative to total deposits), so agents need not use full Von-Neumann-Morgenstern utility; a simple withdrawal-probability threshold suffices.
5. **A Simple Replacement Model** — Describes the ABM (1000 agents, LogNormal deposits, Watts-Strogatz network, truncated geometric exogenous withdrawals, Monte Carlo decision-making).
6. **Conclusion** — (Placeholder).

---

#### `banking.bib`
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

This yields **2 × 4 × 2 × 3 × 2 = 96 jobs**, each launching a full Julia process with 16 worker cores. Each job runs `finMain0001.jl` with a unique generation seed (starting at 1001, incrementing per job). Within each job, the parameter grid produces 5 seed repeats × 10 iterations = **50 simulation runs per job**, for a total of **4,800 model runs**.

---

#### `BankRuns5.Rproj`
Standard RStudio project configuration file. Sets the working directory and basic project metadata.

---

## 4. Model Description

### Agents and Network

The model contains **1,000 agents** (hardcoded in `finMain0001.jl`). Each agent has:
- A **deposit** drawn from a LogNormal or Pareto distribution.
- A **`banked` flag** (initially `true`).

Agents are connected in a **Newman–Watts–Strogatz small-world network** with parameters `k` (baseline degree) and `p` (rewiring probability). This network represents the information network: an agent only observes whether its direct neighbors are banking or have withdrawn.

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
   b. **Infer population state:** Scale to estimate total withdrawals population-wide as `propWithdrawn × N`.
   c. **Sample future withdrawals:** Draw `depth = 1000` samples from a truncated Geometric, conditioned on being ≥ the observed count. These represent uncertain future withdrawals.
   d. **Monte Carlo: "withdraw now" strategy:** For each of the 1,000 samples, clone the current model state and simulate the focal agent withdrawing immediately. Record whether the payout equals the full deposit.
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
| `seed1` | Deposit draw randomness | 5 random seeds |
| `iteration` | Run replication | 10 per seed |

**Fixed parameters:**
- Agent count: 1,000
- Deposit distribution: LogNormal(μ=1.0, σ=varied)
- Exogenous withdrawal distribution: truncated Geometric(p=0.1)
- Monte Carlo depth: 1,000 trials per agent decision
- Decision threshold: implied by the comparison of withdrawal vs. stay probabilities

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
    └── finMain0001.jl (×96 jobs)
            ├── parameterGen.jl → bankRunParametersInit.csv
            │                     bankRunlogNormal.csv
            │                     bankRunGeometric.csv
            │                     key*.jld2
            └── modelCall() × N_runs
                    ├── agents{core}.csv          (agent deposits per run)
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

## 9. Theoretical Contribution

The paper makes three main contributions:

1. **Critique of Diamond-Dybvig:** By formalizing DD as a stochastic process, the paper shows that the model's insurance payout (not the run mechanism) is the primary driver of its results. Agents are effectively buying an insurance option, an artifact absent from real-world banking.

2. **A Behaviorally-Grounded Decision Rule:** Rather than requiring full utility maximization, agents in the replacement model compare probabilities of recovering their full deposit. This is motivated by the asymmetry of costs: the cost of unnecessary withdrawal (foregone interest) is trivially small relative to the potential loss of the deposit itself.

3. **Network-Mediated Information:** Agents observe only their local network neighborhood and use this as a sample of the broader population. They explicitly model uncertainty about unobserved withdrawals using a Monte Carlo procedure seeded by a Geometric distribution. This generates realistic informational cascades without assuming global information or representative-agent symmetry—features essential for modeling phenomena like the 2023 SVB collapse.

The result is an ABM where bank runs emerge endogenously from rational (but bounded-information) agent behavior on a social network, with calibratable parameters for reserve requirements, deposit insurance design, network topology, and deposit inequality.
