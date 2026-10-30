# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_learn_init.jl
#
# Where the learned weight ω* starts, BANKRUN_LEARN_INIT (2026-10-30; robustness only,
# docs/learning_design.md §11 decision 10).
#   A. LEARN_INIT = culture, set explicitly, is the default model file for file.
#   B. uniform: episode 1's θ weights are (1 − κ)·λ + κ·u with u ~ U(0, 1) from the
#      population's own stream, the same draws under every rule (common seeding).
#   C. uniform changes the run from episode 1; Rule B moves on from the draws.
#   D. The refused combinations.
# The reference bank with a stale public signal (r1k-stale-y50), N = 1000, small MC depth.

using Test
using CSV, DataFrames, Distributions, Graphs, Random, Statistics

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
const E = 3
const GRIP, MEMORY = 0.5, 0.2
# bankRunEpisodes columns: key type episode seed2 theta failed n nExog nEndog depTotal
# depEndog lambdaMean lambdaSd weightMean weightSd msexMean mseyMean nJoined
const C_EPISODE, C_WEIGHT = 3, 14

const STAMP = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?"
outputs(dir) = Dict(f => replace(read(joinpath(dir, f), String), STAMP => "T")
                    for f in readdir(dir) if occursin(r"^bankRun[A-Za-z]+\d+\.csv$", f))
episodes(dir) = CSV.read(joinpath(dir, only(filter(f -> occursin(r"^bankRunEpisodes\d+\.csv$", f), readdir(dir)))),
                         DataFrame; header=false)
runkey(seed1, seed2) = "-$(seed1)-$(seed2)"

function arm(sw)
    d = mktempdir()
    m = loadCell(d, [d, string(GEN_SEED), CELL...]; switches=sw, depth=DEPTH)
    for i in ROWS
        Base.invokelatest(m.runRow, m.jointFrame[i, :])
    end
    return m, d
end

learnSw(rule, init) = merge(SW, (EPISODES = E, LEARN = rule, LEARN_GRIP = GRIP,
                                 LEARN_MEMORY = MEMORY, LEARN_INIT = init))

@testset "A. culture, set explicitly, is the default" begin
    _, da = arm(merge(SW, (EPISODES = E, LEARN = "payoff", LEARN_GRIP = GRIP, LEARN_MEMORY = MEMORY)))
    _, db = arm(learnSw("payoff", "culture"))
    oa, ob = outputs(da), outputs(db)
    @test sort(collect(keys(oa))) == sort(collect(keys(ob)))
    per_run = filter(f -> !startswith(f, "bankRunEpisodes"), collect(keys(oa)))
    @test all(oa[f] == ob[f] for f in per_run)
    @test isequal(Matrix(episodes(da)[:, 2:end]), Matrix(episodes(db)[:, 2:end]))
end

arms = Dict((r, i) => arm(learnSw(r, i)) for r in ("payoff", "imitate") for i in ("culture", "uniform"))
eps = Dict(k => episodes(d) for (k, (_, d)) in arms)

@testset "B. episode 1 weights from the population's draws" begin
    mk, _ = arms[("payoff", "uniform")]
    for i in ROWS
        row = mk.jointFrame[i, :]
        mod, isI = Base.invokelatest(mk.modelGenTyped, row[:key], row[:seed1], row[:seed2],
                                     nv(row[:network]), .1, row[:network], row[:depositDist],
                                     row[:reserveRatio], row[:depositInsuranceQuantile],
                                     row[:withdrawRV], row[:warmupAlpha], row[:fracIndividualists],
                                     row[:lambdaI], row[:lambdaC])
        λ = [a.individualism for a in mod.agtList]
        u = rand(MersenneTwister(xor(reinterpret(UInt64, row[:seed1]), 0xbb67ae8584caa73b)), length(λ))
        w = (1 - GRIP) .* λ .+ GRIP .* u
        for rule in ("payoff", "imitate")
            ep = eps[(rule, "uniform")]
            r = ep[endswith.(ep[:, 1], runkey(row[:seed1], row[:seed2])) .& (ep[:, C_EPISODE] .== 1), :]
            for (t, sel) in (("I", isI), ("C", .!isI))
                @test only(r[r[:, 2] .== t, C_WEIGHT]) ≈ mean(w[sel])
            end
        end
    end
end

@testset "C. uniform changes the run from episode 1" begin
    for rule in ("payoff", "imitate")
        c, u = eps[(rule, "culture")], eps[(rule, "uniform")]
        @test c[:, 5] == u[:, 5]                                       # same θ draws
        @test any(c[c[:, C_EPISODE] .== 1, C_WEIGHT] .!= u[u[:, C_EPISODE] .== 1, C_WEIGHT])
    end
    p, q = eps[("payoff", "uniform")], eps[("imitate", "uniform")]
    @test p[p[:, C_EPISODE] .== 1, C_WEIGHT] ≈ q[q[:, C_EPISODE] .== 1, C_WEIGHT]   # same start
    @test any(p[p[:, C_EPISODE] .> 1, C_WEIGHT] .!= q[q[:, C_EPISODE] .> 1, C_WEIGHT])
end

@testset "D. refused combinations" begin
    mk, _ = arms[("payoff", "uniform")]
    parse_with(d) = withenv(d...) do
        Base.invokelatest(mk.parseSwitchesFromEnv)
    end
    base = Dict("BANKRUN_BALANCE" => "firesale", "BANKRUN_PAYOFF" => "recovery",
                "BANKRUN_FUNDAMENTAL" => "theta", "BANKRUN_PRIVATE_SIGNAL" => "theta",
                "BANKRUN_THETA_PUBLIC" => "stale", "BANKRUN_LAMBDA_SCOPE" => "both",
                "BANKRUN_LEARN_INIT" => "uniform", "BANKRUN_LEARN_GRIP" => "0.5")
    for rule in ("payoff", "imitate", "payoff+imitate", "payoff+type")
        @test parse_with(merge(base, Dict("BANKRUN_LEARN" => rule))).LEARN_INIT == "uniform"
    end
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN" => "precision")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN" => "type", "BANKRUN_LEARN_GRIP" => "0")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN_GRIP" => "0")))   # LEARN none
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN" => "payoff", "BANKRUN_LEARN_INIT" => "random")))
end
