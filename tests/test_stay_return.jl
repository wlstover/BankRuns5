# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_stay_return.jl
#
# BANKRUN_STAY_RETURN (2026-10-20): Chapter 1's stayers' return R, L = 0.
#   A. decide(): R = 1 is the published rule under every tie-break; R > 1 moves
#      the cutoff on P_stay to 1/R; the legacy salvage clause is untouched.
#   B. R = 1 set explicitly reproduces the default arm run for run and writes no
#      bankRunStayReturn file; R > 1 runs, logs R once per run, stays in range.
#      Directions are printed, not asserted.
#   C. ENV parsing rejects R < 1 and non-numbers.
# That the defaults reproduce the earlier model is tests/test_switch_identity.jl.

using Test
using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase

const ROOT = abspath(joinpath(@__DIR__, ".."))

function load_model(name; depth=30)
    m = Module(name)
    Core.eval(m, :(using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase))
    for f in ("settings.jl", "objects.jl", "functions4.jl")
        Base.include(m, joinpath(ROOT, f))
    end
    dir = mktempdir()
    Core.eval(m, :(dataDir = $dir; workerCore = 1; depth = $depth))
    return m
end

function build(m, seed; n=60, reserve=0.15)
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, 1.0), n)
    λs = [i <= n ÷ 3 ? 0.2 : 0.8 for i in 1:n]
    agents = [m.Agent(i, deposits[i], true, λs[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, 0.1, seed, seed, LogNormal(1.0, 1.0), net, 0.1,
                   truncated(Geometric(0.2), 0, n))
end

m0 = load_model(:R0)

# ---------------------------------------------------------------- A
@testset "A. decide() with a stayers' return" begin
    rules = ("legacy", "schuler", "strict")
    # R = 1 is the published comparison on the whole grid, including interior P_WD.
    for tb in rules, pw in 0:0.1:1, ps in 0:0.1:1
        @test m0.decide(pw, ps; tiebreak=tb, stayReturn=1.0) == m0.decide(pw, ps; tiebreak=tb)
    end
    # R > 1, P_WD = 1: withdraw iff P_stay < 1/R.
    for tb in rules, R in (1.25, 2.0, 4.0)
        @test  m0.decide(1.0, 1 / R - 0.01; tiebreak=tb, stayReturn=R)
        @test !m0.decide(1.0, 1 / R + 0.01; tiebreak=tb, stayReturn=R)
        @test !m0.decide(1.0, 1.0;          tiebreak=tb, stayReturn=R)
    end
    # Under R = 1 an agent with P_stay = 0.6 runs; under R = 2 it stays.
    @test  m0.decide(1.0, 0.6; stayReturn=1.0)
    @test !m0.decide(1.0, 0.6; stayReturn=2.0)
    # P_WD = 0: legacy still salvages, schuler/strict still stay, whatever R.
    for R in (1.0, 2.0), ps in (0.0, 0.5, 1.0)
        @test  m0.decide(0.0, ps; tiebreak="legacy",  stayReturn=R)
        @test !m0.decide(0.0, ps; tiebreak="schuler", stayReturn=R)
        @test !m0.decide(0.0, ps; tiebreak="strict",  stayReturn=R)
    end
end

# ---------------------------------------------------------------- B
@testset "B. arms" begin
    seeds = 1:30
    function arm(; kw...)
        m = load_model(gensym(:B))
        for (k, v) in kw; Core.eval(m, :($k = $v)); end
        res = [Base.invokelatest(() -> m.modelRun(build(m, s))) for s in seeds]
        f = joinpath(m.dataDir, "bankRunStayReturn1.csv")
        log = isfile(f) ? CSV.read(f, DataFrame; header=[:key, :stayReturn]) : nothing
        return res, log
    end
    base, baselog = arm()
    one, onelog   = arm(STAY_RETURN=1.0)
    @test one == base                         # R = 1 is the default, run for run
    @test baselog === nothing && onelog === nothing
    out = Dict(1.0 => base)
    for R in (1.25, 2.0)
        res, log = arm(STAY_RETURN=R)
        out[R] = res
        @test all(0 <= r[2] <= 60 for r in res)
        @test log !== nothing && nrow(log) == length(seeds) && all(log.stayReturn .== R)
    end
    println("\nDiagnostics over $(length(seeds)) seeds (not asserted):")
    for R in sort(collect(keys(out)))
        res = out[R]
        println(rpad("R = $R", 12), " P(run)=", round(mean(r[1] for r in res), digits=2),
                "  mean |S*|=", round(mean(r[2] for r in res), digits=2))
    end
end

# ---------------------------------------------------------------- C
@testset "C. ENV parsing" begin
    withenv("BANKRUN_STAY_RETURN" => "") do
        @test m0.parseSwitchesFromEnv().STAY_RETURN == 1.0
    end
    withenv("BANKRUN_STAY_RETURN" => "1.2") do
        @test m0.parseSwitchesFromEnv().STAY_RETURN == 1.2
    end
    for bad in ("0.9", "abc")
        withenv("BANKRUN_STAY_RETURN" => bad) do
            @test_throws ErrorException m0.parseSwitchesFromEnv()
        end
    end
end
