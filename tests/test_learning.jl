# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_learning.jl
#
# L2 Rule A, precision learning of the θ weight, BANKRUN_LEARN (2026-10-28;
# docs/learning_design.md §4).
#   A. LEARN = precision with κ = 0 is the no-learning model: every per-run file and
#      the episode rows (but the squared errors) are identical.
#   B. Episode 1 is the no-learning model whatever κ (the agents have no experience yet).
#   C. The learner, replayed by hand from θ, x_i and y (episodeThetaDraws,
#      publicAtStart), gives the θ weights the episode rows report, episode by
#      episode; the cultural λ never moves; with κ > 0 the weights do.
#   D. learnUpdate! arithmetic, and κ = 1 ignores culture.
#   E. The refused combinations.
# The reference bank with a stale public signal (r1k-stale-y50), N = 1000, small MC depth.

using Test
using CSV, DataFrames, Distributions, Random, Statistics

include(joinpath(@__DIR__, "..", "scripts", "replay_run.jl"))   # loadCell, defines ROOT

const GEN_SEED = 1017
const DEPTH = 10
const CELL = ["0.05", "0.0", "LogNormal", "1.0", "2.5", "6", "0.05", "0.1", "0.5", "0.1", "0.9"]
const SW = (FRESH_CLONE = true, LOG = "summary", BALANCE = "firesale", PAYOFF = "recovery",
            FUNDAMENTAL = "theta", FIRE_DISCOUNT = 0.6, EQUITY = 0.06, RETURN_LO = 1.0,
            RETURN_HI = 1.4, STAY_RETURN = 1.1, PRIVATE_SIGNAL = "theta", THETA_NOISE = 0.10,
            THETA_PUBLIC_NOISE = 0.10, THETA_PUBLIC = "stale", THETA_PUBLIC_LEVEL = 0.5,
            LAMBDA_SCOPE = "both", WITHDRAW = "partial", CARA = 0.1, DEPOSIT_CAP = 0.01)
const ROWS = 1:3
const E = 4
# bankRunEpisodes columns: key type episode seed2 theta failed n nExog nEndog depTotal
# depEndog lambdaMean lambdaSd weightMean weightSd msexMean mseyMean
const C_EPISODE, C_LAMBDA, C_WEIGHT, C_MSEX = 3, 12, 14, 16
# bankRunEpisodes columns 19-20 (late 2026-10-30): learnedMean learnedSd, the learned weight w* alone
const C_LEARNED, C_LEARNED_SD = 19, 20

const STAMP = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?"
outputs(dir) = Dict(f => replace(read(joinpath(dir, f), String), STAMP => "T")
                    for f in readdir(dir) if occursin(r"^bankRun[A-Za-z]+\d+\.csv$", f))
episodes(dir) = CSV.read(joinpath(dir, only(filter(f -> startswith(f, "bankRunEpisodes"), readdir(dir)))),
                         DataFrame; header=false)

function arm(sw)
    d = mktempdir()
    m = loadCell(d, [d, string(GEN_SEED), CELL...]; switches=sw, depth=DEPTH)
    for i in ROWS
        Base.invokelatest(m.runRow, m.jointFrame[i, :])
    end
    return m, d
end

m0, d0 = arm(merge(SW, (EPISODES = E,)))
ep0 = episodes(d0)

@testset "A. κ = 0 is the no-learning model" begin
    _, d = arm(merge(SW, (EPISODES = E, LEARN = "precision", LEARN_GRIP = 0.0)))
    o0, o = outputs(d0), outputs(d)
    per_run = filter(f -> !startswith(f, "bankRunEpisodes"), collect(keys(o0)))
    @test sort(collect(keys(o0))) == sort(collect(keys(o)))
    @test all(o0[f] == o[f] for f in per_run)
    ep = episodes(d)
    @test Matrix(ep[:, 2:C_MSEX-1]) == Matrix(ep0[:, 2:C_MSEX-1])      # col 1: keys carry build stamps
    @test all(isnan, ep0[:, C_MSEX]) && !any(isnan, ep[:, C_MSEX])
end

mk, dk = arm(merge(SW, (EPISODES = E, LEARN = "precision", LEARN_GRIP = 0.5, LEARN_MEMORY = 0.2)))
epk = episodes(dk)

@testset "B. episode 1 is the no-learning model" begin
    one(ep) = Matrix(ep[ep[:, C_EPISODE] .== 1, 2:C_MSEX-1])
    @test one(epk) == one(ep0)
end

@testset "C. the learner replayed by hand" begin
    for i in ROWS
        row = mk.jointFrame[i, :]
        mod, isI = Base.invokelatest(mk.modelGenTyped, row[:key], row[:seed1], row[:seed2],
                                     nv(row[:network]), .1, row[:network], row[:depositDist],
                                     row[:reserveRatio], row[:depositInsuranceQuantile],
                                     row[:withdrawRV], row[:warmupAlpha], row[:fracIndividualists],
                                     row[:lambdaI], row[:lambdaC])
        L = Base.invokelatest(mk.LearnState, mod)
        n = length(mod.agtList)
        rows_i = epk[endswith.(epk[:, 1], "-$(row[:seed1])-$(row[:seed2])"), :]
        for e in 1:E
            s2 = mk.episodeSeed(row[:seed2], e)
            for (t, sel) in (("I", isI), ("C", .!isI))
                r = rows_i[(rows_i[:, C_EPISODE] .== e) .& (rows_i[:, 2] .== t), :]
                @test nrow(r) == 1
                @test r[1, C_WEIGHT] ≈ mean(L.weight[sel])
                @test r[1, C_LAMBDA] ≈ mean(L.culture[sel])
            end
            θ, x = Base.invokelatest(mk.episodeThetaDraws, s2, n)
            Base.invokelatest(mk.learnUpdate!, L, x, θ, Base.invokelatest(mk.publicAtStart, θ);
                              grip=0.5, memory=0.2)
        end
    end
    # the cultural λ is constant; the θ weight moves after episode 1
    for (k, g) in pairs(groupby(epk, [:Column1, :Column2]))
        @test length(unique(g[:, C_LAMBDA])) == 1
        @test any(g[g[:, C_EPISODE] .> 1, C_WEIGHT] .!= g[1, C_LAMBDA])
    end
end

@testset "D. learnUpdate!" begin
    L = mk.LearnState([0.2, 0.8], [0.01, 0.01], [0.01, 0.01], [0.2, 0.8])
    mk.learnUpdate!(L, [0.6, 0.6], 0.5, 0.9; grip=1.0, memory=0.5)
    @test L.msex ≈ [0.5 * 0.01 + 0.5 * 0.01, 0.5 * 0.01 + 0.5 * 0.01]
    @test L.msey ≈ [0.5 * 0.01 + 0.5 * 0.16, 0.5 * 0.01 + 0.5 * 0.16]
    @test L.weight[1] ≈ L.weight[2] ≈ 0.01 / (0.01 + 0.085)        # κ = 1: culture gone
    L2 = mk.LearnState([0.2, 0.8], [0.01, 0.01], [0.01, 0.01], [0.2, 0.8])
    mk.learnUpdate!(L2, [0.6, 0.6], 0.5, 0.9; grip=0.25, memory=0.5)
    @test L2.weight ≈ 0.75 .* [0.2, 0.8] .+ 0.25 * 0.01 / (0.01 + 0.085)
end

@testset "E. refused combinations" begin
    base = Dict("BANKRUN_BALANCE" => "firesale", "BANKRUN_PAYOFF" => "recovery",
                "BANKRUN_FUNDAMENTAL" => "theta", "BANKRUN_PRIVATE_SIGNAL" => "theta",
                "BANKRUN_THETA_PUBLIC" => "stale", "BANKRUN_LAMBDA_SCOPE" => "both",
                "BANKRUN_LEARN" => "precision", "BANKRUN_LEARN_GRIP" => "0.5")
    parse_with(d) = withenv(d...) do
        Base.invokelatest(mk.parseSwitchesFromEnv)
    end
    @test parse_with(base).LEARN == "precision"
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_THETA_PUBLIC" => "none")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LAMBDA_SCOPE" => "count")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN" => "none")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN_GRIP" => "1.5")))
end

@testset "E. the learned-weight columns: weight = (1 − κ)·λ + κ·ω* by type" begin
    @test all(isnan, ep0[:, C_LEARNED]) && all(isnan, ep0[:, C_LEARNED_SD])     # no learning
    @test all(isapprox.(epk[:, C_WEIGHT], (1 - 0.5) .* epk[:, C_LAMBDA] .+ 0.5 .* epk[:, C_LEARNED]; atol=1e-12))
    @test epk[epk[:, C_EPISODE] .== 1, C_LEARNED] == epk[epk[:, C_EPISODE] .== 1, C_LAMBDA]     # ω* starts at λ
    @test !any(isnan, epk[:, C_LEARNED_SD])
end
