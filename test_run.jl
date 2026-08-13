################################################################################
#  Small-scale sanity-check sweep
#  Run with: julia --project=. test_run.jl
#
#  Sweeps μ × (λ_I, λ_C) over REP replications each.
#  Prints a summary table of bank-run probabilities and writes results.csv.
#
#  Key checks:
#   1. Higher λ gap (λ_C − λ_I) → stronger non-monotonicity in μ
#   2. μ = 0 (all collectivist) vs μ = 1 (all individualist) set the floor/ceiling
#   3. Within-type λ draws are continuous (warmupLambda vs individualism in CSV)
################################################################################

using Distributions, Graphs, Random, LinearAlgebra,
      CSV, DataFrames, StatsBase, Dates, Distributed, Printf

include("objects.jl")
include("warmup.jl")
include("functions4.jl")

# ── Test parameters ──────────────────────────────────────────────────────────
const N_AGENTS  = 200       # agents per run  (original: 1000)
const DEPTH_MC  = 50        # Monte Carlo trials per decision
                            # (sweep default 100 since 2026-08-13; model's original 1000)
const REPS      = 20        # seeds per (μ, λ_I, λ_C) cell
const WARMUP_A  = 0.3       # fixed warm-up α for this test
const RESERVE   = 0.2
const DEP_QUANT = 0.1
const DEP_SIGMA = 0.5       # LogNormal σ — moderate tails
const EXOG_P    = 0.2       # Geometric(0.2) → mean ≈ 4 exog withdrawals
const WS_K      = 6
const WS_P      = 0.05

const MU_VALS      = [0.0, 0.25, 0.5, 0.75, 1.0]
const LAMBDA_PAIRS = [          # (λ_I, λ_C) — λ_I < λ_C throughout
    (0.1, 0.9),                 # wide gap
    (0.2, 0.8),                 # medium gap
    (0.3, 0.5),                 # narrow gap
]

# ── Infrastructure stubs ──────────────────────────────────────────────────────
const OUT_DIR = joinpath(@__DIR__, "outputs", "test_run")
mkpath(OUT_DIR)
global dataDir    = OUT_DIR
global workerCore = 1
global depth      = DEPTH_MC

# ── Sweep (wrapped in a function to avoid Julia soft-scope issues) ────────────
function run_sweep()
    network  = newman_watts_strogatz(N_AGENTS, WS_K, WS_P)
    depDist  = LogNormal(1.0, DEP_SIGMA)
    exogDist = truncated(Geometric(EXOG_P), 0, N_AGENTS)

    results = DataFrame(
        mu          = Float64[],
        lambdaI     = Float64[],
        lambdaC     = Float64[],
        lambdaGap   = Float64[],
        seed        = Int[],
        bankRun     = Bool[],
        meanLambdaI = Float64[],   # realised E[λ | type I] — checks Beta centering
        meanLambdaC = Float64[],
        fracI       = Float64[],   # realised fraction of type-I agents
    )

    total  = length(MU_VALS) * length(LAMBDA_PAIRS) * REPS
    n_done = 0

    for (lI, lC) in LAMBDA_PAIRS, mu in MU_VALS
        midpoint = (lI + lC) / 2
        for rep in 1:REPS
            seed1 = 1000 * rep + 1
            seed2 = 1000 * rep + 2
            key   = "test_mu$(mu)_lI$(lI)_lC$(lC)_r$(rep)"

            mod = modelGen(key, seed1, seed2, N_AGENTS, 0.1,
                           network, depDist, RESERVE, DEP_QUANT, exogDist,
                           WARMUP_A, mu, lI, lC)

            lams_I = [a.individualism for a in mod.agtList if a.individualism < midpoint]
            lams_C = [a.individualism for a in mod.agtList if a.individualism >= midpoint]

            result = modelRun(mod)

            push!(results, (
                mu, lI, lC, lC - lI, seed1, result,
                isempty(lams_I) ? NaN : mean(lams_I),
                isempty(lams_C) ? NaN : mean(lams_C),
                count(a.individualism < midpoint for a in mod.agtList) / N_AGENTS,
            ))

            n_done += 1
            n_done % 10 == 0 && print("\r  $n_done/$total runs complete")
        end
    end
    println("\r  $total/$total runs complete  \n")
    return results
end

println("Starting test sweep: $(length(MU_VALS)) μ values × $(length(LAMBDA_PAIRS)) λ pairs × $REPS reps")
println("N=$N_AGENTS  depth=$DEPTH_MC  warmupAlpha=$WARMUP_A\n")

results = run_sweep()
CSV.write(joinpath(OUT_DIR, "test_results.csv"), results)

# ── Summary table ─────────────────────────────────────────────────────────────
println("="^72)
println("Bank-run probability by (μ, λ_I, λ_C)  [N=$N_AGENTS, depth=$DEPTH_MC, reps=$REPS]")
println("="^72)

for (lI, lC) in LAMBDA_PAIRS
    println("  λ_I=$lI  λ_C=$lC  (gap=$(lC-lI))")
    for mu in MU_VALS
        sub = filter(r -> r.mu == mu && r.lambdaI == lI && r.lambdaC == lC, results)
        p   = mean(sub.bankRun)
        bar = repeat("█", round(Int, p * 30))
        @printf("    μ=%-5.2f  P(run)=%.3f  %s\n", mu, p, bar)
    end
    println()
end

println("="^72)
println("Beta-draw diagnostics (realised E[λ | type] vs target)")
println("-"^72)
@printf("  %-6s  %-6s  %-16s  %-16s  %s\n",
        "λ_I", "λ_C", "E[λ|I] realised", "E[λ|C] realised", "frac-I realised")
for (lI, lC) in LAMBDA_PAIRS
    sub = filter(r -> r.lambdaI == lI && r.lambdaC == lC, results)
    mi  = round(mean(filter(!isnan, sub.meanLambdaI)), digits=3)
    mc  = round(mean(filter(!isnan, sub.meanLambdaC)), digits=3)
    fi  = round(mean(sub.fracI), digits=3)
    @printf("  %-6s  %-6s  %-16s  %-16s  %s\n", lI, lC, mi, mc, fi)
end
println()
println("Results written to: $(joinpath(OUT_DIR, "test_results.csv"))")
