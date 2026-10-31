################################################################################
# test_oneshot.jl  (added 2026-10-31)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_oneshot.jl
#
# Rung 2's nest switches (docs/rung2_nest.md). The defaults are covered by
# test_switch_identity.jl and test_episodes.jl (byte-identical). Here:
#   A. TIMING = oneshot: one tick; every agent still banking after the shock decides
#      exactly once (one bankRunOneShot row each); the bank is frozen while they
#      decide (the vault in every decision row is the post-shock vault); the
#      withdrawals executed are exactly the decided ones; est = (1 − ω)·x + ω·y.
#   B. HEADCOUNT_BELIEF = prior: anticipatedWithdrawals uses the prior draws only.
#   C. FAIL_PAYOFF = insurance: a stayer in a failed bank gets its insured share
#      only, in the sub-simulations (stayerPayoff), the realised value (stayValue)
#      and lossStayers.
#   D. Refused combinations and parsing.
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

# A model as modelGen builds it, including the long asset under firesale.
function build(m::Module, seed::Int; n::Int=60, reserve::Float64=0.20, ins::Float64=0.0, sigma::Float64=1.0)
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, sigma), n)
    λs = [i <= n ÷ 3 ? 0.2 : 0.8 for i in 1:n]
    agents = [m.Agent(i, deposits[i], true, λs[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    Base.invokelatest(m.switchValue, :BALANCE) == "firesale" &&
        (bank.illiquid = (1.0 - reserve + Base.invokelatest(m.switchValue, :EQUITY)) * sum(deposits))
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, ins, seed, seed,
                   LogNormal(1.0, sigma), net, 0.1, truncated(Geometric(0.2), 0, n))
end
readlog(m, f, cols) = (p = joinpath(m.dataDir, f); isfile(p) ? CSV.read(p, DataFrame; header=cols) : nothing)

# The nest of docs/rung2_nest.md, at a small N.
const NEST = (BALANCE="firesale", PAYOFF="recovery", STAY_RETURN=1.1, FUNDAMENTAL="theta",
              PRIVATE_SIGNAL="theta", THETA_PUBLIC="stale", THETA_PUBLIC_LEVEL=0.5,
              LAMBDA_SCOPE="theta", THETA_NOISE_DIST="uniform", FRESH_CLONE=true,
              TIEBREAK="strict", TIMING="oneshot", HEADCOUNT_BELIEF="prior", FAIL_PAYOFF="insurance")
const ONESHOT_COLS = [:key, :agent, :individualism, :x, :est, :withdrew, :wdProb, :stayProb]
const ENDOG_COLS = [:key, :agent, :withdraw, :deposit, :tick, :vault, :wdProb, :stayProb]

# ---------------------------------------------------------------- A
@testset "A. TIMING = oneshot" begin
    m = load_model(:A)
    setsw!(m; NEST..., LOG="full")
    nDecided = 0
    for s in 1:12
        mod = build(m, s; reserve=0.10, sigma=0.0)
        rec = Base.invokelatest(m.RunRecord)
        Base.invokelatest(m.modelRun, mod; record=rec)
        os = readlog(m, "bankRunOneShot1.csv", ONESHOT_COLS)
        en = readlog(m, "bankRunEndogenous1.csv", ENDOG_COLS)
        o = os[os.key .== mod.key, :]
        e = en[en.key .== mod.key, :]
        exog = Set(rec.order[1:rec.nExog])
        # one tick, every agent left after the shock decides exactly once
        @test rec.nTicks == 1
        @test sort(o.agent) == sort([i for i in 1:length(mod.agtList) if !(i in exog)])
        @test all(e.tick .== 1) && nrow(e) == nrow(o)
        # the bank is frozen while they decide: one vault value across the decisions
        @test length(unique(e.vault)) == 1
        # executed withdrawals = the decided ones (no liquidity failure in these banks)
        @test Set(rec.order[rec.nExog+1:end]) == Set(o.agent[o.withdrew])
        # the blend: est = (1 − ω)·x + ω·y with ω = λ (LAMBDA_SCOPE theta), y = 0.5
        @test all(isapprox.(o.est, (1 .- o.individualism) .* o.x .+ o.individualism .* 0.5; atol=1e-12))
        # uniform noise: |x − θ| ≤ ε_x
        θ = first(Base.invokelatest(m.episodeThetaDraws, mod.seed2, 1))
        @test all(abs.(o.x .- θ) .<= 0.10 + 1e-12)
        nDecided += count(o.withdrew)
    end
    @test nDecided > 0                          # some agents withdraw: the test is not vacuous
    # sequential timing on the same banks takes more than one tick somewhere
    ms = load_model(:As)
    setsw!(ms; NEST..., TIMING="sequential")
    ticks = map(1:12) do s
        rec = Base.invokelatest(ms.RunRecord)
        Base.invokelatest(ms.modelRun, build(ms, s; reserve=0.10, sigma=0.0); record=rec)
        rec.nTicks
    end
    @test maximum(ticks) > 1
end

# ---------------------------------------------------------------- B
@testset "B. HEADCOUNT_BELIEF = prior" begin
    m = load_model(:B)
    agt = m.Agent(1, 1.0, true, 0.8)
    draws = [0, 3, 10, 40]
    # λ = 0 (what modelRun passes under prior): the prior draws less those already out
    @test m.anticipatedWithdrawals(agt, draws, 50, 0, 2, 60, 1; pubAlpha=0.0, weightPhi=1.0, λ=0.0) ==
          max.(0, draws .- 2)
    # the blend (the default) moves with the neighbour estimate; prior does not
    @test m.anticipatedWithdrawals(agt, draws, 50, 0, 2, 60, 1; pubAlpha=0.0, weightPhi=1.0, λ=0.8) !=
          max.(0, draws .- 2)
end

# ---------------------------------------------------------------- C
@testset "C. FAIL_PAYOFF = insurance" begin
    m = load_model(:C)
    setsw!(m; BALANCE="firesale", PAYOFF="recovery")
    # a failing bank (ρ = 0.5): recovery max(ρR·d, min(d, cap)), insurance min(d, cap)
    @test Base.invokelatest(m.stayerPayoff, 5.0, 0.0, 1.0, 10.0, 4.0, 1.0, 1.1) ≈ max(0.5 * 1.1 * 4.0, 1.0)
    @test Base.invokelatest(m.stayValue, 0.5, [4.0], 1.0, 1.1) ≈ [0.55]
    setsw!(m; FAIL_PAYOFF="insurance")
    @test Base.invokelatest(m.stayerPayoff, 5.0, 0.0, 1.0, 10.0, 4.0, 1.0, 1.1) ≈ 1.0
    @test Base.invokelatest(m.stayValue, 0.5, [4.0], 1.0, 1.1) ≈ [0.25]
    @test Base.invokelatest(m.stayerPayoff, 50.0, 0.0, 1.0, 10.0, 4.0, 1.0, 1.1) ≈ 1.1 * 4.0   # solvent: R·d
    # lossStayers with cap 0: a failed bank's stayers lose their whole balance
    setsw!(m; FUNDAMENTAL="theta")
    nFailed = 0
    for s in 1:30
        mod = build(m, s; reserve=0.05, ins=0.0)
        isI = [a.individualism < 0.5 for a in mod.agtList]
        rec = Base.invokelatest(m.RunRecord)
        failed = Base.invokelatest(m.modelRun, mod; record=rec)[1]
        rows = Base.invokelatest(m.typeSummary, mod, isI, rec)
        stay = [a.banked for a in mod.agtList]
        d = [a.deposit for a in mod.agtList]
        if failed
            nFailed += 1
            @test sum(rows.lossStayers) ≈ sum(d[stay]) atol=1e-9
        else
            @test all(rows.lossStayers .== 0.0)
        end
    end
    @test nFailed > 0
end

# ---------------------------------------------------------------- D
@testset "D. refused combinations and parsing" begin
    m = load_model(:D)
    D = m.SWITCH_DEFAULTS
    @test D.TIMING == "sequential" && D.HEADCOUNT_BELIEF == "blend" && D.FAIL_PAYOFF == "recovery"
    err(; kw...) = m.switchComboError(merge(D, (; kw...)))
    FS = (BALANCE="firesale", PAYOFF="recovery", FRESH_CLONE=true)
    @test err(; FS..., TIMING="oneshot") === nothing
    @test err(; FS..., TIMING="oneshot", WITHDRAW="partial") !== nothing
    @test err(; FS..., TIMING="oneshot", CARA=0.1) !== nothing
    @test err(; FS..., FAIL_PAYOFF="insurance") === nothing
    @test err(FAIL_PAYOFF="insurance") !== nothing                 # needs the fire-sale bank
    @test err(HEADCOUNT_BELIEF="prior") === nothing
    withenv("BANKRUN_TIMING" => "oneshot", "BANKRUN_HEADCOUNT_BELIEF" => "prior",
            "BANKRUN_BALANCE" => "firesale", "BANKRUN_PAYOFF" => "recovery",
            "BANKRUN_FAIL_PAYOFF" => "insurance") do
        sw = m.parseSwitchesFromEnv()
        @test sw.TIMING == "oneshot" && sw.HEADCOUNT_BELIEF == "prior" && sw.FAIL_PAYOFF == "insurance"
    end
    withenv("BANKRUN_TIMING" => "simultaneous") do
        @test_throws ErrorException m.parseSwitchesFromEnv()
    end
    mm = load_model(:Dm)                                            # refused inside modelRun too
    setsw!(mm; FAIL_PAYOFF="insurance")
    @test_throws ErrorException Base.invokelatest(() -> mm.modelRun(build(mm, 1)))
end
