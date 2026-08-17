#!/usr/bin/env julia
# =============================================================================
# dump_network.jl — regenerate a sweep cell's network and export it as an edge
# list, so the visualisation module can draw the graph the model actually used.
#
# WHY THIS IS POSSIBLE WITHOUT TOUCHING THE MODEL
# -----------------------------------------------
# parameterGen.jl:37   Random.seed!(genSeed)
# parameterGen.jl:107  newman_watts_strogatz(agtCnts[1], ws_k, ws_p)
#
# Nothing between those two lines consumes the global RNG — paretoGen and
# logNormalGen (parameterGen.jl:79-85) are pure constructors that return
# Pareto(...)/LogNormal(...) without drawing. So the network is exactly the
# first RNG consumer after the seed, and re-running that pair reproduces it.
#
# This script therefore READS none of Schuler's files and WRITES none of them.
# It re-runs one library call under one seed.
#
# genSeed for a sweep task is SEED_OFFSET + SLURM_ARRAY_TASK_ID
# (sweep_task.slurm:74), i.e. 1000 + task_id at the default offset.
#
# ⚠️ ONE NETWORK PER CELL. parameterGen.jl:107 builds a 1-element array which is
# then crossjoined, so ALL 250 runs in a cell share one network. Network
# structure does not vary with seed1 within a cell — only warm-up, lambda
# assignment and the deposit vector do.
#
# ⚠️ WHAT THIS DOES AND DOES NOT PROVE. Running it twice gives an identical
# graph, and the degree distribution can be checked against Newman-Watts'
# E[deg] = k(1+p). That establishes the regeneration is deterministic and
# structurally correct. It does NOT prove the edge set is byte-identical to the
# one the sweep used — that would need the model to emit an edge hash per task,
# which is a small addition worth batching with open item 12. Until then,
# captions should say "regenerated from the cell's seed", not "the network used".
#
# ⚠️ RNG STREAMS ARE VERSION-DEPENDENT. Run this under the SAME Julia and the
# same pinned Manifest as the sweep (julia/1.8.0 per sweep_task.slurm:46). A
# different Julia or a different Graphs.jl will silently give a different graph.
# The provenance file records both so a mismatch is at least detectable.
#
# USAGE
#   julia --project scripts/dump_network.jl --seed 1073 --n 1000 --k 6 --p 0.05 \
#         --out outputs/production/task_73/network
#
#   # from a manifest row, which is the safer way to get k and p right:
#   julia --project scripts/dump_network.jl --manifest outputs/production/manifest.csv \
#         --task 73 --out outputs/production/task_73/network
#
# Writes <out>_edges.csv (src,dst) and <out>_meta.csv (provenance).
# =============================================================================

using Random
using Graphs
using Printf
using SHA
using Dates

function usage()
    println(read(@__FILE__, String)[1:findfirst("=====\n", read(@__FILE__, String))[end]])
    exit(2)
end

# ── Arguments ────────────────────────────────────────────────────────────────
args = Dict{String,String}()
i = 1
while i <= length(ARGS)
    a = ARGS[i]
    if startswith(a, "--") && i < length(ARGS)
        args[a[3:end]] = ARGS[i+1]; global i += 2
    elseif a in ("-h", "--help")
        usage()
    else
        println(stderr, "unknown or valueless argument: $a"); exit(2)
    end
end

seedOffset = parse(Int, get(args, "seed-offset", "1000"))
nAgents    = parse(Int, get(args, "n", "1000"))

genSeed = nothing
wsK = wsP = nothing

if haskey(args, "manifest")
    haskey(args, "task") || (println(stderr, "--manifest requires --task"); exit(2))
    task = parse(Int, args["task"])
    # Header: task_id,reserve,depq,sigma,k,p,alpha,mu,lambdaI,lambdaC,arm_tag,...
    open(args["manifest"]) do fh
        header = split(strip(readline(fh)), ',')
        ci = Dict(h => j for (j, h) in enumerate(header))
        for req in ("task_id", "k", "p")
            haskey(ci, req) || (println(stderr, "manifest lacks column '$req'"); exit(2))
        end
        found = false
        for line in eachline(fh)
            f = split(strip(line), ',')
            length(f) < length(header) && continue
            if parse(Int, f[ci["task_id"]]) == task
                global wsK = parse(Int, f[ci["k"]])
                global wsP = parse(Float64, f[ci["p"]])
                found = true; break
            end
        end
        found || (println(stderr, "task_id $task not present in manifest"); exit(2))
    end
    genSeed = seedOffset + task
    @printf("from manifest: task=%d -> genSeed=%d, k=%d, p=%g\n", task, genSeed, wsK, wsP)
else
    haskey(args, "seed") || (println(stderr, "need --seed (or --manifest + --task)"); exit(2))
    genSeed = parse(Int, args["seed"])
    wsK = parse(Int, get(args, "k", "6"))
    wsP = parse(Float64, get(args, "p", "0.05"))
end

outbase = get(args, "out", "network")
mkpath(dirname(abspath(outbase)) )

# ── The regeneration. These two lines are the whole point. ───────────────────
Random.seed!(genSeed)
g = newman_watts_strogatz(nAgents, wsK, wsP)

# ── Determinism self-check: same seed must give the same graph ───────────────
Random.seed!(genSeed)
g2 = newman_watts_strogatz(nAgents, wsK, wsP)
if collect(edges(g)) != collect(edges(g2))
    println(stderr, "FAIL: regeneration is not deterministic under a fixed seed.")
    println(stderr, "      Something between the seed and the call is consuming the RNG.")
    exit(1)
end

# ── Structural check: Newman-Watts ADDS edges, so E[deg] = k(1+p) ────────────
# Classic Watts-Strogatz rewires and gives E[deg] = k. This is the check that
# catches the fig5 error class, where the figure used nx.watts_strogatz_graph
# while the model runs newman_watts_strogatz.
degs = degree(g)
meanDeg = sum(degs) / length(degs)
expectedNW = wsK * (1 + wsP)
expectedWS = float(wsK)
@printf("mean degree %.4f   Newman-Watts expects %.4f   (classic WS would be %.4f)\n",
        meanDeg, expectedNW, expectedWS)
if abs(meanDeg - expectedNW) > max(0.15, 0.05 * expectedNW)
    println(stderr, "WARN: mean degree is far from k(1+p). Check the graph generator.")
end

# ── Write ────────────────────────────────────────────────────────────────────
edgePath = outbase * "_edges.csv"
open(edgePath, "w") do io
    println(io, "src,dst")
    for e in edges(g)
        println(io, src(e), ",", dst(e))
    end
end

edgeHash = bytes2hex(sha256(read(edgePath)))[1:16]

metaPath = outbase * "_meta.csv"
open(metaPath, "w") do io
    println(io, "field,value")
    println(io, "genSeed,",       genSeed)
    println(io, "nAgents,",       nAgents)
    println(io, "wsK,",           wsK)
    println(io, "wsP,",           wsP)
    println(io, "nEdges,",        ne(g))
    println(io, "meanDegree,",    round(meanDeg, digits=6))
    println(io, "expectedNW,",    round(expectedNW, digits=6))
    println(io, "edgeHash,",      edgeHash)
    println(io, "juliaVersion,",  VERSION)
    println(io, "graphsVersion,", pkgversion(Graphs))
    println(io, "generatedAt,",   Dates.now())
    println(io, "generator,newman_watts_strogatz")
    println(io, "provenance,regenerated-from-seed-not-recorded-by-model")
end

@printf("wrote %s  (%d nodes, %d edges, hash %s)\n", edgePath, nv(g), ne(g), edgeHash)
@printf("wrote %s\n", metaPath)
