################################################################################
# test_public_signal.jl  (added 2026-10-08, branch public-signal)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_public_signal.jl
#
# Three parts:
#   A. The double count in subModelRun (deterministic). With skipWithdrawn=false
#      (the published behaviour) an already-withdrawn neighbour's deposit comes
#      off the submodel's vault a second time; with skipWithdrawn=true it does not.
#   B. Default identity. modelRun from this branch, with every public-signal
#      setting at its default, must reproduce the published modelRun (pinned to
#      commit bc5df60) exactly: same (runState, |S*|, deposits withdrawn) and a
#      byte-identical bankRunEndogenous file, seed for seed.
#   C. Non-default runs: invariants on the announcement (bankRunPublic file),
#      plus diagnostics printed but not asserted (directions are stochastic).
################################################################################

using Test
using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase

const ROOT = abspath(joinpath(@__DIR__, ".."))
const PUBLISHED_COMMIT = "bc5df60"     # last commit before the public-signal change

"""Load objects.jl + a functions4.jl source into a fresh module with its own globals."""
function load_model(name::Symbol, functions_src::AbstractString; depth::Int=30)
    m = Module(name)
    Core.eval(m, :(using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase))
    Base.include(m, joinpath(ROOT, "objects.jl"))
    path = joinpath(mktempdir(), "functions4.jl")
    write(path, functions_src)
    Base.include(m, path)
    dir = mktempdir()
    Core.eval(m, :(dataDir = $dir; workerCore = 1; depth = $depth))
    return m
end

"""A small Model in module m: n agents, Newman–Watts network, Geometric shock."""
function build(m::Module, seed::Int; n::Int=60, reserve::Float64=0.15, λs=nothing)
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, 1.0), n)
    λs = λs === nothing ? [i <= n ÷ 3 ? 0.2 : 0.8 for i in 1:n] : λs
    agents = [m.Agent(i, deposits[i], true, λs[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, 0.1, seed, seed,
                   LogNormal(1.0, 1.0), net, 0.1, truncated(Geometric(0.2), 0, n))
end

endo(m) = (f = joinpath(m.dataDir, "bankRunEndogenous1.csv"); isfile(f) ? read(f, String) : "")
setsw!(m; kw...) = for (k, v) in kw; Core.eval(m, :($k = $v)); end

# ---------------------------------------------------------------- A
@testset "A. subModelRun double count" begin
    m = load_model(:A, read(joinpath(ROOT, "functions4.jl"), String))
    mod = build(m, 1; n=10)
    for a in mod.agtList; a.deposit = 1.0; end
    mod.theBank.vault = 5.0
    out = mod.agtList[1]
    m.withdraw(mod, out)                    # an "exogenous" withdrawal: vault 5 -> 4
    snap = m.clone(mod)                     # cloned after the shock, as modelRun does
    focal = mod.agtList[5]
    for (skip, expected) in ((false, 2.0), (true, 3.0))
        sub = m.clone(snap)
        m.subModelRun(sub, focal, [out], 0; skipWithdrawn=skip)
        # skip=false: 4 - 1 (agent 1 again, the double count) - 1 (focal) = 2
        # skip=true : 4 - 1 (focal) = 3
        @test sub.theBank.vault ≈ expected
    end
end

# ---------------------------------------------------------------- B
@testset "B. defaults reproduce the published modelRun" begin
    old_src = read(`git -C $ROOT show $PUBLISHED_COMMIT:functions4.jl`, String)
    old = load_model(:Old, old_src)
    new = load_model(:New, read(joinpath(ROOT, "functions4.jl"), String))
    for seed in 1:20
        r_old = old.modelRun(build(old, seed))
        r_new = new.modelRun(build(new, seed))
        @test r_old[1] == r_new[1]
        @test r_old[2] == r_new[2]
        @test r_old[3] == r_new[3]
    end
    @test !isempty(endo(old))
    @test endo(old) == endo(new)            # every decision row, byte for byte
    @test !isfile(joinpath(new.dataDir, "bankRunPublic1.csv"))
    @test !isfile(joinpath(new.dataDir, "bankRunPublicParams1.csv"))
end

# ---------------------------------------------------------------- C
@testset "C. non-default runs" begin
    seeds = 1:30
    function arm(; kw...)
        m = load_model(gensym(:C), read(joinpath(ROOT, "functions4.jl"), String))
        setsw!(m; kw...)
        # The module was created inside this function, so call into it in the
        # latest world age (otherwise its methods are "too new").
        res = [Base.invokelatest(() -> m.modelRun(build(m, s))) for s in seeds]
        pubf = joinpath(m.dataDir, "bankRunPublic1.csv")
        pub = isfile(pubf) ? CSV.read(pubf, DataFrame; header=[:key, :tick, :trueWithdrawn, :publicPoint]) : nothing
        return res, pub
    end
    meanN(res) = round(mean(r[2] for r in res), digits=2)
    pRun(res) = round(mean(r[1] for r in res), digits=2)

    res0, _ = arm()
    resC, pubC = arm(PUBLIC_ALPHA=1.0)
    resS, pubS = arm(PUBLIC_ALPHA=1.0, PUBLIC_BIAS=0.5)
    resR, pubR = arm(PUBLIC_ALPHA=1.0, PUBLIC_BIAS=0.5, PUBLIC_RHO=0.5)
    resP, _    = arm(WEIGHT_PHI=0.5)
    resF, _    = arm(FIX_DOUBLE_COUNT=true)
    resK, _    = arm(FRESH_CLONE=true)

    n = 60
    # Accurate announcement: exactly the true count (clamped to N-1).
    @test pubC !== nothing && all(pubC.publicPoint .== min.(pubC.trueWithdrawn, n - 1))
    # Persistent spin: understated by b·N at every tick.
    @test all(pubS.publicPoint .== clamp.(round.(Int, pubS.trueWithdrawn .- 0.5n), 0, n - 1))
    @test all(pubS.publicPoint .<= pubS.trueWithdrawn)
    # Correcting spin: understatement b·ρ^(t-1)·N shrinks with t.
    @test all(pubR.publicPoint .== clamp.(round.(Int, pubR.trueWithdrawn .- 0.5n .* 0.5 .^ (pubR.tick .- 1)), 0, n - 1))
    for res in (res0, resC, resS, resR, resP, resF, resK)
        @test all(0 <= r[2] <= n for r in res)
    end

    println("\nDiagnostics over $(length(seeds)) seeds (not asserted):")
    for (lab, res) in (("default (local only)", res0), ("α=1 accurate common", resC),
                       ("α=1, b=.5 persistent spin", resS), ("α=1, b=.5, ρ=.5 correcting", resR),
                       ("φ=.5 weight decay", resP), ("fix double count", resF),
                       ("fresh clone", resK))
        println(rpad(lab, 30), " P(run)=", pRun(res), "  mean |S*|=", meanN(res))
    end
end
