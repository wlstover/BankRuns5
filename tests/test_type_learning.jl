# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_type_learning.jl
#
# L3b group learning by success-biased type switching, BANKRUN_LEARN = type and
# payoff+type (2026-10-30; docs/learning_design.md §5).
#   A. ν = 0 is the no-learning model (type) and Rule B alone (payoff+type): every
#      per-run file and the episode rows are identical, and nJoined is 0.
#   B. Episode 1 is the no-learning model at any ν.
#   C. The learner, replayed by hand episode by episode (realised payoffs, one random
#      neighbour each from the type stream, switch to the other type if it was paid
#      more, λ to the same quantile of the new type's Beta; Rule B first under
#      payoff+type), gives the type counts, λ, θ weights and nJoined the episode rows
#      report.
#   D. typeUpdate! arithmetic: synchronous, only to the other type, only toward a
#      better-paid neighbour, a tie is no switch, the quantile is kept.
#   E. μ moves; payoff+type differs from payoff.
#   F. The refused combinations.
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
const E = 4
const GRIP, MEMORY, R = 0.5, 0.2, 1.1
const RATE = 0.5                     # high, so a few episodes show switches
# bankRunEpisodes columns: key type episode seed2 theta failed n nExog nEndog depTotal
# depEndog lambdaMean lambdaSd weightMean weightSd msexMean mseyMean nJoined
const C_EPISODE, C_N, C_LAMBDA, C_WEIGHT, C_MSEX, C_JOINED = 3, 7, 12, 14, 16, 18
# bankRunEpisodes columns 19-20 (late 2026-10-30): learnedMean learnedSd, the learned weight w* alone
const C_LEARNED, C_LEARNED_SD = 19, 20

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

learnSw(rule; rate=RATE) = merge(SW, (EPISODES = E, LEARN = rule, LEARN_TYPE_RATE = rate,
                                      LEARN_GRIP = rule == "type" ? 0.0 : GRIP, LEARN_MEMORY = MEMORY))

m0, d0 = arm(merge(SW, (EPISODES = E,)))
ep0 = episodes(d0)

@testset "A. ν = 0 is the model without type switching" begin
    _, d = arm(learnSw("type"; rate=0.0))
    o0, o = outputs(d0), outputs(d)
    per_run = filter(f -> !startswith(f, "bankRunEpisodes"), collect(keys(o0)))
    @test sort(collect(keys(o0))) == sort(collect(keys(o)))
    @test all(o0[f] == o[f] for f in per_run)
    ep = episodes(d)
    @test Matrix(ep[:, 2:C_MSEX-1]) == Matrix(ep0[:, 2:C_MSEX-1])      # col 1: keys carry build stamps
    @test all(ep[:, C_JOINED] .== 0) && all(ep0[:, C_JOINED] .== 0)
    _, dp = arm(merge(SW, (EPISODES = E, LEARN = "payoff", LEARN_GRIP = GRIP, LEARN_MEMORY = MEMORY)))
    _, dpt = arm(learnSw("payoff+type"; rate=0.0))
    op, opt = outputs(dp), outputs(dpt)
    @test all(op[f] == opt[f] for f in per_run)
    @test isequal(Matrix(episodes(dp)[:, 2:end]), Matrix(episodes(dpt)[:, 2:end]))   # NaN columns under Rule B
end

arms = Dict(rule => arm(learnSw(rule)) for rule in ("type", "payoff+type"))
arms["payoff"] = arm(merge(SW, (EPISODES = E, LEARN = "payoff", LEARN_GRIP = GRIP, LEARN_MEMORY = MEMORY)))
eps = Dict(rule => episodes(d) for (rule, (_, d)) in arms)

@testset "B. episode 1 is the no-learning model" begin
    one(ep) = Matrix(ep[ep[:, C_EPISODE] .== 1, 2:C_MSEX-1])
    @test one(eps["type"]) == one(ep0)
    @test one(eps["payoff+type"]) == one(ep0)
end

# Episodes 1..E-1 rerun by hand from a fresh model (common seeding: same draws), the
# learner written out here, not called; types, λ and θ weights drive each next episode.
@testset "C. the learner replayed by hand ($rule)" for rule in ("type", "payoff+type")
    mk, _ = arms[rule]
    epk = eps[rule]
    grip = rule == "type" ? 0.0 : GRIP
    scratch = mktempdir()
    Core.eval(mk, :(dataDir = $scratch))          # the hand runs' files go here
    nswitch = 0
    for i in ROWS
        row = mk.jointFrame[i, :]
        mod, isI0 = Base.invokelatest(mk.modelGenTyped, row[:key], row[:seed1], row[:seed2],
                                      nv(row[:network]), .1, row[:network], row[:depositDist],
                                      row[:reserveRatio], row[:depositInsuranceQuantile],
                                      row[:withdrawRV], row[:warmupAlpha], row[:fracIndividualists],
                                      row[:lambdaI], row[:lambdaC])
        distI = Beta(clamp(row[:lambdaI], 0.01, 0.99) * 20.0, clamp(1 - row[:lambdaI], 0.01, 0.99) * 20.0)
        distC = Beta(clamp(row[:lambdaC], 0.01, 0.99) * 20.0, clamp(1 - row[:lambdaC], 0.01, 0.99) * 20.0)
        isI = collect(isI0)
        start = mk.BankStart(mod)
        λ = [a.individualism for a in mod.agtList]
        deps0 = [a.deposit for a in mod.agtList]
        cap = quantile(mod.depositDistribution, mod.depositInsurance)
        n = length(λ)
        learned = copy(λ)
        weight = copy(λ)
        switched = falses(n)
        rows_i = epk[endswith.(epk[:, 1], runkey(row[:seed1], row[:seed2])), :]
        for e in 1:E
            for (t, sel) in (("I", isI), ("C", .!isI))
                r = rows_i[(rows_i[:, C_EPISODE] .== e) .& (rows_i[:, 2] .== t), :]
                @test nrow(r) == 1
                @test r[1, C_N] == count(sel)
                @test r[1, C_LAMBDA] ≈ mean(λ[sel])
                @test r[1, C_WEIGHT] ≈ mean(weight[sel])
                @test r[1, C_JOINED] == count(switched[sel])
            end
            e == E && break
            Base.invokelatest(mk.resetEpisode!, mod, start, e)
            rec = mk.RunRecord()
            Base.invokelatest(mk.modelRun, mod; record=rec, thetaWeight=copy(weight))
            ρ = rec.endRho
            stay = [(d = a.deposit; ρ >= 1.0 ? R : max(ρ * R, min(d, cap) / d)) for a in mod.agtList]
            left = [a.banked ? a.deposit : 0.0 for a in mod.agtList]
            if rule == "payoff+type"
                θ, x = Base.invokelatest(mk.episodeThetaDraws, mod.seed2, n)
                y = Base.invokelatest(mk.publicAtStart, θ)
                for j in 1:n
                    (stay[j] == 1.0 || y == x[j]) && continue
                    learned[j] = (1 - MEMORY) * learned[j] + MEMORY * ((stay[j] > 1.0) == (y > x[j]) ? 1.0 : 0.0)
                end
            end
            paid = zeros(n)
            for (k, j) in enumerate(rec.order)
                paid[j] += rec.paid[k]
            end
            π = (paid .+ stay .* left) ./ deps0
            rng = MersenneTwister(xor(reinterpret(UInt64, mod.seed2), 0x6a09e667f3bcc909))
            before = copy(isI)
            switched = falses(n)
            for j in 1:n
                go = rand(rng) < RATE
                nb = neighbors(mod.network, j)
                isempty(nb) && continue
                k = nb[rand(rng, 1:length(nb))]
                (go && before[k] != before[j] && π[k] > π[j]) || continue
                from, to = before[j] ? (distI, distC) : (distC, distI)
                λ[j] = quantile(to, cdf(from, λ[j]))
                mod.agtList[j].individualism = λ[j]
                isI[j] = !before[j]
                switched[j] = true
                nswitch += 1
            end
            weight = (1 - grip) .* λ .+ grip .* learned
        end
    end
    @test nswitch > 0
end

@testset "D. typeUpdate!" begin
    mk, _ = arms["type"]
    g = path_graph(3)                                  # 1 — 2 — 3
    dI, dC = Beta(2.0, 18.0), Beta(18.0, 2.0)
    agents = [mk.Agent(1, 1.0, true, 0.1), mk.Agent(2, 1.0, true, 0.9), mk.Agent(3, 1.0, true, 0.9)]
    isI = BitVector([true, false, false])
    L = mk.LearnState([0.1, 0.9, 0.9], zeros(3), zeros(3), [0.1, 0.9, 0.9], [0.5, 0.5, 0.5])
    rng = MersenneTwister(3)
    toC, toI = mk.typeUpdate!(L, agents, isI, g, [1.0, 2.0, 3.0], rng; rate=1.0,
                              distI=dI, distC=dC, grip=0.5)
    # 1 (I) sees 2 (C), paid more: switches, to the same quantile of the C Beta
    @test isI[1] == false && L.switched[1]
    @test agents[1].individualism ≈ quantile(dC, cdf(dI, 0.1)) ≈ L.culture[1]
    # 2 (C): its neighbours are 1 (I, paid less before the round) or 3 (C, same type): no switch
    @test isI[2] == false && !L.switched[2]
    # 3 (C) sees 2 (C): same type, no switch
    @test isI[3] == false && !L.switched[3]
    @test (toC, toI) == (1, 0)
    @test L.weight ≈ 0.5 .* L.culture .+ 0.5 .* L.learned
    # a tie is no switch; rate 0 is no switch
    a2 = [mk.Agent(1, 1.0, true, 0.1), mk.Agent(2, 1.0, true, 0.9)]
    i2 = BitVector([true, false])
    L2 = mk.LearnState([0.1, 0.9], zeros(2), zeros(2), [0.1, 0.9])
    @test mk.typeUpdate!(L2, a2, i2, path_graph(2), [1.0, 1.0], MersenneTwister(1); rate=1.0,
                         distI=dI, distC=dC, grip=0.0) == (0, 0)
    @test mk.typeUpdate!(L2, a2, i2, path_graph(2), [1.0, 2.0], MersenneTwister(1); rate=0.0,
                         distI=dI, distC=dC, grip=0.0) == (0, 0)
    @test i2 == [true, false] && L2.culture == [0.1, 0.9]
end

@testset "E. μ moves; payoff+type differs from payoff" begin
    ep = eps["type"]
    late = ep[ep[:, C_EPISODE] .> 1, :]
    @test sum(late[:, C_JOINED]) > 0
    nI = [sum(g[g[:, 2] .== "I", C_N]) for g in groupby(ep, :Column3)]
    @test length(unique(nI)) > 1                                       # the number of type I changes
    @test all(abs.(ep[ep[:, 2] .== "I", C_LAMBDA] .- 0.1) .< 0.05)      # λ stays within each type's Beta
    @test all(abs.(ep[ep[:, 2] .== "C", C_LAMBDA] .- 0.9) .< 0.05)
    a, b = eps["payoff"], eps["payoff+type"]
    @test a[:, 5] == b[:, 5]                                           # same draws
    @test any(a[a[:, C_EPISODE] .> 1, C_WEIGHT] .!= b[b[:, C_EPISODE] .> 1, C_WEIGHT])
end

@testset "F. refused combinations" begin
    mk, _ = arms["type"]
    parse_with(d) = withenv(d...) do
        Base.invokelatest(mk.parseSwitchesFromEnv)
    end
    base = Dict("BANKRUN_BALANCE" => "firesale", "BANKRUN_PAYOFF" => "recovery",
                "BANKRUN_FUNDAMENTAL" => "theta", "BANKRUN_PRIVATE_SIGNAL" => "theta",
                "BANKRUN_THETA_PUBLIC" => "stale", "BANKRUN_LAMBDA_SCOPE" => "both",
                "BANKRUN_LEARN" => "type")
    @test parse_with(base).LEARN == "type"
    @test parse_with(merge(base, Dict("BANKRUN_LEARN_TYPE_RATE" => "0.1"))).LEARN_TYPE_RATE == 0.1
    @test parse_with(merge(base, Dict("BANKRUN_LEARN" => "payoff+type", "BANKRUN_LEARN_GRIP" => "0.5"))).LEARN == "payoff+type"
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN_GRIP" => "0.5")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_THETA_PUBLIC" => "none")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN" => "payoff", "BANKRUN_LEARN_GRIP" => "0.5",
                                                            "BANKRUN_LEARN_TYPE_RATE" => "0.1")))
    @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LEARN_TYPE_RATE" => "1.5")))
end

@testset "E. the learned-weight columns: weight = (1 − κ)·λ + κ·ω* by type" begin
    @test all(isnan, ep0[:, C_LEARNED]) && all(isnan, ep0[:, C_LEARNED_SD])     # no learning
    for (rule, k) in (("type", 0.0), ("payoff+type", GRIP), ("payoff", GRIP))
        @test all(isapprox.(eps[rule][:, C_WEIGHT], (1 - k) .* eps[rule][:, C_LAMBDA] .+ k .* eps[rule][:, C_LEARNED]; atol=1e-12))
        @test eps[rule][eps[rule][:, C_EPISODE] .== 1, C_LEARNED] == eps[rule][eps[rule][:, C_EPISODE] .== 1, C_LAMBDA]     # ω* starts at λ
        @test !any(isnan, eps[rule][:, C_LEARNED_SD])
    end
end
