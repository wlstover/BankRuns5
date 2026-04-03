################################################################################
#              Replacement Bank Run Model                                      #
#               (networked)                                                    #
#               May 2025                                                       #
#               John S. Schuler                                                #
#               Parameter Sweep Generation Code                                #
################################################################################
#using StatsBase
#using DataFrames
#using JLD2
#using Dates
#using CSV
#using Random
#using Distributions
#using Graphs

# we need to sweep for parameters with the following behavior:
# Under the assumption of perfect information, the probability of bank failure is 0. 



##### PARAMETERS ######
# SEED
# AGENT COUNT
# WITHDRAWAL PERIODS :number of periods over which exogenous withdrawals become manifest
# search DEPTH (number or simulation rounds agents run when predicting probability
#       of default)
# RESERVE RATIO
# DEPOSIT DISTRIBUTION OBJECT

# Graph OBJECT
# Types are Watts-Strogatz, Barabasi-Albert, Erdos-Renyi, and complete
# and a vector of the needed parameters for each
# GRAPHS for each graph, a and b in (0,1)

genSeed=parse(Int, CLI_ARGS[2])
Random.seed!(genSeed)

# how many model initializations to run?
seedRun=5
# and how many times to run each initialization?
runSize=10


#agtCnts=cat(collect(10:10:100),
#            collect(100:100:1000),
#            collect(1000:1000:5000),dims=1)

agtCnts=[1000]
#reserveRatio=collect(.05:.05:.2)
#reserveRatio=[.12,.125,.13,.135,.14,.145,.15]
#depositDistributions=Distribution[Pareto(.5,10),Pareto(1.0,10),Pareto(1.5,10),Pareto(2.0,10),Pareto(2.5,10)]
reserveRatio=parse(Float64, CLI_ARGS[3])


# now we need the deposit insurance quantile
depQuantile=parse(Float64, CLI_ARGS[4])

# Watts-Strogatz network parameters
ws_k=parse(Int, CLI_ARGS[8])
ws_p=parse(Float64, CLI_ARGS[9])

# Warm-up learning rate (α): controls how quickly agents adopt neighbor opinions.
# High α → fast cultural homogenisation → collectivist λ distribution.
# Low α  → slow convergence → individualist λ distribution.
warmupAlpha=parse(Float64, CLI_ARGS[10])

# Two-type population parameters for the {μ, λ_I, λ_C} framework.
# fracIndividualists (μ): fraction of agents assigned type I.
#   Top-μ fraction by warm-up λ score → type I; rest → type C.
# lambdaI (λ_I): signal weight for individualists  (lower → relies on own MC).
# lambdaC (λ_C): signal weight for collectivists   (higher → follows social signal).
# Theoretical prediction: λ_I < λ_C → s*_I > s*_C (individualists withdraw only
#   at a stronger signal; collectivists are tipped more easily by aggregate runs).
fracIndividualists=parse(Float64, CLI_ARGS[11])
lambdaI=parse(Float64, CLI_ARGS[12])
lambdaC=parse(Float64, CLI_ARGS[13])

function paretoGen(alpha)
    return Pareto(alpha,10)
end

function logNormalGen(mu, sigma)
    return LogNormal(mu, sigma)
end



# now generate deposit distribution from parameters
# logNorm
if CLI_ARGS[5]=="Pareto"
    depDist=paretoGen(parse(Float64, CLI_ARGS[6]))
elseif CLI_ARGS[5]=="LogNormal"
    depDist=logNormalGen(parse(Float64, CLI_ARGS[6]), parse(Float64, CLI_ARGS[7]))
end    
# Pareto



#depositDistributions=paretoGen.(collect(.5:.5:2.5))
#depositDistributions=logNormalGen.([1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0],collect(1:1:10))
depositDistributions=[depDist]
depositInsuranceQuantile=[depQuantile]
# For now we run a single fixed network per sweep (change here to vary networks).
graphParams1=[ws_k]
graphParams2=[ws_p]
graphTypes=SimpleGraph{Int64}[newman_watts_strogatz(agtCnts[1], ws_k, ws_p)]

#exogenousProb=Distribution[Binomial(1000,0.1),Binomial(1000,.2),Binomial(1000,.3)]
exogenousProb=Distribution[truncated(Geometric(0.1),0,1000)]
seed1=repeat(sample(1:1000000,seedRun,replace=false),seedRun)
seedIterations=DataFrame(iteration=1:runSize)
seedFrame=DataFrame(seed1=seed1)
depFrame=DataFrame(depositDist=depositDistributions)
graphFrame=DataFrame(network=graphTypes,graphParams1=graphParams1,graphParams2=graphParams2)
exogProbFrame=DataFrame(withdrawRV=exogenousProb)
reserveFrame=DataFrame(reserveRatio=reserveRatio)
depositInsuranceFrame=DataFrame(depositInsuranceQuantile=depositInsuranceQuantile)
warmupAlphaFrame=DataFrame(warmupAlpha=[warmupAlpha])
twoTypeFrame=DataFrame(fracIndividualists=[fracIndividualists],
                       lambdaI=[lambdaI],
                       lambdaC=[lambdaC])
# Full parameter grid for the sweep.
jointFrame=crossjoin(seedFrame,seedIterations,depFrame,graphFrame,exogProbFrame,reserveFrame,depositInsuranceFrame,warmupAlphaFrame,twoTypeFrame)

# now we need to generate the parameters
jointFrame.seed2=sample(1:1000000,size(jointFrame,1),replace=false)
jointFrame.key=string(Dates.now())*"-".*string.(jointFrame.seed1).*"-".*string.(jointFrame.seed2)
jointFrame.started.=false
jointFrame.completed.=false
save_object(dataDir*"/key"*string(genSeed)*string(Dates.now())*".jld2", jointFrame)
println(jointFrame)
# subset to 16 rows
#jointFrame=jointFrame[1:30,:]
CSV.write(dataDir*"/"*"bankRunParametersInit.csv",jointFrame[:,[:seed1,:iteration,:graphParams1,:graphParams2,:reserveRatio,:depositInsuranceQuantile,:warmupAlpha,:fracIndividualists,:lambdaI,:lambdaC,:seed2,:key]],writeheader=false,append=true)
logNormal=DataFrame(params.(jointFrame.depositDist))
rename!(logNormal,:1 => :mu,:2 => :sigma)
CSV.write(dataDir*"/"*"bankRunlogNormal.csv",logNormal,writeheader=false,append=true)
geometric=DataFrame(params.(jointFrame.withdrawRV))
rename!(geometric,:1 => :p,:2 => :s0,:3 => :s1)
CSV.write(dataDir*"/"*"bankRunGeometric.csv",geometric,writeheader=false,append=true)
