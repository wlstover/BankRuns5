################################################################################
# test_cara.jl  (added 2026-10-22)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_cara.jl
#
# Risk aversion (BANKRUN_CARA; the user, 2026-10-22) and the drain rule (a
# fraction the bank cannot pay in full is not offered). r1p showed that a
# risk-neutral depositor never splits: V(f) lies on or below the chord between
# V(0) and V(1), so the only "partial" withdrawals were the failing withdrawal's
# tie. Here:
#   A. ceValue: hand values, the risk-neutral limit, and the risk premium.
#   B. CARA -> 0 reproduces the risk-neutral model run for run (all and partial).
#   C. The drain rule: risk-neutral partial now makes the same withdrawals as
#      all, run for run; under CARA every withdrawal that leaves a balance in is
#      paid in full.
#   D. CARA makes depositors split, and splitting rises with the coefficient.
#   E. Refused: CARA without the fire-sale bank.
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
    Random.seed!(20_000 + seed)
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

function arm(name; n_seeds=30, kw...)
    m = load_model(name)
    setsw!(m; FIRE..., kw...)
    out = Base.invokelatest() do
        map(1:n_seeds) do s
            mod = build(m, s); rec = m.RunRecord()
            r = m.modelRun(mod; record=rec)
            (r, rec, mod)
        end
    end
    return m, out
end
same(a, b) = all(a[k][2].order == b[k][2].order &&
                 isapprox(a[k][2].amount, b[k][2].amount; nans=true) &&
                 a[k][1][1] == b[k][1][1] for k in eachindex(a))
nPartial(m) = (p = joinpath(m.dataDir, "bankRunPartial1.csv");
               isfile(p) ? sum(CSV.read(p, DataFrame; header=false)[!, 4]) : 0)

# ---------------------------------------------------------------- A
@testset "A. ceValue" begin
    m = load_model(:A)
    ce(w, a) = Base.invokelatest(m.ceValue, w, a)
    @test ce([3.0, 3.0, 3.0], 2.0) ≈ 3.0
    @test ce([0.0, 2.0], 1.0e-9) ≈ 1.0 atol = 1e-8               # risk-neutral limit
    @test ce([0.0, 2.0], 1.0) ≈ -log((1 + exp(-2.0)) / 2)        # hand value, 0.566
    @test 0.0 < ce([0.0, 2.0], 1.0) < 1.0                         # a risk premium
    @test ce([0.0, 2.0], 5.0) < ce([0.0, 2.0], 1.0)               # rising in a
    @test isfinite(ce([0.0, 1.0e4], 1.0))                         # no overflow
end

# ---------------------------------------------------------------- B
@testset "B. CARA -> 0 is risk neutral" begin
    for w in ("all", "partial")
        _, n0 = arm(Symbol("B0", w); WITHDRAW=w)
        _, n1 = arm(Symbol("B1", w); WITHDRAW=w, CARA=1.0e-9)
        @test same(n0, n1)
    end
end

# ---------------------------------------------------------------- C
@testset "C. drain rule" begin
    _, oa = arm(:Call; WITHDRAW="all")
    mp, op = arm(:Cpart; WITHDRAW="partial", PARTIAL_MIN_SHARE=0.0)
    @test same(oa, op)
    @test nPartial(mp) == 0
    m, out = arm(:Ccara; WITHDRAW="partial", CARA=1.0)
    for (r, rec, mod) in out
        bal = Dict(a.idx => a.deposit for a in mod.agtList)
        for k in (rec.nExog + 1):length(rec.order)
            i, a = rec.order[k], rec.amount[k]
            a < bal[i] * (1 - 1e-9) && @test rec.paid[k] ≈ a      # a fraction: paid in full
            bal[i] -= a
        end
    end
end

# ---------------------------------------------------------------- D
@testset "D. CARA makes depositors split" begin
    counts = map((0.1, 1.0, 10.0)) do g
        m, _ = arm(Symbol("D", replace(string(g), "." => "_")); WITHDRAW="partial", CARA=g)
        nPartial(m)
    end
    println("D: partial withdrawals at CARA 0.1 / 1 / 10: ", counts)
    @test counts[3] > 0
    @test issorted(counts)
end

# ---------------------------------------------------------------- E
@testset "E. refused" begin
    m = load_model(:E)
    err(sw) = Base.invokelatest(m.switchComboError, sw)
    base = (PUBLIC_MODE="markup", FIX_DOUBLE_COUNT=true, FRESH_CLONE=true, PAYOFF="full",
            BALANCE="vault", FUNDAMENTAL="none", PRIVATE_SIGNAL="none",
            RETURN_LO=1.0, RETURN_HI=1.4, THETA_PUBLIC="none", WITHDRAW="all", CARA=0.0)
    @test err(base) === nothing
    @test occursin("CARA", err(merge(base, (CARA=1.0,))))
end
