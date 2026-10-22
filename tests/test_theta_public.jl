################################################################################
# test_theta_public.jl  (added 2026-10-22)
#
# Run from the repo root, under the pinned Julia (see tests/run_tests.sh):
#     julia --project=. tests/test_theta_public.jl
#
# The public signal of θ (BANKRUN_THETA_PUBLIC, Chapter 1's y) and the scope of
# λ (BANKRUN_LAMBDA_SCOPE). The defaults are covered by test_switch_identity.jl.
# Here:
#   A. thetaBelief and thetaPublicAt on hand-computed cases: no y is the
#      private posterior exactly; stale y ignores θ; tracks moves with it; ρ
#      decays the gap.
#   B. anticipatedWithdrawals: the λ keyword defaults to the agent's own λ.
#   C. Plumbing identity: with every agent at the same λ, λ̄ = λ, so
#      LAMBDA_SCOPE = theta / both reproduce count run for run.
#   D. Paired arms and logs: the public signal changes beliefs only (θ, shock,
#      balance sheet run for run); the params and per-run rows are right.
#   E. Refused combinations.
#   F. Smoke property: an optimistic stale y keeps more depositors in than a
#      pessimistic one, and moves the high-λ (collectivist) agents more.
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

# A fire-sale model as modelGen builds it; λs = (λ_I, λ_C) for a third / two thirds.
function build(m::Module, seed::Int; n::Int=60, reserve::Float64=0.05, λs=(0.2, 0.8))
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, 1.0), n)
    lam = [i <= n ÷ 3 ? λs[1] : λs[2] for i in 1:n]
    agents = [m.Agent(i, deposits[i], true, lam[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    bank.illiquid = (1.0 - reserve + Base.invokelatest(m.switchValue, :EQUITY)) * sum(deposits)
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, 0.0, seed, seed,
                   LogNormal(1.0, 1.0), net, 0.1, truncated(Geometric(0.2), 0, n))
end
readlog(m, f, cols) = (p = joinpath(m.dataDir, f); isfile(p) ? CSV.read(p, DataFrame; header=cols) : nothing)
const BALANCE_COLS = [:key, :theta, :returnTheta, :vaultInit, :illiquidInit, :vaultFinal, :illiquidFinal,
                      :assetsT, :promises, :solvent, :failType, :largestShare, :largestToCapacity,
                      :largestWithdrew]
const TP_COLS = [:key, :theta, :y1, :gap1, :lambdaBar]
const TPP_COLS = [:key, :thetaPublic, :level, :gap, :rho, :noise, :lambdaScope]
const FIRE = (BALANCE="firesale", PAYOFF="recovery", STAY_RETURN=1.1, FUNDAMENTAL="theta",
              PRIVATE_SIGNAL="theta", THETA_NOISE=0.10, FIRE_DISCOUNT=0.6, EQUITY=0.06,
              RETURN_LO=1.0, RETURN_HI=1.4, FRESH_CLONE=true)

# Runs `n_seeds` banks; returns the module, the results and the models after the run.
function arm(name; n_seeds=20, λs=(0.2, 0.8), kw...)
    m = load_model(name)
    setsw!(m; FIRE..., kw...)
    mods = Base.invokelatest(() -> [build(m, s; λs=λs) for s in 1:n_seeds])
    res = Base.invokelatest(() -> [m.modelRun(mod) for mod in mods])
    return m, res, mods
end
endogLog(m) = CSV.read(joinpath(m.dataDir, "bankRunEndogenous1.csv"), DataFrame; header=false)

# ---------------------------------------------------------------- A
@testset "A. thetaBelief and thetaPublicAt" begin
    m = load_model(:A)
    tb(args...) = Base.invokelatest(m.thetaBelief, args...)
    ty(args...; kw...) = Base.invokelatest(m.thetaPublicAt, args...; kw...)
    @test tb(0.4, 0.1, nothing, 0.7, 0.3) == truncated(Normal(0.4, 0.1), 0.0, 1.0)
    @test tb(0.4, 0.1, 0.9, 0.0, 0.3) == truncated(Normal(0.4, 0.1), 0.0, 1.0)   # ω = 0: y ignored
    d = tb(0.2, 0.1, 0.8, 0.25, 0.3)
    @test d.untruncated.μ ≈ 0.75 * 0.2 + 0.25 * 0.8
    @test d.untruncated.σ ≈ 0.75 * 0.1 + 0.25 * 0.3
    d1 = tb(0.2, 0.1, 0.8, 1.0, 0.3)
    @test d1.untruncated.μ ≈ 0.8 && d1.untruncated.σ ≈ 0.3

    # stale: y₀ whatever θ is, while ρ = 1
    for θ in (0.0, 0.3, 0.95), t in (1, 2, 7)
        @test ty("stale", θ, t; level=0.6, gap=0.0, rho=1.0) == 0.6
    end
    # stale with ρ < 1: the gap y₀ − θ decays geometrically
    @test ty("stale", 0.2, 1; level=0.6, gap=0.0, rho=0.5) ≈ 0.6
    @test ty("stale", 0.2, 2; level=0.6, gap=0.0, rho=0.5) ≈ 0.4
    @test ty("stale", 0.2, 3; level=0.6, gap=0.0, rho=0.5) ≈ 0.3
    @test ty("stale", 0.2, 2; level=0.6, gap=0.0, rho=0.0) ≈ 0.2           # corrects at once
    # tracks: θ + δ, clamped to [0, 1]
    @test ty("tracks", 0.3, 1; level=0.6, gap=0.2, rho=1.0) ≈ 0.5
    @test ty("tracks", 0.7, 4; level=0.6, gap=0.2, rho=1.0) ≈ 0.9
    @test ty("tracks", 0.9, 1; level=0.6, gap=0.2, rho=1.0) == 1.0
    @test ty("tracks", 0.1, 1; level=0.6, gap=-0.3, rho=1.0) == 0.0
end

# ---------------------------------------------------------------- B
@testset "B. the head-count weight" begin
    m = load_model(:B)
    agt = m.Agent(1, 3.0, true, 0.7)
    draws = [0, 5, 12, 40]
    aw(; kw...) = Base.invokelatest(m.anticipatedWithdrawals, agt, draws, 20, 0, 3, 60, 1;
                                    pubAlpha=0.0, weightPhi=1.0, kw...)
    @test aw() == aw(λ=0.7)
    @test aw(λ=0.0) == max.(0, draws .- 3)
    @test aw(λ=1.0) == fill(17, 4)
end

# ---------------------------------------------------------------- C
@testset "C. one λ for everyone: the scopes coincide" begin
    _, rc, _ = arm(:Cc; λs=(0.5, 0.5), THETA_PUBLIC="stale", LAMBDA_SCOPE="count")
    for scope in ("theta", "both")
        ms, rs, _ = arm(Symbol(:C, scope); λs=(0.5, 0.5), THETA_PUBLIC="stale", LAMBDA_SCOPE=scope)
        @test rs == rc
    end
    # and with no public signal, scope theta (head counts at λ̄) is count exactly
    m0, r0, _ = arm(:C0; λs=(0.5, 0.5))
    m1, r1, _ = arm(:C1; λs=(0.5, 0.5), LAMBDA_SCOPE="theta")
    @test r1 == r0
    @test endogLog(m1) == endogLog(m0)
end

# ---------------------------------------------------------------- D
@testset "D. paired arms and logs" begin
    m0, _, _ = arm(:D0)
    ms, _, mods = arm(:Ds; THETA_PUBLIC="stale", THETA_PUBLIC_LEVEL=0.8, LAMBDA_SCOPE="both")
    b0 = readlog(m0, "bankRunBalance1.csv", BALANCE_COLS)
    bs = readlog(ms, "bankRunBalance1.csv", BALANCE_COLS)
    @test bs.theta == b0.theta
    @test bs.vaultInit == b0.vaultInit && bs.illiquidInit == b0.illiquidInit
    ex(mm) = CSV.read(joinpath(mm.dataDir, "bankRunExogenous1.csv"), DataFrame; header=false)
    @test ex(ms) == ex(m0)
    @test !isfile(joinpath(m0.dataDir, "bankRunThetaPublicParams1.csv"))
    @test !isfile(joinpath(m0.dataDir, "bankRunThetaPublic1.csv"))

    pp = readlog(ms, "bankRunThetaPublicParams1.csv", TPP_COLS)
    @test nrow(pp) == 20 && all(pp.thetaPublic .== "stale") && all(pp.level .== 0.8)
    @test all(pp.lambdaScope .== "both")
    tp = readlog(ms, "bankRunThetaPublic1.csv", TP_COLS)
    @test nrow(tp) == 20 && tp.theta == bs.theta
    @test all(tp.y1 .== 0.8) && tp.gap1 ≈ 0.8 .- tp.theta
    @test all(tp.lambdaBar .≈ (20 * 0.2 + 40 * 0.8) / 60)

    mt, _, _ = arm(:Dt; THETA_PUBLIC="tracks", THETA_PUBLIC_GAP=0.15)
    tt = readlog(mt, "bankRunThetaPublic1.csv", TP_COLS)
    @test tt.y1 ≈ clamp.(tt.theta .+ 0.15, 0.0, 1.0)

    # scope alone, no public signal: params written, y1 NaN
    ml, _, _ = arm(:Dl; LAMBDA_SCOPE="theta", n_seeds=3)
    tl = readlog(ml, "bankRunThetaPublic1.csv", TP_COLS)
    @test nrow(tl) == 3 && all(isnan, tl.y1)
end

# ---------------------------------------------------------------- E
@testset "E. refused combinations" begin
    m = load_model(:E)
    D = m.SWITCH_DEFAULTS
    err(; kw...) = m.switchComboError(merge(D, (; kw...)))
    base = (BALANCE="firesale", PAYOFF="recovery", FUNDAMENTAL="theta")
    @test err(; base..., THETA_PUBLIC="stale") !== nothing                  # no private θ signal
    @test err(; base..., THETA_PUBLIC="stale", PRIVATE_SIGNAL="theta") === nothing
    @test err(; base..., LAMBDA_SCOPE="both") === nothing
    withenv("BANKRUN_THETA_PUBLIC" => "stale") do
        @test_throws ErrorException m.parseSwitchesFromEnv()
    end
    withenv("BANKRUN_THETA_PUBLIC_GAP" => "1.5") do
        @test_throws ErrorException m.parseSwitchesFromEnv()
    end
    withenv("BANKRUN_BALANCE" => "firesale", "BANKRUN_PAYOFF" => "recovery",
            "BANKRUN_FUNDAMENTAL" => "theta", "BANKRUN_PRIVATE_SIGNAL" => "theta",
            "BANKRUN_THETA_PUBLIC" => "tracks", "BANKRUN_THETA_PUBLIC_GAP" => "-0.2",
            "BANKRUN_LAMBDA_SCOPE" => "both") do
        sw = m.parseSwitchesFromEnv()
        @test sw.THETA_PUBLIC == "tracks" && sw.THETA_PUBLIC_GAP == -0.2 && sw.LAMBDA_SCOPE == "both"
    end
    mm = load_model(:Eg)
    setsw!(mm; base..., THETA_PUBLIC="stale")
    @test_throws ErrorException Base.invokelatest(() -> mm.modelRun(build(mm, 1)))
end

# ---------------------------------------------------------------- F
@testset "F. optimistic vs pessimistic stale y" begin
    # Withdrawal rate by type (λ 0.2 = I, the first third; λ 0.8 = C), over runs.
    function rates(mods)
        wI = mean(mean(!a.banked for a in mod.agtList[1:20]) for mod in mods)
        wC = mean(mean(!a.banked for a in mod.agtList[21:60]) for mod in mods)
        return wI, wC
    end
    _, _, hi = arm(:Fh; n_seeds=40, THETA_PUBLIC="stale", THETA_PUBLIC_LEVEL=0.95, LAMBDA_SCOPE="both")
    _, _, lo = arm(:Fl; n_seeds=40, THETA_PUBLIC="stale", THETA_PUBLIC_LEVEL=0.05, LAMBDA_SCOPE="both")
    hiI, hiC = rates(hi)
    loI, loC = rates(lo)
    @test hiI + hiC < loI + loC               # reassurance keeps depositors in
    @test (loC - hiC) > (loI - hiI)           # and moves the collectivists more
end

# ---------------------------------------------------------------- G
@testset "G. seeding switches parse" begin
    m = load_model(:G)
    withenv("BANKRUN_N_INIT" => "7") do
        @test_throws ErrorException m.parseSwitchesFromEnv()
    end
    withenv("BANKRUN_SEEDING" => "common", "BANKRUN_N_INIT" => "25") do
        sw = m.parseSwitchesFromEnv()
        @test sw.SEEDING == "common" && sw.N_INIT == 25
    end
end
