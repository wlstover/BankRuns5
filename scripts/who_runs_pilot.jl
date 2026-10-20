################################################################################
#  Who-runs pilot (2026-10-13): agent-level output for a small local sweep.
#  Run with: julia --project=. scripts/who_runs_pilot.jl
#
#  Same design as test_run.jl (N = 200, depth 50, μ × (λ_I, λ_C) × REPS seeds),
#  but every run gets a unique key and the sweep writes into a fresh directory,
#  so agents1.csv / bankRunEndogenous1.csv / bankRunExogenous1.csv can be joined
#  run by run. (test_run/ was appended to by ~6 invocations under the same keys.)
#  Analysis: scripts/who_runs_pilot.py.
#
#  Model settings: the BANKRUN_* switches are read from ENV exactly as
#  finMain0001.jl reads them (defaults in settings.jl = the published model).
#  WHO_RUNS_TAG names the output directory, outputs/who_runs_pilot_<tag>
#  (default: outputs/who_runs_pilot). REPS: WHO_RUNS_REPS (default 20).
#    WHO_RUNS_TAG=fixes BANKRUN_FRESH_CLONE=true WHO_RUNS_REPS=40 \
#        julia --project=. scripts/who_runs_pilot.jl
################################################################################

using Distributions, Graphs, Random, LinearAlgebra,
      CSV, DataFrames, StatsBase, Dates, Distributed, Printf

const ROOT = dirname(@__DIR__)
include(joinpath(ROOT, "settings.jl"))
include(joinpath(ROOT, "objects.jl"))
include(joinpath(ROOT, "warmup.jl"))
include(joinpath(ROOT, "functions4.jl"))

const N_AGENTS  = 200
const DEPTH_MC  = 50
const REPS      = parse(Int, get(ENV, "WHO_RUNS_REPS", "20"))
const WARMUP_A  = 0.3
const RESERVE   = 0.2
const DEP_QUANT = 0.1
const DEP_SIGMA = 0.5
const EXOG_P    = 0.2
const WS_K      = 6
const WS_P      = 0.05

const MU_VALS      = [0.0, 0.25, 0.5, 0.75, 1.0]
const LAMBDA_PAIRS = [(0.1, 0.9), (0.2, 0.8), (0.3, 0.5)]

# Switches, parsed as in finMain0001.jl (settings.jl parseSwitchesFromEnv).
for (k, v) in pairs(parseSwitchesFromEnv())
    @eval const $k = $v
end

const TAG = strip(get(ENV, "WHO_RUNS_TAG", ""))
const OUT_DIR = joinpath(ROOT, "outputs", isempty(TAG) ? "who_runs_pilot" : "who_runs_pilot_$TAG")
if isdir(OUT_DIR) && !isempty(readdir(OUT_DIR))
    error("$OUT_DIR is not empty; move it aside first (the model appends to its CSVs)")
end
mkpath(OUT_DIR)
global dataDir    = OUT_DIR
global workerCore = 1
global depth      = DEPTH_MC

function run_sweep()
    # Seeded (2026-10-20): unseeded, every invocation drew its own network (and so
    # its own warm-up types), and arms run separately were not paired.
    Random.seed!(parse(Int, get(ENV, "WHO_RUNS_NETSEED", "20261020")))
    network  = newman_watts_strogatz(N_AGENTS, WS_K, WS_P)
    depDist  = LogNormal(1.0, DEP_SIGMA)
    exogDist = truncated(Geometric(EXOG_P), 0, N_AGENTS)
    results = DataFrame(key=String[], mu=Float64[], lambdaI=Float64[], lambdaC=Float64[],
                        rep=Int[], seed1=Int[], bankRun=Bool[], nWithdrawn=Int[],
                        depositWithdrawn=Float64[], vaultInit=Float64[], insuranceCap=Float64[])
    total, n_done = length(MU_VALS) * length(LAMBDA_PAIRS) * REPS, 0
    for (lI, lC) in LAMBDA_PAIRS, mu in MU_VALS, rep in 1:REPS
        seed1, seed2 = 1000 * rep + 1, 1000 * rep + 2
        key = "who_mu$(mu)_lI$(lI)_lC$(lC)_r$(rep)"
        mod = modelGen(key, seed1, seed2, N_AGENTS, 0.1, network, depDist, RESERVE,
                       DEP_QUANT, exogDist, WARMUP_A, mu, lI, lC)
        vault0 = mod.theBank.vault
        runState, n, d = modelRun(mod)
        push!(results, (key, mu, lI, lC, rep, seed1, runState, n, d, vault0,
                        quantile(depDist, DEP_QUANT)))
        n_done += 1
        n_done % 10 == 0 && print("\r  $n_done/$total runs complete")
    end
    println("\r  $total/$total runs complete")
    return results
end

println("Who-runs pilot: N=$N_AGENTS depth=$DEPTH_MC reps=$REPS -> $OUT_DIR")
println("switches: alpha=$PUBLIC_ALPHA bias=$PUBLIC_BIAS rho=$PUBLIC_RHO phi=$WEIGHT_PHI ",
        "fixDoubleCount=$FIX_DOUBLE_COUNT freshClone=$FRESH_CLONE tiebreak=$TIEBREAK belief=$BELIEF p0=$BELIEF_P0 log=$LOG")
t0 = time()
CSV.write(joinpath(OUT_DIR, "results.csv"), run_sweep())
@printf("done in %.1f min\n", (time() - t0) / 60)
