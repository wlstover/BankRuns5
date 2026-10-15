# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_sparse_submodel.jl
#
# The sparse sub-simulation (functions4.jl SubState / subModelRunSparse /
# payoffIfWithdrawNow, 2026-10-15) against the clone-based reference
# (subModelRun on clone(state); withdraw() on a clone), draw by draw: the same
# payout bits and the same RNG state afterwards, over random states that cover
# the stale and fresh paths, the double count on and off, adaptive and quantile
# insurance, overdrawn vaults, and k from 0 to past the banking count.

using Test
using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase

const ROOT = abspath(joinpath(@__DIR__, ".."))
for f in ("settings.jl", "objects.jl", "functions4.jl")
    include(joinpath(ROOT, f))
end
dataDir = mktempdir(); workerCore = 1

function random_state(rng; n)
    deposits = rand(rng, LogNormal(1.0, 1.0), n)
    agents = [Agent(i, deposits[i], true, 0.5) for i in 1:n]
    ins = rand(rng, (0.0, 0.1, 0.5, 0.95, 1.0, 1.5))          # ≥ 1 = adaptive
    bank = Bank(rand(rng, (0.02, 0.1, 0.3)) * sum(deposits), copy(agents), Agent[])
    mod = Model("t", agents, 0.1, bank, ins, 1, 1, LogNormal(1.0, 1.0),
                newman_watts_strogatz(n, 4, 0.1), 0.1, truncated(Geometric(0.1), 0, n))
    for a in sample(rng, agents, rand(rng, 0:n÷4); replace=false)   # earlier withdrawals
        withdraw(mod, a)
    end
    return mod
end

@testset "sparse sub-simulation = clone-based reference" begin
    rng = MersenneTwister(2026)
    ncase = 0
    for rep in 1:300
        n = rand(rng, (20, 60, 150))
        mod = random_state(rng; n=n)
        banked = filter(a -> a.banked, mod.agtList)
        isempty(banked) && continue
        agt = rand(rng, banked)
        # observed withdrawing neighbours: a mix of already-withdrawn and banked agents
        others = filter(a -> a.idx != agt.idx, mod.agtList)
        nbrs = sample(rng, others, min(length(others), rand(rng, 0:6)); replace=false)
        snap = clone(mod)
        state = SubState(snap)
        @test SubState(mod).bankedIdx == state.bankedIdx      # Model and clone agree
        for skip in (false, true), k in (0, 1, 3, n ÷ 2, n + 5)
            seed = rand(rng, UInt32)
            Random.seed!(seed); r_ref = subModelRun(clone(snap), agt, nbrs, k; skipWithdrawn=skip); x_ref = rand()
            Random.seed!(seed); r_new = subModelRunSparse(state, agt, nbrs, k; skipWithdrawn=skip); x_new = rand()
            @test r_ref[1] === r_new[1]          # identical Float64 bits
            @test r_ref[2] == r_new[2]
            @test x_ref == x_new                 # identical RNG consumption
            ncase += 1
        end
        base = clone(snap)
        got = withdraw(base, base.agtList[agt.idx])
        @test payoffIfWithdrawNow(state, agt) == (got < agt.deposit ? 0.0 : 1.0)
    end
    println("checked $ncase sub-simulation draws")
end
