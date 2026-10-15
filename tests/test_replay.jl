# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_replay.jl
#
# BANKRUN_LOG=summary and scripts/replay_run.jl (2026-10-15).
#   A. A summary-mode "sweep" of three runs writes results, vault and the
#      who-runs summary, and no per-agent or per-decision logs.
#   B. Replaying one of those runs from a manifest row (as run_all.sh writes it)
#      reproduces its results, vault and who-runs rows byte for byte, and writes
#      the full logs.
#   C. The who-runs summary agrees with the full logs (counts by type and how).
# Uses the production network size (N = 1000) at a small MC depth.

using Test
using CSV, DataFrames

include(joinpath(@__DIR__, "..", "scripts", "replay_run.jl"))   # defines ROOT

const GEN_SEED = 1017
const CELL = ["0.15", "0.0", "LogNormal", "1.0", "2.0", "6", "0.05", "0.1", "0.5", "0.1", "0.9"]
const SW = (FRESH_CLONE = true, TIEBREAK = "schuler")
const DEPTH = 10
lines(dir, pat) = vcat([readlines(joinpath(dir, f)) for f in readdir(dir) if occursin(pat, f)]...)
rowsfor(dir, pat, key) = filter(l -> startswith(l, key * ","), lines(dir, pat))

sweep = mktempdir()
m1 = loadCell(sweep, [sweep, string(GEN_SEED), CELL...]; switches=merge(SW, (LOG = "summary",)), depth=DEPTH)
keys_ = String[]
for i in 1:3
    row = m1.jointFrame[i, :]
    push!(keys_, row[:key])
    Base.invokelatest(m1.runRow, row)
end
key = keys_[2]

@testset "A. summary mode" begin
    files = readdir(sweep)
    @test !any(startswith(f, "agents") for f in files)
    @test !any(startswith(f, "bankRunEndogenous") for f in files)
    @test !any(startswith(f, "bankRunExogenous") for f in files)
    @test length(lines(sweep, "bankRunResults")) == 3
    @test length(lines(sweep, "bankRunVault")) == 3
    @test length(lines(sweep, "bankRunTypes")) == 6          # one row per type per run
end

replay_dir = joinpath(mktempdir(), "replay")
@testset "B. replay from the manifest" begin
    man = joinpath(mktempdir(), "manifest.csv")
    open(man, "w") do io
        println(io, "task_id,reserve,depq,sigma,k,p,alpha,mu,lambdaI,lambdaC,arm_tag,assign_rule,mc_depth,",
                "seed_offset,params_sha,submitted_at,public_alpha,public_bias,public_rho,weight_phi,",
                "fix_double_count,fresh_clone,tiebreak,belief,belief_p0")
        println(io, "1,0.15,0.0,2.0,6,0.05,0.1,0.5,0.1,0.9,t,warmup,$DEPTH,$(GEN_SEED - 1),x,now,",
                ",,,,,true,schuler,,")
    end
    redirect_stdout(devnull) do
        main(["--manifest", man, "--task", "1", "--key", key, "--out", replay_dir])
    end
    for pat in ("bankRunResults", "bankRunVault", "bankRunTypes")
        @test rowsfor(sweep, pat, key) == lines(replay_dir, pat)
        @test !isempty(lines(replay_dir, pat))
    end
    @test !isempty(lines(replay_dir, "agents"))
    @test !isempty(lines(replay_dir, "bankRunEndogenous"))
end

@testset "C. summary agrees with the full logs" begin
    ag = CSV.read(IOBuffer(join(lines(replay_dir, "agents"), "\n")), DataFrame;
                  header=[:key, :idx, :deposit, :lam, :warm, :type])
    en = CSV.read(IOBuffer(join(lines(replay_dir, "bankRunEndogenous"), "\n")), DataFrame;
                  header=[:key, :agent, :withdraw, :deposit, :tick, :vault, :wd, :st])
    exl = lines(replay_dir, "bankRunExogenous")
    ex = isempty(exl) ? DataFrame(agent=Int[]) :
         CSV.read(IOBuffer(join(exl, "\n")), DataFrame; header=[:key, :agent, :exo, :deposit, :tick, :vault])
    ty = CSV.read(IOBuffer(join(lines(replay_dir, "bankRunTypes"), "\n")), DataFrame;
                  header=[:key, :type, :n, :nExog, :nEndog, :depTotal, :depExog, :depEndog, :paidExog,
                          :paidEndog, :depStayers, :posSumEndog, :nFirstQuarter])
    typ = Dict(ag.idx .=> ag.type)
    endog = en.agent[en.withdraw .== true]
    for lab in ("I", "C")
        r = ty[ty.type .== lab, :][1, :]
        @test r.n == count(==(lab), ag.type)
        @test r.nEndog == count(i -> typ[i] == lab, endog)
        @test r.nExog == count(i -> typ[i] == lab, ex.agent)
        @test r.depTotal ≈ sum(ag.deposit[ag.type .== lab])
        @test r.depTotal ≈ r.depExog + r.depEndog + r.depStayers
    end
end
