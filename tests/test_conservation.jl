################################################################################
# test_conservation.jl
#
# Property-based test demonstrating the vault-deposit conservation invariant
# in the BankRuns5 model. This is a single-invariant prototype; if the workflow
# proves useful, expand into a full tests/ directory under Pkg's Test framework.
#
# Run from BankRuns5/:
#     julia --project=. tests/test_conservation.jl
#
# Or, if no Project.toml is configured for tests yet:
#     julia tests/test_conservation.jl
#
# Invariant tested:
#     For every reachable state of a Model `mod`,
#         initial_vault - mod.theBank.vault
#             == sum(a.deposit for a in mod.theBank.withdrawHistory)
#
# Why this matters: the vault accounting at functions4.jl:214 debits the FULL
# deposit (`vault -= agt.deposit`) even when the agent's payout is capped by
# deposit insurance. A refactor that conflates the two would silently break
# conservation; this test catches it on every seed.
################################################################################

using Test
using Distributions
using Distributed   # functions4.jl references `Future` without an explicit using
using Graphs
using Random
using StatsBase     # functions4.jl references `sample`/weights helpers

# Load the model code. Pulled in by relative path so the test runs from BankRuns5/.
const BANKRUNS5_ROOT = abspath(joinpath(@__DIR__, ".."))
include(joinpath(BANKRUNS5_ROOT, "objects.jl"))
include(joinpath(BANKRUNS5_ROOT, "functions4.jl"))

# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------

"""
    build_test_model(; n_agents, deposits, reserve_ratio, deposit_insurance, seed)

Construct a minimal `Model` instance suitable for testing the `withdraw()`
accounting path. Stubs out fields not used by `withdraw` (network, probThresh,
exogProb, depositDistribution) with cheap placeholder values.
"""
function build_test_model(;
    n_agents::Int,
    deposits::Vector{Float64},
    reserve_ratio::Float64 = 0.1,
    deposit_insurance::Float64 = 0.0,
    seed::Int = 1,
)
    @assert length(deposits) == n_agents "deposits length must match n_agents"

    # Agents: idx, deposit, banked=true, individualism=0.5 (irrelevant to withdraw)
    agents = [Agent(i, deposits[i], true, 0.5) for i in 1:n_agents]

    initial_vault = reserve_ratio * sum(deposits)
    bank = Bank(initial_vault, copy(agents), Agent[])

    mod = Model(
        "test_key",
        agents,
        reserve_ratio,
        bank,
        deposit_insurance,
        seed, seed,
        LogNormal(0.0, 1.0),     # depositDistribution — stub
        path_graph(n_agents),    # network — stub
        0.5,                     # probThresh — stub
        Uniform(0.0, 1.0),       # exogProb — stub
    )
    return mod, initial_vault
end

"""
    conservation_holds(mod, initial_vault) -> Bool

Returns true iff the vault-deposit conservation invariant holds:
    initial_vault - mod.theBank.vault
        == sum(a.deposit for a in mod.theBank.withdrawHistory)
"""
function conservation_holds(mod::Model, initial_vault::Float64; atol::Float64 = 1e-9)
    withdrawn_sum = isempty(mod.theBank.withdrawHistory) ?
        0.0 : sum(a.deposit for a in mod.theBank.withdrawHistory)
    delta = initial_vault - mod.theBank.vault
    return isapprox(delta, withdrawn_sum; atol = atol)
end

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------

@testset "Conservation invariant: vault - sum(withdrawn deposits)" begin

    # --- Test 1: trivial baseline (no withdrawals) ---
    @testset "no withdrawals → invariant holds at t=0" begin
        mod, init_vault = build_test_model(
            n_agents = 5,
            deposits = Float64[10, 20, 30, 40, 50],
        )
        @test conservation_holds(mod, init_vault)
    end

    # --- Test 2: single withdrawal in vault-positive regime ---
    @testset "single withdrawal, vault stays positive" begin
        mod, init_vault = build_test_model(
            n_agents = 5,
            deposits = Float64[10, 20, 30, 40, 50],
            reserve_ratio = 1.0,  # full reserves, vault won't go negative
        )
        agt = mod.agtList[3]  # deposit = 30
        withdraw(mod, agt)
        @test conservation_holds(mod, init_vault)
        @test mod.theBank.vault == init_vault - 30.0
        @test agt.banked == false
    end

    # --- Test 3: withdrawals push vault negative (bankruptcy regime) ---
    # The vault accounting debits the FULL deposit even when the agent's payout
    # is capped by insurance. Conservation must hold across this branch too.
    @testset "withdrawals push vault negative — invariant still holds" begin
        mod, init_vault = build_test_model(
            n_agents = 5,
            deposits = Float64[10, 20, 30, 40, 50],
            reserve_ratio = 0.1,        # vault = 15, total deposits = 150
            deposit_insurance = 0.5,    # quantile-based
        )
        for agt in mod.agtList
            withdraw(mod, agt)
            @test conservation_holds(mod, init_vault)
        end
        # Final state: vault should equal initial - total deposits
        @test mod.theBank.vault == init_vault - sum(a.deposit for a in mod.agtList)
        @test mod.theBank.vault < 0  # bank is "bankrupt"
        @test all(!a.banked for a in mod.theBank.withdrawHistory)
    end

    # --- Test 4: PROPERTY-BASED — randomized withdrawal orderings, many seeds.
    # This is the headline test: the invariant should hold for EVERY seed and
    # EVERY ordering of withdrawals. If any seed produces a violation, the
    # test fails and prints which seed broke it — making the failure debuggable.
    @testset "property: invariant holds across 50 random withdrawal orderings" begin
        n_seeds = 50
        violations = Int[]
        for seed in 1:n_seeds
            mod, init_vault = build_test_model(
                n_agents = 20,
                deposits = Float64[5.0 * i for i in 1:20],  # 5..100
                reserve_ratio = 0.2,
                deposit_insurance = 0.3,
                seed = seed,
            )
            rng = MersenneTwister(seed)
            order = randperm(rng, length(mod.agtList))
            for i in order
                withdraw(mod, mod.agtList[i])
                if !conservation_holds(mod, init_vault)
                    push!(violations, seed)
                    break
                end
            end
        end
        @test isempty(violations)
        if !isempty(violations)
            @info "Conservation violated for seeds:" violations
        end
    end

    # --- Test 5: monotonicity sub-invariant — once banked=false, stays false.
    # Bundled into the same testset because it's natural to check alongside
    # conservation; in a real expansion this becomes its own @testset block.
    @testset "monotonicity: withdrawn agents do not re-bank" begin
        mod, init_vault = build_test_model(
            n_agents = 10,
            deposits = fill(10.0, 10),
            reserve_ratio = 0.5,
        )
        for agt in mod.agtList[1:5]
            withdraw(mod, agt)
        end
        # Snapshot which agents are flagged banked=false
        withdrawn_idx = Set(a.idx for a in mod.theBank.withdrawHistory)
        # Now withdraw the rest and verify the original 5 are still false.
        for agt in mod.agtList[6:10]
            withdraw(mod, agt)
        end
        for agt in mod.theBank.withdrawHistory
            if agt.idx in withdrawn_idx
                @test agt.banked == false
            end
        end
        @test conservation_holds(mod, init_vault)
    end
end

println("\n✓ All conservation invariant tests passed.")
