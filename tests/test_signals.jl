################################################################################
# test_signals.jl  (added 2026-10-20)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_signals.jl
#
# The Chapter 1 signal switches and the insured columns:
#   A. BANKRUN_PRIVATE_SIGNAL = shock. With small noise every agent's posterior
#      draws sit at the realised shock; with very large noise they follow the
#      prior. The arm draws exactly the main-stream random numbers of the
#      uninformative arm (pairing), which the default identity of
#      test_switch_identity.jl does not cover.
#   B. BANKRUN_PUBLIC_MODE = stale. The announced level is the true count at
#      tick 1 (refresh 0) or at its last refresh (refresh k); bias still subtracts.
#   C. typeSummary's insured columns against a direct count.
# The defaults of all three are covered by test_switch_identity.jl (byte-
# identical to 420ecc0) and test_public_signal.jl B.
################################################################################

using Test
using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase

const ROOT = abspath(joinpath(@__DIR__, ".."))

function load_model(name::Symbol; depth::Int=30)
    m = Module(name)
    Core.eval(m, :(using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase))
    for f in ("settings.jl", "objects.jl", "functions4.jl")
        Base.include(m, joinpath(ROOT, f))
    end
    dir = mktempdir()
    Core.eval(m, :(dataDir = $dir; workerCore = 1; depth = $depth))
    return m
end
setsw!(m; kw...) = for (k, v) in kw; Core.eval(m, :($k = $v)); end

function build(m::Module, seed::Int; n::Int=60, reserve::Float64=0.15, ins::Float64=0.1)
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, 1.0), n)
    λs = [i <= n ÷ 3 ? 0.2 : 0.8 for i in 1:n]
    agents = [m.Agent(i, deposits[i], true, λs[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, ins, seed, seed,
                   LogNormal(1.0, 1.0), net, 0.1, truncated(Geometric(0.2), 0, n))
end
readlog(m, f, cols) = (p = joinpath(m.dataDir, f); isfile(p) ? CSV.read(p, DataFrame; header=cols) : nothing)

# ---------------------------------------------------------------- A
@testset "A. informative private signal" begin
    m = load_model(:A)
    mod = build(m, 3)
    nExog = 7
    tight = m.privatePosteriors(mod, nExog, 0.05; belief="geometric", p0=0.02)
    draws = reduce(vcat, [m.privateDraws(tight, a, 200) for a in mod.agtList])
    @test all(draws .== nExog)                         # s → 0: the realised shock exactly
    wide = m.privatePosteriors(mod, nExog, 1.0e5; belief="geometric", p0=0.02)
    d = reduce(vcat, [m.privateDraws(wide, a, 500) for a in mod.agtList])
    priorMean = mean(rand(MersenneTwister(1), mod.exogProb, 50_000))
    @test abs(mean(d) - priorMean) < 0.1 * priorMean   # s → ∞: the prior
    mid = m.privatePosteriors(mod, 30, 3.0; belief="geometric", p0=0.02)
    dm = reduce(vcat, [m.privateDraws(mid, a, 200) for a in mod.agtList])
    @test 20 < mean(dm) < 31                           # pulled toward the signal, shrunk by the prior
    # Same seed, same signals: the posterior has its own reproducible stream.
    again = m.privatePosteriors(mod, nExog, 3.0; belief="geometric", p0=0.02)
    @test again.signal == m.privatePosteriors(mod, nExog, 3.0; belief="geometric", p0=0.02).signal
    # Point prior: the posterior lives on 0..N-1.
    pt = m.privatePosteriors(mod, nExog, 2.0; belief="point", p0=0.02)
    dp = reduce(vcat, [m.privateDraws(pt, a, 100) for a in mod.agtList])
    @test all(0 .<= dp .<= length(mod.agtList) - 1)

    # Pairing: with noise so small that the posterior is a point mass, and every
    # agent's weight on the social signal at 1 (λ = 1: the private draws carry no
    # weight), the shock arm must reproduce the none arm decision for decision.
    function run(sig)
        mm = load_model(gensym(:P))
        setsw!(mm; PRIVATE_SIGNAL=sig, PRIVATE_NOISE=0.05)
        res = Base.invokelatest() do
            [begin
                 md = build(mm, s)
                 for a in md.agtList; a.individualism = 1.0; end
                 mm.modelRun(md)
             end for s in 1:10]
        end
        e = joinpath(mm.dataDir, "bankRunEndogenous1.csv")
        return res, read(e, String), mm
    end
    rN, eN, _ = run("none")
    rS, eS, mS = run("shock")
    @test rN == rS
    @test eN == eS
    pp = readlog(mS, "bankRunPrivateParams1.csv", [:key, :privateSignal, :privateNoise, :nExog])
    @test pp !== nothing && nrow(pp) == 10 && all(pp.privateSignal .== "shock")
    @test isfile(joinpath(mS.dataDir, "bankRunPrivate1.csv"))
    # λ < 1 and an informative signal does change decisions somewhere.
    function runλ(sig)
        mm = load_model(gensym(:Q))
        setsw!(mm; PRIVATE_SIGNAL=sig, PRIVATE_NOISE=1.0)
        Base.invokelatest(() -> [mm.modelRun(build(mm, s)) for s in 1:20])
    end
    @test runλ("none") != runλ("shock")
end

# ---------------------------------------------------------------- B
@testset "B. stale public level" begin
    cols = [:key, :tick, :trueWithdrawn, :publicPoint]
    function arm(; kw...)
        mm = load_model(gensym(:S))
        setsw!(mm; PUBLIC_ALPHA=1.0, kw...)
        Base.invokelatest(() -> [mm.modelRun(build(mm, s; reserve=0.25)) for s in 1:20])
        return readlog(mm, "bankRunPublic1.csv", cols), mm
    end
    never, mN = arm(PUBLIC_MODE="stale", PUBLIC_REFRESH=0)
    for g in groupby(never, :key)
        @test all(g.publicPoint .== g.publicPoint[1])          # frozen at tick 1
        @test g.publicPoint[1] == min(g.trueWithdrawn[1], 59)
        @test all(g.publicPoint .<= g.trueWithdrawn)           # it can only fall behind
    end
    @test any(nrow(g) > 1 && g.trueWithdrawn[end] > g.publicPoint[end] for g in groupby(never, :key))
    mp = readlog(mN, "bankRunPublicMode1.csv", [:key, :publicMode, :publicRefresh])
    @test mp !== nothing && all(mp.publicMode .== "stale")

    every2, _ = arm(PUBLIC_MODE="stale", PUBLIC_REFRESH=2)
    for g in groupby(every2, :key)
        for r in eachrow(g)
            refreshTick = r.tick == 1 ? 1 : (isodd(r.tick) ? r.tick : r.tick - 1)
            @test r.publicPoint == min(g.trueWithdrawn[g.tick .== refreshTick][1], 59)
        end
    end
    spin, _ = arm(PUBLIC_MODE="stale", PUBLIC_REFRESH=0, PUBLIC_BIAS=0.1)
    for g in groupby(spin, :key)
        @test all(g.publicPoint .== clamp(round(Int, g.trueWithdrawn[1] - 6), 0, 59))
    end
    markup, _ = arm()                                          # PUBLIC_MODE default: accurate
    @test all(markup.publicPoint .== min.(markup.trueWithdrawn, 59))
end

# ---------------------------------------------------------------- C
@testset "C. insured columns" begin
    m = load_model(:C)
    for (ins, seed) in ((0.1, 1), (0.5, 2), (0.0, 3))
        mod = build(m, seed; ins=ins)
        isI = [a.individualism < 0.5 for a in mod.agtList]
        rec = m.RunRecord()
        m.modelRun(mod; record=rec)
        rows = m.typeSummary(mod, isI, rec)
        cap = quantile(mod.depositDistribution, ins)
        d = [a.deposit for a in mod.agtList]
        @test m.insuranceCap(mod) == cap
        @test sum(rows.nInsured) == count(d .<= cap)
        @test sum(rows.depUninsured) ≈ sum(d[d .> cap])
        endog = Set(rec.order[rec.nExog+1:end])
        @test sum(rows.nEndogInsured) == count(i -> d[i] <= cap && i in endog, 1:length(d))
        stay = [a.banked for a in mod.agtList]
        @test sum(rows.depStayersUninsured) ≈ sum(d[stay .& (d .> cap)])
        @test sum(rows.nStayersUninsured) == count(stay .& (d .> cap))
    end
    mod = build(m, 4; ins=1.5)                                 # adaptive scheme
    @test isnan(m.insuranceCap(mod))
end
