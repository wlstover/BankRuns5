################################################################################
# test_deposit_cap.jl  (added 2026-10-23)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_deposit_cap.jl
#
# The deposit cap (BANKRUN_DEPOSIT_CAP = c; the user, 2026-10-23):
#   A. capDeposits on log-normal(1, 2.5) draws: no deposit above c of the capped
#      total; the capped deposits share one level L; every deposit below L is
#      unchanged; capping again changes nothing; no-op when nobody exceeds c.
#   B. Infeasible caps (c <= 1/n) and the switch's range are refused.
#   C. modelGenTyped: with the cap, the same draws (λ, types) and deposits as
#      without it below L, and the bank built on the capped total.
################################################################################

using Test
using CSV, DataFrames, Distributions, Distributed, Graphs, LinearAlgebra, Random, StatsBase

const ROOT = abspath(joinpath(@__DIR__, ".."))

function load_model(name::Symbol)
    m = Module(name)
    Core.eval(m, :(using CSV, DataFrames, Distributions, Distributed, Graphs, LinearAlgebra, Random, StatsBase))
    for f in ("settings.jl", "objects.jl", "warmup.jl", "functions4.jl")
        Base.include(m, joinpath(ROOT, f))
    end
    dir = mktempdir()
    Core.eval(m, :(dataDir = $dir; workerCore = 1; depth = 30; LOG = "summary"))
    return m
end
setsw!(m; kw...) = for (k, v) in kw; Core.eval(m, :($k = $v)); end

# ---------------------------------------------------------------- A
@testset "A. capDeposits" begin
    m = load_model(:A)
    cap(d, c) = Base.invokelatest(m.capDeposits, d, c)
    rng = MersenneTwister(7)
    nCapped = Int[]
    for rep in 1:500, c in (0.01, 0.02, 0.05)
        d = rand(rng, LogNormal(1.0, 2.5), 1000)
        out = cap(d, c)
        L = maximum(out)
        @test L <= c * sum(out) * (1 + 1e-12)
        hit = d .> L
        if any(hit)
            @test L ≈ c * sum(out)                      # the cap binds exactly
            @test all(out[hit] .== L)
        end
        @test out[.!hit] == d[.!hit]                     # below L, untouched
        @test cap(out, c) == out                         # idempotent
        c == 0.01 && push!(nCapped, count(hit))
    end
    @test median(nCapped) > 10                          # σ 2.5 at N 1,000: tens of agents at 1%
    d = rand(rng, LogNormal(1.0, 0.5), 1000)            # nobody near 5%
    @test cap(d, 0.05) === d
end

# ---------------------------------------------------------------- B
@testset "B. refused" begin
    m = load_model(:B)
    @test_throws ErrorException Base.invokelatest(m.capDeposits, rand(100), 0.01)   # c·n = 1
    withenv("BANKRUN_DEPOSIT_CAP" => "1.5") do
        @test_throws ErrorException Base.invokelatest(m.parseSwitchesFromEnv)
    end
end

# ---------------------------------------------------------------- C
@testset "C. modelGenTyped with the cap" begin
    gen(m) = Base.invokelatest(m.modelGenTyped, "k1", 11, 12, 300, 0.1,
                               newman_watts_strogatz(300, 6, 0.05; seed=3), LogNormal(1.0, 2.5),
                               0.05, 0.0, truncated(Geometric(0.2), 0, 300), 0.1, 0.5, 0.1, 0.9)
    m0 = load_model(:C0); setsw!(m0; BALANCE="firesale")
    m1 = load_model(:C1); setsw!(m1; BALANCE="firesale", DEPOSIT_CAP=0.02)
    (a, isI0), (b, isI1) = gen(m0), gen(m1)
    d0 = [x.deposit for x in a.agtList]; d1 = [x.deposit for x in b.agtList]
    L = maximum(d1)
    @test isI0 == isI1
    @test [x.individualism for x in a.agtList] == [x.individualism for x in b.agtList]
    @test any(d0 .> L) && d1[d0 .<= L] == d0[d0 .<= L]
    @test L ≈ 0.02 * sum(d1)
    @test b.theBank.vault ≈ 0.05 * sum(d1)
    @test b.theBank.illiquid ≈ (1.0 - 0.05 + 0.10) * sum(d1)    # EQUITY default 0.10
end
