################################################################################
# test_partial.jl  (added 2026-10-22)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_partial.jl
#
# Partial withdrawals (BANKRUN_WITHDRAW = partial; decided by the user
# 2026-10-22). The default (all) is covered by test_switch_identity.jl. Here:
#   A. chooseFraction: argmax over the grid, ties to the smaller fraction, and
#      the tie-break rules' margins.
#   B. afterOwnWithdrawal on a hand-computed fire sale.
#   C. Identity: with nobody above the size cutoff, partial reproduces all run
#      for run (results, who-runs summary, timing, balance sheet).
#   D. Large depositors: partial withdrawals happen, the books balance, and the
#      original deposits are restored for the outputs.
#   E. The size cutoff: PARTIAL_MIN_SHARE = 0.01 makes the same decisions as no
#      cutoff (every agent values the interior fractions).
#   F. Refused combinations.
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

# A fire-sale bank as modelGen builds it, deposits LogNormal(1, σ); σ 2.5 gives whales.
function build(m::Module, seed::Int; n::Int=60, reserve::Float64=0.05, σ::Float64=2.5,
               insurance::Float64=0.0)
    Random.seed!(20_000 + seed)
    deposits = rand(LogNormal(1.0, σ), n)
    lam = [i <= n ÷ 2 ? 0.1 : 0.9 for i in 1:n]
    agents = [m.Agent(i, deposits[i], true, lam[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    bank.illiquid = (1.0 - reserve + Base.invokelatest(m.switchValue, :EQUITY)) * sum(deposits)
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, insurance, seed, seed,
                   LogNormal(1.0, σ), net, 0.1, truncated(Geometric(0.2), 0, n))
end
const FIRE = (BALANCE="firesale", PAYOFF="recovery", STAY_RETURN=1.1, FUNDAMENTAL="theta",
              PRIVATE_SIGNAL="theta", THETA_NOISE=0.10, FIRE_DISCOUNT=0.6, EQUITY=0.06,
              RETURN_LO=1.0, RETURN_HI=1.4, FRESH_CLONE=true, LOG="summary")

# Runs n_seeds banks through runRow's pieces; returns the module and, per run,
# (result tuple, record, model, isI).
function arm(name; n_seeds=30, σ=2.5, kw...)
    m = load_model(name)
    setsw!(m; FIRE..., kw...)
    out = Base.invokelatest() do
        map(1:n_seeds) do s
            mod = build(m, s; σ=σ)
            rec = m.RunRecord()
            r = m.modelRun(mod; record=rec)
            (r, rec, mod, [a.individualism < 0.5 for a in mod.agtList])
        end
    end
    return m, out
end
summaries(m, out) = Base.invokelatest() do
    vcat([m.typeSummary(o[3], o[4], o[2]) for o in out]...),
    vcat([m.timingRows(o[3], o[4], o[2]) for o in out]...)
end
readcsv(m, f) = (p = joinpath(m.dataDir, f); isfile(p) ? CSV.read(p, DataFrame; header=false) : nothing)

# ---------------------------------------------------------------- A
@testset "A. chooseFraction" begin
    m = load_model(:A)
    cf(vs, va, vi; tb="strict", ps=0.5) = Base.invokelatest(m.chooseFraction, vs, va, vi; tiebreak=tb, pStay=ps)
    @test cf(0.9, 0.8, (0.85, 0.86, 0.84)) == 0.0          # staying is best
    @test cf(0.8, 0.9, (0.85, 0.86, 0.84)) == 1.0          # all is best
    @test cf(0.8, 0.85, (0.82, 0.95, 0.90)) == 0.5         # an interior maximum
    @test cf(0.8, 0.95, (0.95, 0.95, 0.95)) == 0.25        # ties go to the smaller fraction
    @test cf(0.9, 0.9, (0.8, 0.8, 0.8)) == 0.0
    @test cf(0.5, 0.0, (0.1, 0.1, 0.1); tb="legacy") == 1.0   # legacy salvage clause
    @test cf(1.1, 1.2, (1.3, 1.3, 1.3); tb="schuler", ps=1.0) == 0.0
end

# ---------------------------------------------------------------- B
@testset "B. afterOwnWithdrawal" begin
    m = load_model(:B)
    # vault 10, long asset 100, d 0.5, deposits [40, 20, 50]; agent 1 takes 30.
    s = Base.invokelatest(m.SubState, 10.0, [40.0, 20.0, 50.0], BitVector([1, 1, 1]), [1, 2, 3],
                          0, -Inf, false, 0.0, 100.0, 0.5, 110.0)
    s2, paid = Base.invokelatest(m.afterOwnWithdrawal, s, 1, 30.0)
    @test paid == 30.0
    @test s2.illiquid ≈ 100.0 - 20.0 / 0.5                  # sells 40 face for 20 cash
    @test s2.vault ≈ 0.0
    @test s2.deposits == [10.0, 20.0, 50.0] && s.deposits == [40.0, 20.0, 50.0]
    @test s2.bankedDep ≈ 80.0
    @test Base.invokelatest(m.capacityOf, s) ≈ 10.0 + 0.5 * 100.0
    # More than the bank can raise: it sells everything and pays what it has.
    # Taking 70 needs 60 from a capacity of 50: it is paid the 60 the bank has.
    s3, paid3 = Base.invokelatest(m.afterOwnWithdrawal, s, 2, 70.0)
    @test paid3 ≈ 60.0
    @test s3.illiquid == 0.0 && s3.vault ≈ -10.0
end

# ---------------------------------------------------------------- C
@testset "C. nobody above the cutoff: partial == all" begin
    ma, oa = arm(:Call)
    mp, op = arm(:Cpart; WITHDRAW="partial", PARTIAL_MIN_SHARE=1.0e9)
    @test [o[1][1] for o in oa] == [o[1][1] for o in op]
    @test [o[1][2] for o in oa] == [o[1][2] for o in op]
    @test [o[1][3] for o in oa] ≈ [o[1][3] for o in op]
    ta, tia = summaries(ma, oa); tp, tip = summaries(mp, op)
    for c in names(ta)
        c == "key" || c == "type" || @test isapprox(ta[!, c], tp[!, c]; nans=true)
    end
    @test tia == tip
    ba, bp = readcsv(ma, "bankRunBalance1.csv"), readcsv(mp, "bankRunBalance1.csv")
    @test Matrix(ba) == Matrix(bp)
    pr = readcsv(mp, "bankRunPartial1.csv")
    @test all(pr[!, 5] .== 0) && all(pr[!, 4] .== 0)   # no interior decisions, no partial events
    @test readcsv(ma, "bankRunPartial1.csv") === nothing
    @test readcsv(mp, "bankRunWithdrawParams1.csv")[1, 2] == "partial"
end

# ---------------------------------------------------------------- D
@testset "D. large depositors withdraw partially; the books balance" begin
    m, out = arm(:D; WITHDRAW="partial", n_seeds=40)
    pr = readcsv(m, "bankRunPartial1.csv")
    rename!(pr, [:key, :nAnyOut, :nStillIn, :nPartial, :nBig, :share, :largestFrac])
    @test sum(pr.nBig) > 0
    @test sum(pr.nPartial) > 0                          # some interior choices
    for (k, o) in enumerate(out)
        (state, n, depOut), rec, mod, isI = o
        endog = (rec.nExog + 1):length(rec.order)
        exogDep = sum(mod.agtList[i].deposit for i in rec.order[1:rec.nExog]; init=0.0)
        @test depOut ≈ exogDep + sum(rec.amount[endog]; init=0.0)
        @test n == length(unique(rec.order))
        @test all(rec.paid .<= [isnan(a) ? Inf : a for a in rec.amount] .+ 1e-9)
        # per agent, never more withdrawn than deposited (deposits are restored)
        w = zeros(length(mod.agtList))
        for j in endog; w[rec.order[j]] += rec.amount[j]; end
        @test all(w .<= [a.deposit for a in mod.agtList] .* (1 + 1e-9))
        @test pr.nAnyOut[k] == n
    end
    t, _ = summaries(m, out)
    @test all(t.depEndog .<= t.depTotal .- t.depExog .+ 1e-6)
    @test all(t.depStayers .>= -1e-6)
end

# ---------------------------------------------------------------- E
@testset "E. the size cutoff makes the same decisions as no cutoff" begin
    m1, o1 = arm(:E1; WITHDRAW="partial", PARTIAL_MIN_SHARE=0.01)
    m0, o0 = arm(:E0; WITHDRAW="partial", PARTIAL_MIN_SHARE=0.0)
    same = [o1[k][2].order == o0[k][2].order && isapprox(o1[k][2].amount, o0[k][2].amount; nans=true) for k in eachindex(o1)]
    println("E: runs with identical withdrawals (cutoff 0.01 vs 0): ", count(same), " / ", length(same))
    @test all(same)
end

# ---------------------------------------------------------------- F
@testset "F. refused combinations" begin
    m = load_model(:F)
    err(sw) = Base.invokelatest(m.switchComboError, sw)
    base = (PUBLIC_MODE="markup", FIX_DOUBLE_COUNT=true, FRESH_CLONE=true, PAYOFF="recovery",
            BALANCE="firesale", FUNDAMENTAL="theta", PRIVATE_SIGNAL="theta",
            RETURN_LO=1.0, RETURN_HI=1.4, THETA_PUBLIC="none", WITHDRAW="partial")
    @test err(base) === nothing
    @test occursin("firesale", err(merge(base, (BALANCE="vault", PAYOFF="full", FUNDAMENTAL="none",
                                                PRIVATE_SIGNAL="none"))))
    @test occursin("FRESH_CLONE", err(merge(base, (FRESH_CLONE=false,))))
    @test occursin("stale", err(merge(base, (PUBLIC_MODE="stale",))))
    setsw!(m; FIRE..., WITHDRAW="partial")
    mod = Base.invokelatest(build, m, 1; insurance=0.5)
    @test_throws ErrorException Base.invokelatest(m.modelRun, mod)
end
