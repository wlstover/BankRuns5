################################################################################
#              Replacement Bank Run Model                                      #
#               (networked)                                                    #
#               May 2025                                                       #
#               John S. Schuler                                                #
#               Main Control Code                                              #
################################################################################

using Distributed
# If available, start workers with the local sysimage for faster load + shared pages.
const SYSIMAGE_PATH = joinpath(@__DIR__, "sysimage.so")

cores=16
if nprocs() < cores
    exeflags = isfile(SYSIMAGE_PATH) ?
        ["--project=$(Base.active_project())", "-J", SYSIMAGE_PATH] :
        ["--project=$(Base.active_project())"]
    addprocs(cores - nprocs(); exeflags=exeflags)
end
cores = nprocs()
# Load packages on all workers after they are added.
@everywhere using Distributions
@everywhere using Random
@everywhere using LinearAlgebra

@everywhere using CSV
@everywhere using DataFrames
@everywhere using Graphs
@everywhere using StatsBase
@everywhere using JLD2
@everywhere using Dates
#@everywhere workerCore=1

# Broadcast command-line args to all workers (workers don't get ARGS by default).
const CLI_ARGS = copy(ARGS)
@everywhere const CLI_ARGS = $CLI_ARGS

# Type-assignment rule for the cultural warm-up, set by scripts/run_all.sh
# --assignment. "warmup" is the model as published; "random" and "reverse" are
# placebo arms that decouple cultural type from network position. Broadcast the
# same way as CLI_ARGS because workers do not inherit ENV modifications made
# after addprocs. See functions4.jl modelGen for what each rule does.
const ASSIGN_RULE = let r = strip(get(ENV, "BANKRUN_ASSIGN_RULE", ""))
    isempty(r) ? "warmup" : String(r)     # empty export == absent; see MC_DEPTH
end
if !(ASSIGN_RULE in ("warmup", "random", "reverse"))
    error("BANKRUN_ASSIGN_RULE must be warmup|random|reverse, got \"$ASSIGN_RULE\"")
end
@everywhere const ASSIGN_RULE = $ASSIGN_RULE
println("assignment rule: ", ASSIGN_RULE)


# major parameters
#
# Monte Carlo depth: the number of clone-and-resimulate draws each agent runs
# per decision (functions4.jl:423,433). Set by scripts/run_all.sh --depth.
#
# ⚠️ DEFAULT LOWERED 1000 -> 100 on 2026-08-13. This is a modelling change, not
# just a speed knob. The decision rule is P̂_WD > P̂_stay, and both sides are
# means of `depth` Bernoulli draws, so the Monte Carlo standard error scales as
# 1/sqrt(depth): ~0.016 at depth=1000 against ~0.050 at depth=100, i.e. ~3.2x
# noisier. Agents whose two probabilities are close will flip decisions more
# often, which injects noise into the cascade itself. The sign of the effect on
# aggregate P(run) is not obvious a priori and should be measured, not assumed.
#
# ⚠️ The 2026-04 production sweep ran at depth=1000. Results produced at a
# different depth are NOT directly comparable to it. `depth` is recorded in the
# manifest and in the parameter dump so any comparison can condition on it.
# Parsed once on the master and broadcast, rather than each worker reading ENV
# for itself — same pattern as ASSIGN_RULE below. If workers resolved it
# independently, a divergent environment on one node would give that node's
# agents a different decision precision, silently and unrecoverably.
# `get(ENV, k, default)` returns "" for a SET-BUT-EMPTY variable, not the
# default — and SLURM --export=ALL,FOO= propagates exactly that. Treat empty as
# absent so an empty export falls back instead of killing the job.
const MC_DEPTH = let d = strip(get(ENV, "BANKRUN_MC_DEPTH", ""))
    isempty(d) && (d = "100")
    n = tryparse(Int, d)
    (n === nothing || n < 1) && error("BANKRUN_MC_DEPTH must be a positive integer, got \"$d\"")
    n
end
@everywhere depth::Int64 = $MC_DEPTH
println("Monte Carlo depth: ", MC_DEPTH)

@everywhere include("objects.jl")

@everywhere include("warmup.jl")

@everywhere include("functions4.jl")

for c in 2:cores
    @spawnat c myCore(c)
end
sleep(5)

#println(depth)
# now, we summarize the model  

# model initialization
# generate the agents and their network 
# generate their deposits
# generate the bank 

# now the model begins and an exogenous number of agents withdraw

# each agent observes the percentage of its neighbors that have withdrawn
# and takes this as a random sample of the population
# the agent then calculates its probability of getting its full deposit back 
# while randomizing over which agents withdraw
# and its own place in line 

# now, the structs are generated once and for all
# so we can use processes based parallelism 

# first, check if there are any jld2 files in the data directory
dataDir = CLI_ARGS[1]
@everywhere dataDir = $dataDir
#@everywhere dataDir="/Users/l25-n05917-res/ResearchCode/BankRunDataNew"
# If this is a fresh run, run the parameter generation code

# bring in the parameter generation code
# define jointFrame to keep global scope
#jointFrame=DataFrame()
# check if there is a jld2 file in the data directory
#jld2_files = readdir(dataDir, join=true)
#jld2_files = filter(file -> occursin(".jld2", file), jld2_files)
#if isempty(jld2_files)
# if there are no jld2 files, we need to generate the parameters
if myid() == 1
    include("parameterGen.jl")
end
# if there are jld2 files, we need to load the parameters
#@everywhere include("restart.jl")




# Work queue for distributed sweep: each worker pulls a row, runs, and checks it off.
coreDict=Dict()
resultDict=Dict()
rowDict=Dict()
for j in 2:cores
    coreDict[j]=nothing
end
#workerCore=1
#modelCall()
#exit()
# how many rows do we have in the control file?
while sum(jointFrame.completed) < size(jointFrame,1)
        for c in keys(coreDict)
            #println(sum(jointFrame.completed))
            #println("Core")
            #println(c)
            #println(coreDict[c])
            #println(isReady(coreDict[c]))
            #println(isnothing(coreDict[c]))
            #readline()
            if isnothing(coreDict[c])
                # if the core dictionary is nothing, we send it the parameters
                #println("Sending Parameters")
                #println("core")
                #println(c)
                #println(coreDict[c])
                # read parameters from the first row
                # step 1: get the index of the first non-started row
                
                coreDict[c]=@spawnat c modelCall()
                #println(coreDict[c])
                #println(resultDict==:complete)
            elseif isReady(coreDict[c])
                #println("Ready")
                #println(coreDict[c])
                coreDict[c]=fetch(coreDict[c])
                #println(coreDict[c])
                #println(sum(jointFrame.completed) < size(jointFrame,1))
                #println(sum(jointFrame.completed))
            end
        end    
end
# Belt and braces behind the functions4.jl write/checkOff reorder (2026-08-19).
# The loop above exits on sum(completed), which a worker sets from inside
# modelCall. Falling straight off the end of the script lets Julia tear down
# the pool while a worker still holds an unfinished call, so drain every
# outstanding future first. Bounded: at this point no row is left to pull, so
# each in-flight call either finishes its current run or returns immediately
# on a nothing from rowPull.
for c in keys(coreDict)
    if coreDict[c] isa Future
        wait(coreDict[c])
    end
end
CSV.write(dataDir*"/"*"bankRunParametersFin.csv",jointFrame[:,[:key,:started,:completed]],writeheader=false,append=true)
