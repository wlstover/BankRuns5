################################################################################
#  CARA smoke (2026-10-22): the rung-1 reference bank under BANKRUN_WITHDRAW=partial
#  at one BANKRUN_CARA value, at full size (N = 1,000, depth 100), through runRow,
#  so every output file is written as in a sweep. Run one process per CARA value
#  into its own directory; the same REPS banks (network, deposits, θ, shock) in
#  each, so the values pair run for run.
#
#    BANKRUN_CARA=0.1 CARA_SMOKE_OUT=outputs/cara_smoke/g0.1 CARA_SMOKE_REPS=10 \
#      BANKRUN_FRESH_CLONE=true BANKRUN_LOG=summary BANKRUN_BALANCE=firesale ... \
#      julia --project=. scripts/cara_smoke.jl
#
#  (scripts/cara_smoke.sh sets the reference switches and runs the values in
#  parallel.) Cells: μ 0.25 / 0.5 / 0.75 × λ (0.1, 0.9), uninsured, σ 2.5,
#  reserve 0.05, as rung 1. Summary: scripts/cara_smoke.py.
################################################################################

using Distributions, Graphs, Random, LinearAlgebra,
      CSV, DataFrames, StatsBase, Dates, Distributed, Printf

const ROOT = dirname(@__DIR__)
include(joinpath(ROOT, "settings.jl"))
include(joinpath(ROOT, "objects.jl"))
include(joinpath(ROOT, "warmup.jl"))
include(joinpath(ROOT, "functions4.jl"))

for (k, v) in pairs(parseSwitchesFromEnv())
    @eval const $k = $v
end

const REPS    = parse(Int, get(ENV, "CARA_SMOKE_REPS", "10"))
const OUT_DIR = abspath(get(ENV, "CARA_SMOKE_OUT", joinpath(ROOT, "outputs", "cara_smoke", "g$(CARA)")))
if isdir(OUT_DIR) && !isempty(readdir(OUT_DIR))
    error("$OUT_DIR is not empty; move it aside first (the model appends to its CSVs)")
end
mkpath(OUT_DIR)
global dataDir    = OUT_DIR
global workerCore = 1
global depth      = 100

const N, SIGMA, RESERVE, ALPHA = 1000, 2.5, 0.05, 0.1
const MU_VALS = [0.25, 0.5, 0.75]
const LAMBDA  = (0.1, 0.9)

println("CARA smoke: cara=$CARA withdraw=$WITHDRAW reps=$REPS -> $OUT_DIR")
t0 = time()
for rep in 1:REPS, mu in MU_VALS
    Random.seed!(7_000 + rep)
    net = newman_watts_strogatz(N, 6, 0.05)
    row = Dict(:key => "cara_r$(rep)_mu$(mu)", :seed1 => 1000 * rep + 1, :seed2 => 1000 * rep + 2,
               :network => net, :depositDist => LogNormal(1.0, SIGMA), :reserveRatio => RESERVE,
               :depositInsuranceQuantile => 0.0, :withdrawRV => truncated(Geometric(0.1), 0, N),
               :warmupAlpha => ALPHA, :fracIndividualists => mu,
               :lambdaI => LAMBDA[1], :lambdaC => LAMBDA[2])
    runRow(row)
    @printf("  rep %d mu %.2f done (%.1f min)\n", rep, mu, (time() - t0) / 60)
end
@printf("done in %.1f min\n", (time() - t0) / 60)
