# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_episodes.jl
#
# Repeated episodes, BANKRUN_EPISODES (2026-10-28; docs/learning_design.md, L1).
#   A. EPISODES = 1 reproduces the reference commit byte for byte (results and
#      every output file), on the default bank and on the reference bank.
#   B. EPISODES = 3: the per-run files are exactly those of a single-episode run
#      with episode 3's seed. The reset gives a fresh bank, so the last episode
#      is the model rebuilt from scratch.
#   C. bankRunEpisodes: one row per episode and type; episode e's failure and θ
#      match a single-episode run with episode e's seed; no early-episode file
#      leaks into the output directory.
#   D. Episode seeds: episode 1 is the run's own seed; the rest are distinct and
#      non-negative.
# Uses the production network size (N = 1000) at a small MC depth, as test_replay.jl.

using Test
using CSV, DataFrames, Distributions, Random

include(joinpath(@__DIR__, "..", "scripts", "replay_run.jl"))   # loadCell, defines ROOT

const REFERENCE = "dfb5afe"      # master before L1
const GEN_SEED = 1017
const DEPTH = 10
# out, seed, reserve, q, dist, m, sigma, k, p, alpha, mu, lambdaI, lambdaC (parameterGen.jl)
const CELL_DEFAULT = ["0.15", "0.0", "LogNormal", "1.0", "2.0", "6", "0.05", "0.1", "0.5", "0.1", "0.9"]
const CELL_REF     = ["0.05", "0.0", "LogNormal", "1.0", "2.5", "6", "0.05", "0.1", "0.5", "0.1", "0.9"]
const SW_DEFAULT = (FRESH_CLONE = true, LOG = "summary")
# r1k-stale-y50 (arms/rung1_cap.tsv): the capped fire-sale reference bank, stale y
const SW_REF = (FRESH_CLONE = true, LOG = "summary", BALANCE = "firesale", PAYOFF = "recovery",
                FUNDAMENTAL = "theta", FIRE_DISCOUNT = 0.6, EQUITY = 0.06, RETURN_LO = 1.0,
                RETURN_HI = 1.4, STAY_RETURN = 1.1, PRIVATE_SIGNAL = "theta", THETA_NOISE = 0.10,
                THETA_PUBLIC_NOISE = 0.10, THETA_PUBLIC = "stale", THETA_PUBLIC_LEVEL = 0.5,
                LAMBDA_SCOPE = "both", WITHDRAW = "partial", CARA = 0.1, DEPOSIT_CAP = 0.01)
const ROWS = 1:3

# The model's per-core outputs (bankRun*<core>.csv), with the run keys' build
# timestamps masked: each module stamps its keys and its parameterGen.jl files
# (bankRunParametersInit.csv, key*.jld2) with the time it was loaded.
const STAMP = r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?"
outputs(dir) = Dict(f => replace(read(joinpath(dir, f), String), STAMP => "T")
                    for f in readdir(dir) if occursin(r"^bankRun[A-Za-z]+\d+\.csv$", f))
lines(dir, pat) = vcat([readlines(joinpath(dir, f)) for f in readdir(dir) if occursin(pat, f)]...)

"""loadCell from the files at the reference commit (git show), not the working tree."""
function loadReference(out, cliArgs; switches, depth)
    src = mktempdir()
    for f in ("settings.jl", "objects.jl", "warmup.jl", "functions4.jl", "parameterGen.jl")
        write(joinpath(src, f), read(`git -C $ROOT show $REFERENCE:$f`, String))
    end
    m = Module(:Ref)
    Core.eval(m, :(using Distributions, Random, LinearAlgebra, CSV, DataFrames, Graphs,
                         StatsBase, JLD2, Dates, Distributed))
    for f in ("settings.jl", "objects.jl", "warmup.jl", "functions4.jl")
        Base.include(m, joinpath(src, f))
    end
    Core.eval(m, :(CLI_ARGS = $cliArgs; dataDir = $(String(out)); workerCore = 1;
                   depth = $depth; ASSIGN_RULE = "warmup"))
    for (k, v) in pairs(switches)
        Core.eval(m, :($k = $v))
    end
    redirect_stdout(devnull) do
        Base.include(m, joinpath(src, "parameterGen.jl"))
    end
    return m
end

cell(out, c, sw; episodes=nothing) =
    loadCell(out, [out, string(GEN_SEED), c...];
             switches=episodes === nothing ? sw : merge(sw, (EPISODES = episodes,)), depth=DEPTH)

"""Run rows `ROWS` of module `m`; with `seed2s`, override each row's seed2 (same key)."""
function runRows(m; seed2s=nothing)
    jf = copy(m.jointFrame)
    for (j, i) in enumerate(ROWS)
        seed2s === nothing || (jf[i, :seed2] = seed2s[j])
        Base.invokelatest(m.runRow, jf[i, :])
    end
end

for (label, c, sw) in (("default bank", CELL_DEFAULT, SW_DEFAULT), ("reference bank", CELL_REF, SW_REF))
    @testset "A. EPISODES = 1 reproduces $REFERENCE ($label)" begin
        dr, dc = mktempdir(), mktempdir()
        ref = loadReference(dr, [dr, string(GEN_SEED), c...]; switches=sw, depth=DEPTH)
        cur = cell(dc, c, sw; episodes=1)
        runRows(ref); runRows(cur)
        o_ref, o_cur = outputs(dr), outputs(dc)
        @test sort(collect(keys(o_ref))) == sort(collect(keys(o_cur)))
        @test o_ref == o_cur
    end

    @testset "B-C. EPISODES = 3 ($label)" begin
        E = 3
        de = mktempdir()
        mE = cell(de, c, sw; episodes=E)
        runRows(mE)
        seeds = [mE.jointFrame[i, :seed2] for i in ROWS]

        # B: per-run files = a single-episode run with episode E's seed
        d1 = mktempdir()
        m1 = cell(d1, c, sw)
        runRows(m1; seed2s=[m1.episodeSeed(s, E) for s in seeds])
        oE, o1 = outputs(de), outputs(d1)
        epFiles = filter(f -> startswith(f, "bankRunEpisodes"), collect(keys(oE)))
        @test length(epFiles) == 1
        @test sort(setdiff(collect(keys(oE)), epFiles)) == sort(collect(keys(o1)))
        @test all(oE[f] == o1[f] for f in keys(o1))

        # C: one row per episode and type, and each episode matches a single run
        ep = CSV.read(joinpath(de, only(epFiles)), DataFrame; header=false)
        @test nrow(ep) == length(ROWS) * E * 2
        for e in 1:E
            de1 = mktempdir()
            me = cell(de1, c, sw)
            runRows(me; seed2s=[me.episodeSeed(s, e) for s in seeds])
            res = CSV.read(joinpath(de1, only(filter(f -> startswith(f, "bankRunResults"), readdir(de1)))),
                           DataFrame; header=false)
            rows_e = ep[ep[:, 3] .== e, :]
            for (j, s) in enumerate(seeds)
                r = rows_e[rows_e[:, 4] .== me.episodeSeed(s, e), :]
                @test nrow(r) == 2                                   # types I and C
                @test all(r[:, 6] .== res[j, 2])                     # failed = that run's result
                @test all(r[:, 5] .≈ Base.invokelatest(me.episodeTheta, me.episodeSeed(s, e)))
            end
        end
        @test length(lines(de, "bankRunResults")) == length(ROWS)   # last episode only
    end
end

@testset "D. episode seeds" begin
    m = Module(:Seeds)
    Core.eval(m, :(using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase))
    for f in ("settings.jl", "objects.jl", "functions4.jl")
        Base.include(m, joinpath(ROOT, f))
    end
    for s in (1, 17, 999_999, typemax(Int64))
        seeds = [m.episodeSeed(s, e) for e in 1:50]
        @test seeds[1] == s
        @test allunique(seeds)
        @test all(seeds .>= 0)
    end
end
