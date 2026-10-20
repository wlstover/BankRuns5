################################################################################
#  replay_run.jl — re-simulate one run of a sweep with full logging (2026-10-15).
#
#  A run is fully determined by its cell (the parameters), the task's generator
#  seed (GEN_SEED = seed_offset + task_id, which also fixes the network) and the
#  run's two seeds (the last two fields of its key). So a sweep run with
#  BANKRUN_LOG=summary keeps only run-level results and the who-runs summary,
#  and the per-agent / per-decision logs of any run are regenerated here.
#  The replay writes the same files a BANKRUN_LOG=full sweep would, under the
#  run's original key; tests/test_replay.jl checks it reproduces the stored
#  results, vault and who-runs rows byte for byte.
#
#  Usage (from the repo root, same commit and Manifest as the sweep):
#    julia --project=. scripts/replay_run.jl --manifest outputs/<tag>/manifest.csv \
#          --task 17 --key '2026-10-16T09:12:03.123-482913-77120' --out outputs/replay
#
#  The manifest supplies the cell, seed_offset, assign_rule, mc_depth and the
#  BANKRUN_* switches (empty field = default). Manifests written before
#  2026-10-15 lack the switch columns; the defaults are used then, so set
#  BANKRUN_* in the environment if that arm ran with non-default switches.
################################################################################

using Distributions, Random, LinearAlgebra, CSV, DataFrames, Graphs, StatsBase, JLD2, Dates, Distributed

const ROOT = dirname(@__DIR__)

"""
    loadCell(out, cliArgs; switches, assign, depth) -> Module

The model plus parameterGen.jl for one cell, in a fresh module, exactly as
finMain0001.jl sets it up on a worker (dataDir = out, workerCore = 1). The
returned module holds `jointFrame`; run a row with `m.runRow(row)`.
"""
function loadCell(out::AbstractString, cliArgs::Vector{String};
                  switches=NamedTuple(), assign::AbstractString="warmup", depth::Int=100)
    mkpath(out)
    m = Module(:Cell)
    Core.eval(m, :(using Distributions, Random, LinearAlgebra, CSV, DataFrames, Graphs,
                         StatsBase, JLD2, Dates, Distributed))
    for f in ("settings.jl", "objects.jl", "warmup.jl", "functions4.jl")
        Base.include(m, joinpath(ROOT, f))
    end
    Core.eval(m, :(CLI_ARGS = $cliArgs; dataDir = $(String(out)); workerCore = 1;
                   depth = $depth; ASSIGN_RULE = $(String(assign))))
    for (k, v) in pairs(switches)
        Core.eval(m, :($k = $v))
    end
    redirect_stdout(devnull) do                      # parameterGen.jl prints jointFrame
        Base.include(m, joinpath(ROOT, "parameterGen.jl"))
    end
    return m
end

"""The run's two seeds, from its key `<timestamp>-<seed1>-<seed2>`."""
function keySeeds(key::AbstractString)
    f = split(key, '-')
    return parse(Int, f[end-1]), parse(Int, f[end])
end

"""Run the row with these seeds under the original key; returns (result, nWithdrawn, depositWithdrawn)."""
function replayRow(m::Module, key::AbstractString)
    s1, s2 = keySeeds(key)
    jf = m.jointFrame
    hits = findall((jf.seed1 .== s1) .& (jf.seed2 .== s2))
    length(hits) == 1 || error("expected one row with seeds ($s1, $s2), found $(length(hits))")
    row = jf[hits[1], :]
    row[:key] = String(key)
    return Base.invokelatest(m.runRow, row)
end

const SWITCH_COLUMNS = ("public_alpha" => "BANKRUN_PUBLIC_ALPHA", "public_bias" => "BANKRUN_PUBLIC_BIAS",
                        "public_rho" => "BANKRUN_PUBLIC_RHO", "weight_phi" => "BANKRUN_WEIGHT_PHI",
                        "fix_double_count" => "BANKRUN_FIX_DOUBLE_COUNT", "fresh_clone" => "BANKRUN_FRESH_CLONE",
                        "tiebreak" => "BANKRUN_TIEBREAK", "belief" => "BANKRUN_BELIEF",
                        "belief_p0" => "BANKRUN_BELIEF_P0",
                        "public_mode" => "BANKRUN_PUBLIC_MODE", "public_refresh" => "BANKRUN_PUBLIC_REFRESH",
                        "private_signal" => "BANKRUN_PRIVATE_SIGNAL", "private_noise" => "BANKRUN_PRIVATE_NOISE",
                        "stay_return" => "BANKRUN_STAY_RETURN")

function main(args)
    opts = Dict{String,String}()
    i = 1
    while i <= length(args)
        startswith(args[i], "--") || error("unexpected argument $(args[i])")
        opts[args[i][3:end]] = args[i+1]; i += 2
    end
    for req in ("manifest", "task", "key", "out")
        haskey(opts, req) || error("missing --$req (see the header of this script)")
    end
    man = CSV.read(opts["manifest"], DataFrame; types=String)
    task = parse(Int, opts["task"])
    r = man[parse.(Int, man.task_id) .== task, :]
    nrow(r) == 1 || error("task $task not in $(opts["manifest"])")
    r = r[1, :]
    genSeed = parse(Int, r.seed_offset) + task
    cli = [opts["out"], string(genSeed), r.reserve, r.depq, "LogNormal", "1.0", r.sigma,
           r.k, r.p, r.alpha, r.mu, r.lambdaI, r.lambdaC]
    cell(col) = hasproperty(r, Symbol(col)) && !ismissing(r[Symbol(col)]) ? r[Symbol(col)] : ""
    env = [var => cell(col) for (col, var) in SWITCH_COLUMNS]
    # The double-count default changed to true on 2026-10-20 and run_all.sh has
    # written it resolved since; an empty field is an older manifest, i.e. false.
    env = [var == "BANKRUN_FIX_DOUBLE_COUNT" && isempty(val) ? var => "false" : var => val
           for (var, val) in env]
    # Parse the switches the way finMain0001.jl does, then force full logging.
    tmp = Module(:Parse)
    Base.include(tmp, joinpath(ROOT, "settings.jl"))
    sw = withenv(env...) do
        Base.invokelatest(tmp.parseSwitchesFromEnv)
    end
    sw = merge(sw, (LOG = "full",))
    m = loadCell(opts["out"], cli; switches=sw, assign=r.assign_rule, depth=parse(Int, r.mc_depth))
    res = replayRow(m, opts["key"])
    println("replayed $(opts["key"]) (task $task, GEN_SEED $genSeed): result=$(res[1]) ",
            "nWithdrawn=$(res[2]) depositWithdrawn=$(res[3]) -> $(opts["out"])")
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
