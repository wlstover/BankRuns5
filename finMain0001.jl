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


# major parameters
@everywhere depth::Int64=1000

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
CSV.write(dataDir*"/"*"bankRunParametersFin.csv",jointFrame[:,[:key,:started,:completed]],writeheader=false,append=true)
