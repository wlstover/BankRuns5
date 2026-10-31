# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_payoff_learning.jl
#
# L2 Rule B, payoff learning of the θ weight by the signal-direction rule,
# BANKRUN_LEARN = payoff (2026-10-29; docs/learning_design.md §4).
#   A. LEARN = payoff with κ = 0 is the no-learning model: every per-run file and
#      the episode rows are identical.
#   B. Episode 1 is the no-learning model whatever κ.
#   C. The learner, replayed by hand from θ, x_i, y and each episode's end-of-run
#      balance (the last-episode bankRunBalance row of runs with E = 1..4, which
#      share their early episodes), gives the θ weights the episode rows report.
#   D. payoffUpdate! and stayValue arithmetic, insurance included.
#   E. Insurance changes what Rule B learns (Rule A cannot see it): the θ weights
#      under q 0.99 differ from q 0 on the same populations and draws.
#   F. The refused combinations.
# The reference bank with a stale public signal (r1k-stale-y50), N = 1000, small MC depth.

using Test
using CSV, DataFrames, Distributions, Random, Statistics

include(joinpath(@__DIR__, "..", "scripts", "replay_run.jl"))   # loadCell, defines ROOT

const GEN_SEED = 1017
const DEPTH = 10
const CELL = ["0.05", "0.0", "LogNormal", "1.0", "2.5", "6", "0.05", "0.1", "0.5", "0.1", "0.9"]
const CELL_INS = ["0.05", "0.99", "LogNormal", "1.0", "2.5", "6", "0.05", "0.1", "0.5", "0.1", "0.9"]
const SW = (FRESH_CLONE = true, LOG = "summary", BALANCE = "firesale", PAYOFF = "recovery",
            FUNDAMENTAL = "theta", FIRE_DISCOUNT = 0.6, EQUITY = 0.06, RETURN_LO = 1.0,
            RETURN_HI = 1.4, STAY_RETURN = 1.1, PRIVATE_SIGNAL = "theta", THETA_NOISE = 0.10,
            THETA_PUBLIC_NOISE = 0.10, THETA_PUBLIC = "stale", THETA_PUBLIC_LEVEL = 0.5,
            LAMBDA_SCOPE = "both", WITHDRAW = "partial", CARA = 0.1, DEPOSIT_CAP = 0.01)
const ROWS = 1:3
const E = 4
const GRIP, MEMORY, R = 0.5, 0.2, 1.1
# bankRunEpisodes columns: key type episode seed2 theta failed n nExog nEndog depTotal
# depEndog lambdaMean lambdaSd weightMean weightSd msexMean mseyMean
const C_EPISODE, C_LAMBDA, C_WEIGHT, C_MSEX = 3, 12, 14, 16
# bankRunEpisodes columns 19-20 (late 2026-10-30): learnedMean learnedSd, the learned weight w* alone
const C_LEARNED, C_LEARNED_SD = 19, 20
# bankRunBalance columns: key theta returnTheta vaultInit illiquidInit vaultFinal
# illiquidFinal assetsT promises solvent failType ...
const B_ASSETS, B_PROMISES, B_FAILTYPE = 8, 9, 11

const STAMP = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?"
outputs(dir) = Dict(f => replace(read(joinpath(dir, f), String), STAMP => "T")
                    for f in readdir(dir) if occursin(r"^bankRun[A-Za-z]+\d+\.csv$", f))
readOut(dir, stem) = CSV.read(joinpath(dir, only(filter(f -> occursin(Regex("^$(stem)\\d+\\.csv\$"), f), readdir(dir)))),
                              DataFrame; header=false)
episodes(dir) = readOut(dir, "bankRunEpisodes")
runkey(seed1, seed2) = "-$(seed1)-$(seed2)"

function arm(sw; cell=CELL)
    d = mktempdir()
    m = loadCell(d, [d, string(GEN_SEED), cell...]; switches=sw, depth=DEPTH)
    for i in ROWS
        Base.invokelatest(m.runRow, m.jointFrame[i, :])
    end
    return m, d
end

PAY = merge(SW, (LEARN = "payoff", LEARN_GRIP = GRIP, LEARN_MEMORY = MEMORY))

m0, d0 = arm(merge(SW, (EPISODES = E,)))
ep0 = episodes(d0)

@testset "A. κ = 0 is the no-learning model" begin
    _, d = arm(merge(SW, (EPISODES = E, LEARN = "payoff", LEARN_GRIP = 0.0)))
    o0, o = outputs(d0), outputs(d)
    per_run = filter(f -> !startswith(f, "bankRunEpisodes"), collect(keys(o0)))
    @test sort(collect(keys(o0))) == sort(collect(keys(o)))
    @test all(o0[f] == o[f] for f in per_run)
    ep = episodes(d)
    @test Matrix(ep[:, 2:C_MSEX-1]) == Matrix(ep0[:, 2:C_MSEX-1])      # col 1: keys carry build stamps
    @test all(isnan, ep[:, C_MSEX])                                     # Rule B keeps no squared errors
end

# Runs with E = 1..4 share their early episodes, so the last-episode balance row of
# the E = e run is episode e's end-of-run state in the E = 4 run.
arms_e = [arm(merge(PAY, (EPISODES = e,))) for e in 1:E]
mk, dk = arms_e[E]
epk = episodes(dk)

@testset "B. episode 1 is the no-learning model" begin
    one(ep) = Matrix(ep[ep[:, C_EPISODE] .== 1, 2:C_MSEX-1])
    @test one(epk) == one(ep0)
end

@testset "C. the learner replayed by hand" begin
    bal = [readOut(d, "bankRunBalance") for (_, d) in arms_e]
    moved = false
    for i in ROWS
        row = mk.jointFrame[i, :]
        mod, isI = Base.invokelatest(mk.modelGenTyped, row[:key], row[:seed1], row[:seed2],
                                     nv(row[:network]), .1, row[:network], row[:depositDist],
                                     row[:reserveRatio], row[:depositInsuranceQuantile],
                                     row[:withdrawRV], row[:warmupAlpha], row[:fracIndividualists],
                                     row[:lambdaI], row[:lambdaC])
        λ = [a.individualism for a in mod.agtList]
        deps = [a.deposit for a in mod.agtList]
        cap = quantile(mod.depositDistribution, mod.depositInsurance)
        n = length(λ)
        learned = copy(λ)
        weight = copy(λ)
        k = runkey(row[:seed1], row[:seed2])
        rows_i = epk[endswith.(epk[:, 1], k), :]
        for e in 1:E
            s2 = mk.episodeSeed(row[:seed2], e)
            for (t, sel) in (("I", isI), ("C", .!isI))
                r = rows_i[(rows_i[:, C_EPISODE] .== e) .& (rows_i[:, 2] .== t), :]
                @test nrow(r) == 1
                @test r[1, C_WEIGHT] ≈ mean(weight[sel])
                @test r[1, C_LAMBDA] ≈ mean(λ[sel])
            end
            b = bal[e][endswith.(bal[e][:, 1], k), :]
            @test nrow(b) == 1
            assets = b[1, B_FAILTYPE] == "liquidity" ? 0.0 : b[1, B_ASSETS]
            θ, x = Base.invokelatest(mk.episodeThetaDraws, s2, n)
            y = Base.invokelatest(mk.publicAtStart, θ)
            for j in 1:n
                # stayerPayoff with the end-of-run assets as cash: the stayer's per-unit pay
                stay = mk.stayerPayoff(assets, 0.0, 1.0, b[1, B_PROMISES], deps[j], cap, R) / deps[j]
                stay == 1.0 && continue
                y == x[j] && continue
                trustY = (stay > 1.0) == (y > x[j])        # y was the more optimistic / pessimistic one
                learned[j] = (1 - MEMORY) * learned[j] + MEMORY * (trustY ? 1.0 : 0.0)
            end
            weight = (1 - GRIP) .* λ .+ GRIP .* learned
            moved |= any(weight .!= λ)
        end
    end
    @test moved
    for (k, g) in pairs(groupby(epk, [:Column1, :Column2]))
        @test length(unique(g[:, C_LAMBDA])) == 1                     # the cultural λ never moves
    end
end

@testset "D. payoffUpdate! and stayValue" begin
    # solvent bank: staying pays R; bank at ρ = 0.5, no insurance: ρR = 0.55; insured: the larger of ρR and the insured share
    @test mk.stayValue(2.0, [1.0, 4.0], 0.0, 1.1) ≈ [1.1, 1.1]
    @test mk.stayValue(0.5, [1.0, 4.0], 0.0, 1.1) ≈ [0.55, 0.55]
    @test mk.stayValue(0.5, [1.0, 4.0], 2.0, 1.1) ≈ [1.0, 0.55]     # 4 > cap: recovery beats the insured half
    @test mk.stayValue(Inf, [1.0], 0.0, 1.1) ≈ [1.1]
    # four cases: staying paid (agents 1, 2) or withdrawing did (3, 4); y above x (1, 3) or below (2, 4)
    L = mk.LearnState([0.5, 0.5, 0.5, 0.5, 0.5, 0.5], zeros(6), zeros(6), fill(0.5, 6))
    mk.payoffUpdate!(L, [0.3, 0.7, 0.3, 0.7, 0.3, 0.5], 0.5, [1.1, 1.1, 0.4, 0.4, 1.0, 1.1];
                     grip=1.0, memory=0.5)
    @test L.learned ≈ [0.75, 0.25, 0.25, 0.75, 0.5, 0.5]   # 5: payoff tie; 6: signals tie
    @test L.weight ≈ L.learned                              # κ = 1: culture gone
    L2 = mk.LearnState([0.2, 0.8], zeros(2), zeros(2), [0.2, 0.8])
    mk.payoffUpdate!(L2, [0.3, 0.3], 0.5, [1.1, 1.1]; grip=0.25, memory=0.5)
    @test L2.learned ≈ [0.6, 0.9]
    @test L2.weight ≈ 0.75 .* [0.2, 0.8] .+ 0.25 .* [0.6, 0.9]
end

@testset "E. insurance changes what Rule B learns" begin
    _, di = arm(merge(PAY, (EPISODES = E,)); cell=CELL_INS)
    epi = episodes(di)
    seeds(key) = join(split(key, "-")[end-1:end], "-")       # keys carry build stamps
    sk(ep) = sort(DataFrame(k=seeds.(ep[:, 1]), t=ep[:, 2], e=ep[:, C_EPISODE],
                            w=ep[:, C_WEIGHT], th=ep[:, 5]), [:k, :t, :e])
    a, b = sk(epk), sk(epi)
    @test a.k == b.k && a.th == b.th                   # same populations and draws
    @test b.w[b.e .== 1] == a.w[a.e .== 1]             # episode 1: culture in both
    @test any(b.w[b.e .> 1] .!= a.w[a.e .> 1])         # later: insurance moved the weights
end

@testset "F. refused combinations" begin
    base = Dict("BANKRUN_BALANCE" => "firesale", "BANKRUN_PAYOFF" => "recovery",
                "BANKRUN_FUNDAMENTAL" => "theta", "BANKRUN_PRIVATE_SIGNAL" => "theta",
                "BANKRUN_THETA_PUBLIC" => "stale", "BANKRUN_LAMBDA_SCOPE" => "both",
                "BANKRUN_LEARN" => "payoff", "BANKRUN_LEARN_GRIP" => "0.5")
    parse_with(d) = withenv(d...) do
        Base.invokelatest(mk.parseSwitchesFromEnv)
    end
    @test parse_with(base).LEARN == "payoff"
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_THETA_PUBLIC" => "none")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LAMBDA_SCOPE" => "count")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN" => "none")))
end

@testset "E. the learned-weight columns: weight = (1 − κ)·λ + κ·ω* by type" begin
    @test all(isnan, ep0[:, C_LEARNED]) && all(isnan, ep0[:, C_LEARNED_SD])     # no learning
    @test all(isapprox.(epk[:, C_WEIGHT], (1 - GRIP) .* epk[:, C_LAMBDA] .+ GRIP .* epk[:, C_LEARNED]; atol=1e-12))
    @test epk[epk[:, C_EPISODE] .== 1, C_LEARNED] == epk[epk[:, C_EPISODE] .== 1, C_LAMBDA]     # ω* starts at λ
    @test !any(isnan, epk[:, C_LEARNED_SD])
end
