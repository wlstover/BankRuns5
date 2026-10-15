# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_switch_identity.jl
#
# Every pre-existing switch arm reproduces the reference commit byte for byte.
#
# test_public_signal.jl part B checks only the DEFAULT arm against the published
# model. This test checks every arm of the switches that existed at REFERENCE
# (public signal α/b/ρ, weight decay φ, double-count fix, fresh clone, and a
# combination) under three bank configurations (adaptive insurance included):
# result tuples and every output file must match. It guards refactors of
# functions4.jl, and it fails if a switch added later changes behaviour at its
# default. Added 2026-10-15 for the schuler-sync cleanup.

using Test
using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase

const ROOT = abspath(joinpath(@__DIR__, ".."))
const REFERENCE = "420ecc0"     # public-signal Level 1, before the 2026-10-15 cleanup

gitshow(f) = read(`git -C $ROOT show $REFERENCE:$f`, String)

"""Load source files, in order, into a fresh module with its own globals."""
function load(name, files::Vector{Pair{String,String}}; depth=30)
    m = Module(name)
    Core.eval(m, :(using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase))
    d = mktempdir()
    for (fn, src) in files
        p = joinpath(d, fn); write(p, src); Base.include(m, p)
    end
    out = mktempdir()
    Core.eval(m, :(dataDir = $out; workerCore = 1; depth = $depth))
    return m
end
reference_files() = ["objects.jl" => gitshow("objects.jl"), "functions4.jl" => gitshow("functions4.jl")]
current_files() = [f => read(joinpath(ROOT, f), String) for f in ("settings.jl", "objects.jl", "functions4.jl")]

function build(m, seed; n=60, reserve=0.15, ins=0.1)
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, 1.0), n)
    λs = [i <= n ÷ 3 ? 0.2 : 0.8 for i in 1:n]
    agents = [m.Agent(i, deposits[i], true, λs[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, ins, seed, seed, LogNormal(1.0, 1.0), net, 0.1,
                   truncated(Geometric(0.2), 0, n))
end
outputs(m) = Dict(f => read(joinpath(m.dataDir, f), String) for f in readdir(m.dataDir))

const ARMS = [(;), (PUBLIC_ALPHA=1.0,), (PUBLIC_ALPHA=1.0, PUBLIC_BIAS=0.5),
              (PUBLIC_ALPHA=1.0, PUBLIC_BIAS=0.5, PUBLIC_RHO=0.5), (WEIGHT_PHI=0.5,),
              (FIX_DOUBLE_COUNT=true,), (FRESH_CLONE=true,),
              (PUBLIC_ALPHA=0.5, PUBLIC_BIAS=0.3, PUBLIC_RHO=0.8, WEIGHT_PHI=0.7, FRESH_CLONE=true)]
const CONFIGS = [(n=60, reserve=0.15, ins=0.1), (n=120, reserve=0.10, ins=1.5), (n=60, reserve=0.30, ins=0.0)]

@testset "switch arms reproduce $REFERENCE" begin
    for arm in ARMS, cfg in CONFIGS
        ref = load(gensym(:Ref), reference_files()); cur = load(gensym(:Cur), current_files())
        for (k, v) in pairs(arm)
            Core.eval(ref, :($k = $v)); Core.eval(cur, :($k = $v))
        end
        r_ref = [Base.invokelatest(() -> ref.modelRun(build(ref, s; cfg...))) for s in 1:8]
        r_cur = [Base.invokelatest(() -> cur.modelRun(build(cur, s; cfg...))) for s in 1:8]
        o_ref, o_cur = outputs(ref), outputs(cur)
        @test r_ref == r_cur
        @test sort(collect(keys(o_ref))) == sort(collect(keys(o_cur)))
        @test o_ref == o_cur
    end
end
