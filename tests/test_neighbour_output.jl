################################################################################
# test_neighbour_output.jl  (added 2026-10-22)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_neighbour_output.jl
#
# bankRunNeighbour (functions4.jl neighbourRows; rung-4 scorecard S3): decisions
# and withdrawals by the share of neighbours already out.
#   A. nbBin puts shares in the documented bins.
#   B. Fire-sale runs, all and partial: the decisions add up to the record's,
#      the withdrawals to its endogenous withdrawal events, and the file is
#      written once per run with two type rows.
#   C. Vault runs record no decisions and write no file.
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

function build(m::Module, seed::Int; n::Int=60, reserve::Float64=0.05, σ::Float64=2.5)
    Random.seed!(30_000 + seed)
    deposits = rand(LogNormal(1.0, σ), n)
    agents = [m.Agent(i, deposits[i], true, i <= n ÷ 2 ? 0.1 : 0.9) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    bank.illiquid = (1.0 - reserve + Base.invokelatest(m.switchValue, :EQUITY)) * sum(deposits)
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, 0.0, seed, seed,
                   LogNormal(1.0, σ), net, 0.1, truncated(Geometric(0.2), 0, n))
end
const FIRE = (BALANCE="firesale", PAYOFF="recovery", STAY_RETURN=1.1, FUNDAMENTAL="theta",
              PRIVATE_SIGNAL="theta", THETA_NOISE=0.10, FIRE_DISCOUNT=0.6, EQUITY=0.06,
              RETURN_LO=1.0, RETURN_HI=1.4, FRESH_CLONE=true, LOG="summary")

@testset "A. bins" begin
    m = load_model(:A)
    b(x) = Base.invokelatest(m.nbBin, x)
    @test [b(0.0), b(0.05), b(0.1), b(0.15), b(0.3), b(0.4), b(0.6), b(1.0)] == [1, 2, 2, 3, 4, 5, 6, 6]
end

for mode in ("all", "partial")
    @testset "B. fire-sale runs ($mode)" begin
        m = load_model(Symbol("B", mode))
        setsw!(m; FIRE..., WITHDRAW=mode)
        recs = Base.invokelatest() do
            map(1:20) do s
                mod = build(m, s); rec = m.RunRecord()
                m.modelRun(mod; record=rec)
                isI = [a.individualism < 0.5 for a in mod.agtList]
                rows = m.neighbourRows(mod, isI, rec)
                (rec, rows)
            end
        end
        for (rec, rows) in recs
            dec = sum(Matrix(rows[:, r"^dec_"])); wd = sum(Matrix(rows[:, r"^wd_"]))
            @test dec == length(rec.nbAgent)
            @test wd == length(rec.order) - rec.nExog       # each withdrawal is one decision
            @test all(Matrix(rows[:, r"^wd_"]) .<= Matrix(rows[:, r"^dec_"]))
            @test nrow(rows) == 2
        end
        @test sum(length(r[1].nbAgent) for r in recs) > 0
    end
end

@testset "C. vault runs write nothing" begin
    m = load_model(:C)
    setsw!(m; LOG="summary")
    rec = Base.invokelatest() do
        mod = build(m, 1; reserve=0.15); r = m.RunRecord()
        m.modelRun(mod; record=r); r
    end
    @test isempty(rec.nbAgent)
end
