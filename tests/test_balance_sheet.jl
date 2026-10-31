################################################################################
# test_balance_sheet.jl  (added 2026-10-21)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_balance_sheet.jl
#
# The fire-sale bank, expected recovery and the fundamental θ
# (BANKRUN_BALANCE / PAYOFF / FUNDAMENTAL, docking with Chapter 1's Rochet–Vives
# bank). The defaults are covered by test_switch_identity.jl (byte-identical to
# 420ecc0). Here:
#   A. raiseCash: the fire-sale arithmetic, and withdraw()'s accounting over a
#      run of withdrawals: vault = vault0 + (1 − d)·sold − Σ deposits.
#   B. stayerPayoff on hand-computed banks: solvent, pro rata, insurance floor.
#   C. The sparse sub-simulation against subModelRun on clones, draw by draw
#      (payoffs and RNG state), under firesale and under recovery in the vault
#      bank; payoffIfWithdrawNow against withdraw() on a clone.
#   D. modelRun under firesale: the bankRunBalance row adds up, failType agrees
#      with the solvency test, and θ is the same across paired arms while the
#      shock (main RNG stream) is untouched.
#   E. The θ posterior: truncated normal around the signal.
#   F. Refused switch combinations, in modelRun and at parse time.
#   G. Smoke property: failures concentrate at low θ.
#   I. THETA_NOISE_DIST = uniform (2026-10-31, rung 2): the draws are θ + U[−ε, ε] on
#      the same θ stream, the θ window is Chapter 1's U[est ± w] truncated to [0, 1],
#      and the switch parses; normal stays the default.
#   H. typeSummary's lossStayers (2026-10-31): the stayers' exact shortfall at par,
#      against a hand computation from the bankRunBalance row; NaN on the vault bank.
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
function build(m::Module, seed::Int; n::Int=60, reserve::Float64=0.20, ins::Float64=0.1)
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, 1.0), n)
    λs = [i <= n ÷ 3 ? 0.2 : 0.8 for i in 1:n]
    agents = [m.Agent(i, deposits[i], true, λs[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    Base.invokelatest(m.switchValue, :BALANCE) == "firesale" &&
        (bank.illiquid = (1.0 - reserve + Base.invokelatest(m.switchValue, :EQUITY)) * sum(deposits))
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, ins, seed, seed,
                   LogNormal(1.0, 1.0), net, 0.1, truncated(Geometric(0.2), 0, n))
end
readlog(m, f, cols) = (p = joinpath(m.dataDir, f); isfile(p) ? CSV.read(p, DataFrame; header=cols) : nothing)
const BALANCE_COLS = [:key, :theta, :returnTheta, :vaultInit, :illiquidInit, :vaultFinal, :illiquidFinal,
                      :assetsT, :promises, :solvent, :failType, :largestShare, :largestToCapacity,
                      :largestWithdrew]
const FIRE = (BALANCE="firesale", PAYOFF="recovery", STAY_RETURN=1.1)

# ---------------------------------------------------------------- A
@testset "A. fire-sale arithmetic and accounting" begin
    m = load_model(:A)
    rc = m.raiseCash
    @test rc(10.0, 50.0, 4.0, 0.25) == (10.0, 50.0)          # the vault covers it
    @test rc(1.0, 0.0, 4.0, 0.25) == (1.0, 0.0)              # nothing to sell (vault bank)
    v, ill = rc(1.0, 50.0, 4.0, 0.25)                         # sell 3 / 0.75 = 4 units
    @test v == 4.0 && ill ≈ 46.0
    v, ill = rc(1.0, 2.0, 4.0, 0.25)                          # capacity 1.5 < 3: sell all
    @test v == 2.5 && ill == 0.0

    setsw!(m; FIRE...)
    d = Base.invokelatest(m.switchValue, :FIRE_DISCOUNT)
    for s in 1:15
        mod = build(m, s; reserve=0.05)
        v0, i0 = mod.theBank.vault, mod.theBank.illiquid
        @test i0 ≈ (1 - 0.05 + 0.10) * sum(a.deposit for a in mod.agtList)
        paidAll, depAll = 0.0, 0.0
        for a in shuffle(MersenneTwister(s), mod.agtList)
            capBefore = mod.theBank.vault + (1 - d) * mod.theBank.illiquid
            paid = Base.invokelatest(m.withdraw, mod, a)
            depAll += a.deposit
            @test mod.theBank.illiquid >= 0.0
            @test mod.theBank.vault ≈ v0 + (1 - d) * (i0 - mod.theBank.illiquid) - depAll atol=1e-8
            if a.deposit <= capBefore + 1e-12
                @test paid == a.deposit                       # paid in full while capacity lasts
            else                                              # sold out: what is left, or insurance
                ins = quantile(mod.depositDistribution, mod.depositInsurance)
                @test mod.theBank.illiquid == 0.0
                @test paid == max(0.0, capBefore, min(a.deposit, ins))
            end
        end
        @test mod.theBank.vault < 0.0                         # everyone out: the bank cannot pay all
    end
end

# ---------------------------------------------------------------- B
@testset "B. stayer payoff" begin
    m = load_model(:B)
    sp = m.stayerPayoff
    # cash 2, 10 units at 1.2 = 14 >= promises 1.1·10 = 11: solvent, paid R·dep
    @test sp(2.0, 10.0, 1.2, 11.0, 4.0, 1.0, 1.1) ≈ 1.1 * 4.0
    # assets 7 against 11: ρ = 7/11, pro rata, above the insurance cap of 1
    @test sp(2.0, 5.0, 1.0, 11.0, 4.0, 1.0, 1.1) ≈ (7 / 11) * 1.1 * 4.0
    # a deeply insolvent bank: the insurance cap is the floor
    @test sp(0.0, 1.0, 0.5, 11.0, 4.0, 3.0, 1.1) == 3.0
    @test sp(-5.0, 0.0, 1.0, 11.0, 4.0, 0.0, 1.1) == 0.0      # negative vault counts as no cash
    @test sp(0.0, 0.0, 1.0, 0.0, 4.0, 0.0, 1.1) ≈ 1.1 * 4.0   # no promises left: solvent
end

# ---------------------------------------------------------------- C
@testset "C. sparse sub-simulation = clone reference" begin
    for (label, sw, terminal) in (("firesale", FIRE, true), ("recovery, vault bank", (PAYOFF="recovery",), false))
        m = load_model(gensym(:C))
        setsw!(m; sw...)
        rng = MersenneTwister(11)
        nchk = 0
        for s in 1:25
            mod = build(m, s; reserve=rand(rng, (0.05, 0.15, 0.3)), ins=rand(rng, (0.0, 0.1, 0.5, 1.5)))
            for a in sample(rng, mod.agtList, rand(rng, 0:10); replace=false)
                Base.invokelatest(m.withdraw, mod, a)
            end
            focal = rand(rng, filter(a -> a.banked, mod.agtList))
            wn = filter(a -> !a.banked, m.neighborList(mod, focal))
            for skip in (true, false), k in (0, 3, 15, 200)
                Rθ = terminal ? rand(rng, (0.6, 1.0, 1.4)) : nothing
                seed = rand(rng, UInt32)
                Random.seed!(seed)
                a = Base.invokelatest(m.subModelRunSparse, m.SubState(Base.invokelatest(m.clone, mod)), focal, wn, k;
                                      skipWithdrawn=skip, terminalReturn=Rθ, stayReturn=1.1)
                after1 = rand()
                Random.seed!(seed)
                b = Base.invokelatest(m.subModelRun, Base.invokelatest(m.clone, mod), focal, wn, k;
                                      skipWithdrawn=skip, terminalReturn=Rθ, stayReturn=1.1)
                after2 = rand()
                @test a == b
                @test after1 == after2
                nchk += 1
            end
            # withdrawing now: the recovery share, as withdraw() on a clone pays it
            c = Base.invokelatest(m.clone, mod)
            cf = first(filter(x -> x.idx == focal.idx, c.agtList))
            @test Base.invokelatest(m.payoffIfWithdrawNow, m.SubState(mod), focal; recovery=true) ==
                  Base.invokelatest(m.withdraw, c, cf) / focal.deposit
        end
        @test nchk > 100
    end
end

# ---------------------------------------------------------------- D
function arm(name; n_seeds=20, reserve=0.20, kw...)
    m = load_model(name)
    setsw!(m; kw...)
    res = Base.invokelatest(() -> [m.modelRun(build(m, s; reserve=reserve)) for s in 1:n_seeds])
    return m, res
end

@testset "D. modelRun under firesale" begin
    m, res = arm(:D1; FIRE..., FUNDAMENTAL="theta")
    bal = readlog(m, "bankRunBalance1.csv", BALANCE_COLS)
    @test bal !== nothing && nrow(bal) == 20
    @test all(in(("none", "liquidity", "insolvency")), bal.failType)
    for (r, (failed, nW, depW)) in zip(eachrow(bal), res)
        @test failed == (r.failType != "none")
        @test r.solvent == (r.failType == "none")
        r.failType == "liquidity" || @test r.solvent == (r.assetsT >= r.promises)
        # accounting over the whole run: the vault moved by fire-sale proceeds less deposits paid out
        @test r.vaultFinal ≈ r.vaultInit + (1 - 0.25) * (r.illiquidInit - r.illiquidFinal) - depW atol=1e-8
        @test r.returnTheta ≈ 0.9 + 0.4 * r.theta
    end
    pp = readlog(m, "bankRunBalanceParams1.csv",
                 [:key, :payoff, :balance, :fireDiscount, :equity, :fundamental, :returnLo, :returnHi, :thetaNoise])
    @test pp !== nothing && all(pp.balance .== "firesale") && all(pp.payoff .== "recovery")
    @test !isfile(joinpath(m.dataDir, "bankRunPrivateParams1.csv"))    # no private signal

    # Paired arms: the θ signal changes beliefs only. θ, the shock and the
    # initial balance sheet are the same run for run.
    ms, _ = arm(:D2; FIRE..., FUNDAMENTAL="theta", PRIVATE_SIGNAL="theta", THETA_NOISE=0.05)
    bs = readlog(ms, "bankRunBalance1.csv", BALANCE_COLS)
    @test bs.theta == bal.theta
    @test bs.vaultInit == bal.vaultInit && bs.illiquidInit == bal.illiquidInit
    ex(mm) = CSV.read(joinpath(mm.dataDir, "bankRunExogenous1.csv"), DataFrame; header=false)
    @test ex(ms) == ex(m)
    pr = readlog(ms, "bankRunPrivateParams1.csv", [:key, :privateSignal, :privateNoise, :nExog])
    @test pr !== nothing && all(pr.privateSignal .== "theta")

    # FUNDAMENTAL = none: θ = 1, the long asset returns RETURN_HI.
    mn, _ = arm(:D3; FIRE...)
    bn = readlog(mn, "bankRunBalance1.csv", BALANCE_COLS)
    @test all(bn.theta .== 1.0) && all(bn.returnTheta .≈ 1.3)

    # Recovery in the vault bank writes the params file but no balance rows.
    mr, _ = arm(:D4; PAYOFF="recovery", n_seeds=3)
    @test isfile(joinpath(mr.dataDir, "bankRunBalanceParams1.csv"))
    @test !isfile(joinpath(mr.dataDir, "bankRunBalance1.csv"))
end

# ---------------------------------------------------------------- E
@testset "E. θ posterior" begin
    rng = MersenneTwister(5)
    for (x, s) in ((0.5, 0.05), (0.3, 0.1), (0.02, 0.1))
        d = truncated(Normal(x, s), 0.0, 1.0)
        draws = rand(rng, d, 20_000)
        @test all(0 .<= draws .<= 1)
        @test abs(mean(draws) - mean(d)) < 0.005
        x > 3s && @test abs(mean(draws) - x) < 0.005          # interior: centred on the signal
    end
end

# ---------------------------------------------------------------- F
@testset "F. refused combinations" begin
    m = load_model(:F)
    D = m.SWITCH_DEFAULTS
    err(; kw...) = m.switchComboError(merge(D, (; kw...)))
    @test err() === nothing
    @test err(BALANCE="firesale") !== nothing                       # needs PAYOFF=recovery
    @test err(BALANCE="firesale", PAYOFF="recovery") === nothing
    @test err(BALANCE="firesale", PAYOFF="recovery", FIX_DOUBLE_COUNT=false) !== nothing
    @test err(FUNDAMENTAL="theta") !== nothing                      # needs firesale
    @test err(PRIVATE_SIGNAL="theta", BALANCE="firesale", PAYOFF="recovery") !== nothing
    @test err(RETURN_LO=1.5, RETURN_HI=1.0) !== nothing
    mm = load_model(:Fg)
    setsw!(mm; BALANCE="firesale")
    @test_throws ErrorException Base.invokelatest(() -> mm.modelRun(build(mm, 1)))
    withenv("BANKRUN_BALANCE" => "firesale") do
        @test_throws ErrorException m.parseSwitchesFromEnv()
    end
    withenv("BANKRUN_BALANCE" => "firesale", "BANKRUN_PAYOFF" => "recovery",
            "BANKRUN_FUNDAMENTAL" => "theta", "BANKRUN_PRIVATE_SIGNAL" => "theta") do
        sw = m.parseSwitchesFromEnv()
        @test sw.BALANCE == "firesale" && sw.FUNDAMENTAL == "theta"
    end
end

# ---------------------------------------------------------------- G
@testset "G. failures concentrate at low θ" begin
    m, res = arm(:G; n_seeds=60, FIRE..., FUNDAMENTAL="theta")
    bal = readlog(m, "bankRunBalance1.csv", BALANCE_COLS)
    failed = bal.failType .!= "none"
    lo, hi = failed[bal.theta .< 0.5], failed[bal.theta .>= 0.5]
    @test mean(lo) > mean(hi)
    @test any(failed) && !all(failed)
end

# ---------------------------------------------------------------- H
@testset "H. stayers' exact loss (lossStayers)" begin
    m = load_model(:H)
    setsw!(m; FIRE..., FUNDAMENTAL="theta")
    R, nFailedWithLoss = 1.1, 0
    for s in 1:30
        mod = build(m, s; reserve=0.05)
        isI = [a.individualism < 0.5 for a in mod.agtList]
        rec = Base.invokelatest(m.RunRecord)
        Base.invokelatest(m.modelRun, mod; record=rec)
        rows = Base.invokelatest(m.typeSummary, mod, isI, rec)
        b = last(readlog(m, "bankRunBalance1.csv", BALANCE_COLS))
        ρ = b.failType == "liquidity" ? 0.0 : b.promises > 0 ? b.assetsT / b.promises : Inf
        @test rec.endRho == ρ
        cap = Base.invokelatest(m.currentCap, mod)
        stay = [a.banked for a in mod.agtList]
        d = [a.deposit for a in mod.agtList]
        recov(x) = ρ >= 1.0 ? R * x : max(ρ * R * x, min(x, cap))
        loss = [stay[i] ? max(d[i] - recov(d[i]), 0.0) : 0.0 for i in eachindex(d)]
        for (t, sel) in (("I", isI), ("C", .!isI))
            @test only(rows[rows.type .== t, :lossStayers]) ≈ sum(loss[sel]) atol=1e-9
        end
        b.solvent && @test all(rows.lossStayers .== 0.0)
        (!b.solvent && sum(loss) > 0) && (nFailedWithLoss += 1)
    end
    @test nFailedWithLoss > 0                     # the check is not vacuous
    mv = load_model(:Hv)                          # vault bank: no ρ, NaN
    modv = build(mv, 1)
    recv = Base.invokelatest(mv.RunRecord)
    Base.invokelatest(mv.modelRun, modv; record=recv)
    rowsv = Base.invokelatest(mv.typeSummary, modv, [a.individualism < 0.5 for a in modv.agtList], recv)
    @test all(isnan, rowsv.lossStayers)
end

# ---------------------------------------------------------------- I
@testset "I. uniform θ noise (THETA_NOISE_DIST)" begin
    m = load_model(:I)
    @test m.SWITCH_DEFAULTS.THETA_NOISE_DIST == "normal"
    # the window: Chapter 1's U[est ± w], w = (1 − ω)·ε_x + ω·ε_y, truncated to [0, 1]
    setsw!(m; THETA_NOISE_DIST="uniform")
    for (x, y, ω, ex, ey) in ((0.5, 0.6, 0.3, 0.1, 0.2), (0.02, 0.6, 0.0, 0.1, 0.1), (1.05, 0.9, 0.5, 0.1, 0.05))
        d = Base.invokelatest(m.thetaBelief, x, ex, y, ω, ey)
        est, w = (1 - ω) * x + ω * y, (1 - ω) * ex + ω * ey
        @test minimum(d) ≈ max(est - w, 0.0) && maximum(d) ≈ min(est + w, 1.0)
        draws = rand(MersenneTwister(1), d, 5_000)
        @test all(max(est - w, 0.0) .<= draws .<= min(est + w, 1.0))
    end
    @test Base.invokelatest(m.thetaBelief, 0.5, 0.1, nothing, 0.0, 0.1) == truncated(Uniform(0.4, 0.6), 0.0, 1.0)
    @test Base.invokelatest(m.thetaNoiseVar, 0.3) ≈ 0.03
    # the draws: same θ, |x − θ| ≤ ε, filling the interval; one draw per agent either way
    for s2 in (11, 12, 13)
        θu, xu = Base.invokelatest(m.episodeThetaDraws, s2, 4_000)
        @test all(abs.(xu .- θu) .<= 0.10) && maximum(abs.(xu .- θu)) > 0.099
        @test abs(std(xu .- θu) - 0.10 / sqrt(3)) < 0.003
    end
    mn = load_model(:In)
    for s2 in (11, 12, 13)
        θn, xn = Base.invokelatest(mn.episodeThetaDraws, s2, 4_000)
        @test θn == first(Base.invokelatest(m.episodeThetaDraws, s2, 4_000))
        @test maximum(abs.(xn .- θn)) > 0.25                 # normal: tails beyond 2.5 s.d.
    end
    @test Base.invokelatest(mn.thetaNoiseVar, 0.3) ≈ 0.09
    # parsing
    withenv("BANKRUN_THETA_NOISE_DIST" => "uniform") do
        @test m.parseSwitchesFromEnv().THETA_NOISE_DIST == "uniform"
    end
    withenv("BANKRUN_THETA_NOISE_DIST" => "laplace") do
        @test_throws ErrorException m.parseSwitchesFromEnv()
    end
end
