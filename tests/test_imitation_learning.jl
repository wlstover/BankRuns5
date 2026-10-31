# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_imitation_learning.jl
#
# L3a imitation of a better-paid neighbour's θ weight, BANKRUN_LEARN = imitate and
# payoff+imitate (2026-10-29; docs/learning_design.md §5).
#   A. LEARN = imitate with κ = 0 is the no-learning model: every per-run file and
#      the episode rows are identical.
#   B. Episode 1 is the no-learning model whatever κ.
#   C. The learner, replayed by hand episode by episode (realised payoffs from each
#      episode's withdrawals and end-of-run ρ, one random neighbour each, Rule B first
#      under payoff+imitate), gives the θ weights the episode rows report.
#   D. imitateUpdate! arithmetic: synchronous, only toward a better-paid neighbour.
#   E. The cultural λ never moves; payoff+imitate differs from payoff. (Imitation
#      alone keeps every learned weight inside the range of the cultural λ: in C.)
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
# bankRunEpisodes columns: key type episode seed2 theta failed n nExog nEndog depTotal
# depEndog lambdaMean lambdaSd weightMean weightSd msexMean mseyMean
const C_EPISODE, C_LAMBDA, C_WEIGHT, C_MSEX = 3, 12, 14, 16
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

learnSw(rule) = merge(SW, (EPISODES = E, LEARN = rule, LEARN_GRIP = GRIP, LEARN_MEMORY = MEMORY))

m0, d0 = arm(merge(SW, (EPISODES = E,)))
ep0 = episodes(d0)

@testset "A. κ = 0 is the no-learning model" begin
    for rule in ("imitate", "payoff+imitate")
        _, d = arm(merge(SW, (EPISODES = E, LEARN = rule, LEARN_GRIP = 0.0)))
        o0, o = outputs(d0), outputs(d)
        per_run = filter(f -> !startswith(f, "bankRunEpisodes"), collect(keys(o0)))
        @test sort(collect(keys(o0))) == sort(collect(keys(o)))
        @test all(o0[f] == o[f] for f in per_run)
        ep = episodes(d)
        @test Matrix(ep[:, 2:C_MSEX-1]) == Matrix(ep0[:, 2:C_MSEX-1])      # col 1: keys carry build stamps
        @test all(isnan, ep[:, C_MSEX])
    end
end

arms = Dict(rule => arm(learnSw(rule)) for rule in ("imitate", "payoff+imitate", "payoff"))
eps = Dict(rule => episodes(d) for (rule, (_, d)) in arms)

@testset "B. episode 1 is the no-learning model" begin
    one(ep) = Matrix(ep[ep[:, C_EPISODE] .== 1, 2:C_MSEX-1])
    @test one(eps["imitate"]) == one(ep0)
    @test one(eps["payoff+imitate"]) == one(ep0)
end

# Episodes 1..E-1 rerun by hand from a fresh model (common seeding: same draws), the
# learner written out here, not called; its θ weights drive each next episode.
@testset "C. the learner replayed by hand ($rule)" for rule in ("imitate", "payoff+imitate")
    mk, _ = arms[rule]
    epk = eps[rule]
    scratch = mktempdir()
    Core.eval(mk, :(dataDir = $scratch))          # the hand runs' files go here
    moved = false
    for i in ROWS
        row = mk.jointFrame[i, :]
        mod, isI = Base.invokelatest(mk.modelGenTyped, row[:key], row[:seed1], row[:seed2],
                                     nv(row[:network]), .1, row[:network], row[:depositDist],
                                     row[:reserveRatio], row[:depositInsuranceQuantile],
                                     row[:withdrawRV], row[:warmupAlpha], row[:fracIndividualists],
                                     row[:lambdaI], row[:lambdaC])
        start = mk.BankStart(mod)
        λ = [a.individualism for a in mod.agtList]
        deps0 = [a.deposit for a in mod.agtList]
        cap = quantile(mod.depositDistribution, mod.depositInsurance)
        n = length(λ)
        learned = copy(λ)
        weight = copy(λ)
        rows_i = epk[endswith.(epk[:, 1], runkey(row[:seed1], row[:seed2])), :]
        for e in 1:E
            for (t, sel) in (("I", isI), ("C", .!isI))
                r = rows_i[(rows_i[:, C_EPISODE] .== e) .& (rows_i[:, 2] .== t), :]
                @test nrow(r) == 1
                @test r[1, C_WEIGHT] ≈ mean(weight[sel])
            end
            e == E && break
            Base.invokelatest(mk.resetEpisode!, mod, start, e)
            rec = mk.RunRecord()
            Base.invokelatest(mk.modelRun, mod; record=rec, thetaWeight=copy(weight))
            ρ = rec.endRho
            # per unit, what staying to the end paid on the balance held at the end
            # (for those who left, what it would have paid: Rule B scores everyone)
            stay = [(d = a.deposit; ρ >= 1.0 ? R : max(ρ * R, min(d, cap) / d)) for a in mod.agtList]
            left = [a.banked ? a.deposit : 0.0 for a in mod.agtList]
            if rule == "payoff+imitate"
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
            rng = MersenneTwister(xor(reinterpret(UInt64, mod.seed2), 0x2545f4914f6cdd1d))
            before = copy(learned)
            for j in 1:n
                nb = neighbors(mod.network, j)
                isempty(nb) && continue
                k = nb[rand(rng, 1:length(nb))]
                π[k] > π[j] && (learned[j] = (1 - MEMORY) * before[j] + MEMORY * before[k])
            end
            weight = (1 - GRIP) .* λ .+ GRIP .* learned
            moved |= any(weight .!= λ)
            rule == "imitate" && @test minimum(λ) <= minimum(learned) && maximum(learned) <= maximum(λ)
        end
    end
    @test moved
end

@testset "D. imitateUpdate!" begin
    mk, _ = arms["imitate"]
    g = path_graph(3)                                  # 1 — 2 — 3
    L = mk.LearnState([0.2, 0.2, 0.2], zeros(3), zeros(3), fill(0.2, 3), [0.0, 0.5, 1.0])
    rng = MersenneTwister(7)
    r = copy(rng); rand(r, 1:1)                        # agent 1 draws first
    pick2 = neighbors(g, 2)[rand(r, 1:2)]              # then agent 2
    mk.imitateUpdate!(L, g, [1.0, 2.0, 3.0], rng; grip=1.0, memory=0.5)
    @test L.learned[1] ≈ 0.25                          # toward 2's weight before the round
    @test L.learned[3] ≈ 1.0                           # 2 was paid less: no move
    @test L.learned[2] ≈ (pick2 == 3 ? 0.75 : 0.5)     # toward 3, or stays (1 was paid less)
    @test L.weight ≈ L.learned
    L2 = mk.LearnState([0.2, 0.8], zeros(2), zeros(2), [0.2, 0.8])
    mk.imitateUpdate!(L2, path_graph(2), [1.0, 1.0], MersenneTwister(1); grip=0.5, memory=0.5)
    @test L2.learned ≈ [0.2, 0.8]                      # payoff tie: no move
    @test L2.weight ≈ [0.2, 0.8]
end

@testset "E. the cultural λ never moves; imitation adds to Rule B" begin
    ep = eps["imitate"]
    for (k, g) in pairs(groupby(ep, [:Column1, :Column2]))
        @test length(unique(g[:, C_LAMBDA])) == 1                     # the cultural λ never moves
    end
    a, b = eps["payoff"], eps["payoff+imitate"]
    @test a[:, 5] == b[:, 5]                                           # same draws
    @test any(a[a[:, C_EPISODE] .> 1, C_WEIGHT] .!= b[b[:, C_EPISODE] .> 1, C_WEIGHT])
end

@testset "F. refused combinations" begin
    mk, _ = arms["imitate"]
    parse_with(d) = withenv(d...) do
        Base.invokelatest(mk.parseSwitchesFromEnv)
    end
    for rule in ("imitate", "payoff+imitate")
        base = Dict("BANKRUN_BALANCE" => "firesale", "BANKRUN_PAYOFF" => "recovery",
                    "BANKRUN_FUNDAMENTAL" => "theta", "BANKRUN_PRIVATE_SIGNAL" => "theta",
                    "BANKRUN_THETA_PUBLIC" => "stale", "BANKRUN_LAMBDA_SCOPE" => "both",
                    "BANKRUN_LEARN" => rule, "BANKRUN_LEARN_GRIP" => "0.5")
        @test parse_with(base).LEARN == rule
        @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_THETA_PUBLIC" => "none")))
        @test_throws ErrorException parse_with(merge(base, Dict("BANKRUN_LAMBDA_SCOPE" => "count")))
    end
end

@testset "E. the learned-weight columns: weight = (1 − κ)·λ + κ·ω* by type" begin
    @test all(isnan, ep0[:, C_LEARNED]) && all(isnan, ep0[:, C_LEARNED_SD])     # no learning
    for rule in ("imitate", "payoff+imitate")
        @test all(isapprox.(eps[rule][:, C_WEIGHT], (1 - GRIP) .* eps[rule][:, C_LAMBDA] .+ GRIP .* eps[rule][:, C_LEARNED]; atol=1e-12))
        @test eps[rule][eps[rule][:, C_EPISODE] .== 1, C_LEARNED] == eps[rule][eps[rule][:, C_EPISODE] .== 1, C_LAMBDA]     # ω* starts at λ
        @test !any(isnan, eps[rule][:, C_LEARNED_SD])
    end
end
