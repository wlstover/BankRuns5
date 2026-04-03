# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Academic paper: *"A Bank Run Model for the Twentieth Century"* by John S. Schuler (George Mason, Dept. Computational & Data Sciences). The project critiques Diamond-Dybvig (1983) and replaces it with an agent-based model (ABM). Languages: Julia (simulation), R (analysis), LaTeX/Sweave (paper via `draft.Rnw`).

## Running the Simulation

**Full parameter sweep (96 jobs, ~4800 total runs):**
```bash
# Edit DATA_DIR, JULIA_BIN, PROJECT_DIR at top of script first
bash run_sweep.sh
```

**Single job manually:**
```bash
julia --project=. finMain0001.jl <DATA_DIR> <GEN_SEED> <reserveRatio> <depQuantile> LogNormal <mu> <sigma> <ws_k> <ws_p>
# Example:
julia --project=. finMain0001.jl /path/to/data 1001 0.2 0.1 LogNormal 1.0 2.0 6 0.05
```

**Resume interrupted sweep:**
Uncomment `include("restart.jl")` in `finMain0001.jl` (and comment out `include("parameterGen.jl")`). `restart.jl` reloads JLD2 state files, prunes orphaned partial CSV outputs, and reconstructs `jointFrame` with completed flags set.

**Build sysimage (faster startup, optional):**
```bash
julia --project=. sysImage.jl
# Produces sysimage.so; finMain0001.jl auto-detects and uses it
```

## Architecture

### Dual struct hierarchy
`objects.jl` defines two parallel struct families — **main** (`Agent`, `Bank`, `Model`) and **Monte Carlo sub-simulation** (`simAgent`, `simBank`, `simModel`). They are structurally identical but never share a type, preventing accidental mutation of the real model during agent decision-making.

### Model lifecycle (per run)
1. **`parameterGen.jl`** — reads CLI args, builds a cross-joined `jointFrame` DataFrame (parameter grid), saves it as a JLD2 file, writes init CSVs to `DATA_DIR`.
2. **`finMain0001.jl`** — spawns 16 distributed workers, broadcasts `jointFrame` and `depth=1000`, then loops: pulls unstarted rows via locked `rowPull()`, dispatches `modelCall()` to free workers via `@spawnat`.
3. **`modelGen()`** — initializes one `Model`: draws LogNormal deposits, constructs Watts-Strogatz network, sets bank vault = `reserveRatio × sum(deposits)`.
4. **`modelRun()`** — two-phase execution:
   - *Phase 1 (exogenous):* draws from `truncated(Geometric(0.1), 0, 1000)`, randomly selects that many agents to withdraw unconditionally.
   - *Phase 2 (endogenous):* each remaining agent observes its neighbor withdrawal fraction, infers population-level withdrawal count, runs `depth=1000` Monte Carlo trials via `subModelRun()` comparing P(full deposit | withdraw now) vs P(full deposit | stay), withdraws if the former is higher. Repeats until no agent changes state or vault ≤ 0.
5. **`modelCall()`** — worker entry point; calls `modelGen` + `modelRun`, writes result (binary failure flag) to `bankRunResults{core}.csv`, marks row complete via `checkOff()`.

### Distributed coordination
- Process 1 (master) owns `jointFrame`; workers call `@spawnat 1 rowPull()` to get a row atomically (guarded by `rowLock`).
- Worker identity is stored in per-worker global `workerCore` (set by `myCore(c)`); CSV output files are per-worker to avoid write contention: `agents{core}.csv`, `bankRunExogenous{core}.csv`, `bankRunEndogenous{core}.csv`, `bankRunResults{core}.csv`.

### Output files (written to DATA_DIR)
| File | Content |
|---|---|
| `bankRunParametersInit.csv` | Parameter grid (appended each job) |
| `bankRunlogNormal.csv` | LogNormal params per run |
| `bankRunGeometric.csv` | Geometric params per run |
| `agents{core}.csv` | Agent deposits per run |
| `bankRunExogenous{core}.csv` | Exogenous withdrawal events |
| `bankRunEndogenous{core}.csv` | Endogenous withdrawal decisions (with wdProb/stayProb) |
| `bankRunResults{core}.csv` | Binary failure result per run |
| `key{seed}{timestamp}.jld2` | Full `jointFrame` state for restart |
| `bankRunParametersFin.csv` | Final started/completed flags |

### Analysis
`analysis2.R` and `workingAnalysis.R` are the primary R analysis scripts. `draft.Rnw` is the paper (R Sweave + LaTeX); compile with `R CMD Sweave draft.Rnw && pdflatex draft.tex`. `finAnalysis.R` belongs to a different (antitrust) project — ignore it.

## Parameter Space
- `reserveRatio`: 0.2, 0.4
- `depositInsuranceQuantile`: 0.1, 0.2, 0.3, 0.4 (quantile of LogNormal CDF used as deposit insurance cap)
- LogNormal: mu=1.0 fixed; sigma: 2.0, 3.0
- Watts-Strogatz: k ∈ {6, 10, 50}; p ∈ {0.05, 0.15}
- 5 seeds × 10 iterations per job = 50 runs per job; 96 jobs total
