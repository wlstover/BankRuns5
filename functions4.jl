# initialization functions

# Concentration parameter for within-type Beta distributions of individualism λ.
# Each agent draws λ ~ Beta(mean×κ, (1-mean)×κ) from their type's distribution.
# κ = 20 → σ ≈ 0.09 for a type mean of 0.5, providing within-type heterogeneity
# while keeping the distribution tightly peaked near λ_I or λ_C.
const LAMBDA_CONC = 20.0


function modelGen(key::String,
                  seed1::Int64,
                  seed2::Int64,
                  agtCnt::Int64,
                  probThresh::Float64,
                  network::SimpleGraph{Int64},
                  depositDistribution::Distribution,
                  reserveRatio::Float64,
                  depositInsurance::Float64,
                  exogProb::Distribution,
                  warmupAlpha::Float64,
                  fracIndividualists::Float64,
                  lambdaI::Float64,
                  lambdaC::Float64)
    # ---- Warm-up phase ----
    # Run Flache-Macy cultural dynamics; produces a continuous λ score per agent
    # reflecting resistance to social influence (higher = more individualist).
    # Uses seed1 internally; RNG is reset below so deposit draws are unaffected.
    lambdas_warmup = warmup(agtCnt, network, seed1; alpha=warmupAlpha)

    # ---- Type assignment ----
    # Rank agents by warm-up λ (descending). The top fracIndividualists (μ)
    # fraction → type I; the rest → type C.  Warm-up cultural position
    # determines who belongs to which type; μ controls how many.
    #
    # ⚠️ PLACEBO ARMS (added 2026-08-13; ASSIGN_RULE, default "warmup", is the
    # published model and is bit-identical to the previous code path).
    #
    # The warm-up assigns high resistance scores to agents sitting on cultural
    # BOUNDARIES, and those agents become type I. So individualism and bridge
    # position are the same variable by construction, and varying μ moves two
    # things at once: how many agents weight private signals heavily (the
    # cultural channel we claim) and how many inter-cluster bridges are held by
    # low-λ agents (a pure topology channel). The composition result is jointly
    # attributable to both, and Chapter 2 cannot arbitrate — it has no
    # composition variation at all.
    #
    #   warmup  — rank by warm-up λ (the model as published)
    #   random  — uniformly random type assignment; warm-up score ignored
    #   reverse — bottom-μ by warm-up λ (cluster interiors) become type I
    #
    # Gradient survives under `random` ⇒ the effect is signal weighting, i.e.
    # culture, as claimed. Gradient dies ⇒ it required individualists on
    # bridges, and the cultural reading is overstated.
    #
    # The warm-up above STILL RUNS in every arm and its output is still logged
    # as `warmupLambda`; only its use in ranking changes. That keeps the RNG
    # stream and every downstream draw identical, so the arms are comparable
    # seed-for-seed. `lambdas_warmup` feeds nothing else — sortIdx here and the
    # diagnostic column below — so this is a clean single-channel intervention.
    nI = round(Int, fracIndividualists * agtCnt)
    assignRule = @isdefined(ASSIGN_RULE) ? ASSIGN_RULE : "warmup"
    sortIdx = if assignRule == "random"
        # seed1+2: distinct from the warm-up (seed1) and the λ draws (seed1+1),
        # so the permutation is reproducible without perturbing either.
        Random.seed!(seed1 + 2)
        randperm(agtCnt)
    elseif assignRule == "reverse"
        sortperm(lambdas_warmup, rev=false)
    else
        sortperm(lambdas_warmup, rev=true)
    end
    isI = falses(agtCnt)
    nI > 0 && (isI[sortIdx[1:nI]] .= true)

    # ---- Per-agent λ draws ----
    # Each agent draws a continuous λ from a Beta distribution centred on
    # their type mean (λ_I or λ_C), with shared concentration LAMBDA_CONC:
    #   Type I: Beta(λ_I·κ,  (1−λ_I)·κ)  — peaks near λ_I, E[λ] = λ_I
    #   Type C: Beta(λ_C·κ,  (1−λ_C)·κ)  — peaks near λ_C, E[λ] = λ_C
    # Clamp means away from {0,1} to keep Beta parameters valid.
    # seed1+1 gives a reproducible stream independent of both warm-up and deposits.
    Random.seed!(seed1 + 1)
    distI = Beta(clamp(lambdaI, 0.01, 0.99) * LAMBDA_CONC,
                 clamp(1.0 - lambdaI, 0.01, 0.99) * LAMBDA_CONC)
    distC = Beta(clamp(lambdaC, 0.01, 0.99) * LAMBDA_CONC,
                 clamp(1.0 - lambdaC, 0.01, 0.99) * LAMBDA_CONC)
    agentLambdas = [isI[i] ? rand(distI) : rand(distC) for i in 1:agtCnt]
    agentTypes   = [isI[i] ? "I" : "C"                 for i in 1:agtCnt]

    # ---- Deposits ----
    # Reset to seed1 so deposit draws are unaffected by warm-up or λ draws.
    Random.seed!(seed1)
    deposits=rand(depositDistribution,agtCnt)

    # ---- Agent construction ----
    # individualism holds the agent's drawn λ (continuous, from Beta).
    agtList::Array{Agent}=Agent[]
    for i in 1:agtCnt
        push!(agtList,Agent(i,deposits[i],true,agentLambdas[i]))
    end

    # Log: deposit, drawn λ, raw warm-up score, and type label.
    # warmupLambda captures the cultural formation history;
    # individualism is the signal weight actually used in bank-run decisions.
    agtDF=DataFrame(key=key,idx=1:agtCnt,deposit=deposits,
                    individualism=agentLambdas,
                    warmupLambda=lambdas_warmup,
                    agentType=agentTypes)

    CSV.write(dataDir*"/"*"agents"*string(workerCore)*".csv",agtDF,writeheader=false,append=true)

    bankingList::Array{Agent}=Agent[]

    for agt in agtList
            push!(bankingList,agt)
    end
    # generate the bank
    theBank=Bank(
        reserveRatio*sum(deposits),
        bankingList,
        Agent[]
    )
    mod=Model(
        key,
        agtList,
        reserveRatio,
        theBank,
        depositInsurance,
        seed1,
        seed2,
        depositDistribution,
        network,
        probThresh,
        exogProb
    )
    return mod
end

function neighborList(mod::Model,agt::Agent)
    # get the neighbors of the agent
    neighbors=all_neighbors(mod.network,agt.idx)
    # get the list of agents that are neighbors
    neighborAgents=Agent[]
    for n in neighbors
        push!(neighborAgents,mod.agtList[n])
    end
    return neighborAgents
end

function deposit(agt::Agent)
    return agt.deposit
end
function deposit(agt::simAgent)
    return agt.deposit
end

# now the cloning function
function clone(mod::Model)
    # clone the model
   cloneAgtList::Array{simAgent}=simAgent[]
    for agt in mod.agtList
        push!(cloneAgtList,simAgent(agt.idx,agt.deposit,agt.banked,agt.individualism))
    end

    theBank=simBank(
        mod.theBank.vault,
        simAgent[],
        simAgent[]
    )
    for agt in cloneAgtList
        if agt.banked
            push!(theBank.bankingList,agt)
        else
            push!(theBank.withdrawHistory,agt)
        end
    end
    return simModel(
        cloneAgtList,
        theBank,
        mod.depositInsurance,
        mod.depositDistribution
    )
end

function clone(mod::simModel)
    # clone the model
    cloneAgtList::Array{simAgent}=simAgent[]
    for agt in mod.agtList
        push!(cloneAgtList,simAgent(agt.idx,agt.deposit,agt.banked,agt.individualism))
    end

    theBank=simBank(
        mod.theBank.vault,
        simAgent[],
        simAgent[]
    )
    for agt in cloneAgtList
        if agt.banked
            push!(theBank.bankingList,agt)
        else
            push!(theBank.withdrawHistory,agt)
        end
    end
    return simModel(
        cloneAgtList,
        theBank,
        mod.depositInsurance,
        mod.depositDistribution
    )
end

# and a function to perform the withdrawal
function withdraw(mod::Model,agt::Agent)
    # what is the status of the deposit insurance? 
    # the deposit insurance is either a quantile (0 to 1) of the deposit distribution
    # or if not in this range, we apply the adaptive deposit insurance scheme
    maxDepositInsurance=0.0
    # what is the maximum deposit insurance payout?
    if !(0.0<= mod.depositInsurance < 1.0)
        if length(mod.theBank.withdrawHistory)==0
            maxDepositInsurance=0.0
        else
            # get the maximum deposit insurance payout
            # this is the maximum deposit of the agents that have withdrawn
            # and is the adaptive deposit insurance scheme
            # we need to check if there are any agents that have withdrawn
            # if not, we set the maximum deposit insurance to 0.0
            # otherwise, we set it to the maximum deposit of the agents that have withdrawn
            # get the maximum deposit insurance payout
            maxDepositInsurance=maximum(deposit.(mod.theBank.withdrawHistory))
        end
    else
        # if the deposit insurance is a quantile, we apply the adaptive deposit insurance scheme
        # get the quantile of the deposit distribution
        maxDepositInsurance=quantile(mod.depositDistribution,mod.depositInsurance)
    end

    # withdraw the agent
    agt.banked=false
    # add the agent to the withdraw history
    push!(mod.theBank.withdrawHistory,agt)
    # remove the agent from the banking list
    mod.theBank.bankingList=filter(x->x.idx!=agt.idx,mod.theBank.bankingList)
    # what does the agent get out?
    if agt.deposit>mod.theBank.vault
        agtReturn=max(0.0,mod.theBank.vault,min(agt.deposit,maxDepositInsurance))
    else
        agtReturn=agt.deposit
    end
    mod.theBank.vault-=agt.deposit
    return agtReturn
end

function withdraw(mod::simModel,agt::simAgent)
        # what is the status of the deposit insurance? 
    # the deposit insurance is either a quantile (0 to 1) of the deposit distribution
    # or if not in this range, we apply the adaptive deposit insurance scheme
    maxDepositInsurance=0.0
    # what is the maximum deposit insurance payout?
    if !(0.0<= mod.depositInsurance < 1.0)
        if length(mod.theBank.withdrawHistory)==0
            maxDepositInsurance=0.0
        else
            # get the maximum deposit insurance payout
            # this is the maximum deposit of the agents that have withdrawn
            # and is the adaptive deposit insurance scheme
            # we need to check if there are any agents that have withdrawn
            # if not, we set the maximum deposit insurance to 0.0
            # otherwise, we set it to the maximum deposit of the agents that have withdrawn
            # get the maximum deposit insurance payout
            maxDepositInsurance=maximum(deposit.(mod.theBank.withdrawHistory))
        end
    else
                # if the deposit insurance is a quantile, we apply the adaptive deposit insurance scheme
        # get the quantile of the deposit distribution
        maxDepositInsurance=quantile(mod.depositDistribution,mod.depositInsurance)
    end

    
    # withdraw the agent
    agt.banked=false
    # add the agent to the withdraw history
    push!(mod.theBank.withdrawHistory,agt)
    # remove the agent from the banking list
    mod.theBank.bankingList=filter(x->x.idx!=agt.idx,mod.theBank.bankingList)
    # what does the agent get out?
    if agt.deposit>mod.theBank.vault
        agtReturn=max(0.0,mod.theBank.vault,min(agt.deposit,maxDepositInsurance))
    else
        agtReturn=agt.deposit
    end
    mod.theBank.vault-=agt.deposit
    # update the bank vault
    return agtReturn
end


# we need a function to withdraw exogenously
function exogWithdrawals(mod::Model)
    # get the number of agents that will withdraw
    numWithdrawals=rand(mod.exogProb,1)[1]
    # get the list of agents that will withdraw
    withdrawList=sample(mod.agtList,numWithdrawals,replace=false)
    # set the banked status to false
    global dataDir
    global workerCore
    for agt in withdrawList
        #println("Exogenous Withdrawal Agent ",agt.idx)
        withdraw(mod,agt)
        reportRow=DataFrame(key=mod.key,agent=agt.idx,exogenous=true,deposit=agt.deposit,tick=0,vault=mod.theBank.vault)
        CSV.write(dataDir*"/"*"bankRunExogenous"*string(workerCore)*".csv",reportRow,writeheader=false,append=true)
    end
    return withdrawList
end

function index(agt::Agent)
    return agt.idx
end
function index(agt::simAgent)
    return agt.idx
end

function subModelRun(mod::simModel,agt::Agent,withdrawingAgents::Array{Agent},additionalWithdrawals::Int64)
    # Phase 1: force withdrawals of observed (exogenous) neighbors in the submodel.
    #println("Agent ",agt.idx," sees ",length(withdrawingAgents)," withdrawing agents and anticipates ",additionalWithdrawals," additional withdrawals.")
    for idx in index.(withdrawingAgents)
        # get the agent
        currAgt=mod.agtList[idx]
        # withdraw the agent
        withdraw(mod,currAgt)
    end
    stillBanking=Random.shuffle(mod.theBank.bankingList)
    # Phase 2: remove additional agents to reflect expected endogenous withdrawals.
    # if the current agent is among them, we skip it. 
    numWithdrawn::Int64=0
    idx::Int64=1
    #println(additionalWithdrawals)
    while numWithdrawn < additionalWithdrawals && idx <= length(stillBanking)
        if stillBanking[idx].idx!=agt.idx
            withdraw(mod,stillBanking[idx])
            numWithdrawn+=1
        end
        idx+=1
    end
    # Now simulate the focal agent withdrawing.
    #println("Chk")
    #println(agt in mod.agtList
    currAgt=filter(x->x.idx==agt.idx,mod.agtList)[1]
    result=withdraw(mod,currAgt)
    #println("Agent ",agt.idx," Deposit was ",agt.deposit," with result ", result)
    return (result,result < agt.deposit)
end

# now the main model function
function modelRun(mod::Model)
    runState::Bool=false
    # set the seed
    Random.seed!(mod.seed2)



    exogWithdrawals(mod)
    
    # make a copy of the model
    simModel=clone(mod)

    # now, whenever an agent withdraws, we reset a state variable since this means all other agents will
    # re-examing their decision to bank
    halt::Bool=false
    # now, randomize the order of the agents still banking
    t=0
    if mod.theBank.vault<=0.0
        # if the bank is bankrupt, we need to stop the simulation
        runState=true
        #println("Bankrupt at tick ",t," with vault ",mod.theBank.vault)
        return (runState, runSize(mod)...)
    end
    while !halt && !runState
        halt=true
        t=t+1
        stillBanking=Random.shuffle(mod.theBank.bankingList)
        # each agent observes the percentage of its neighbors that have withdrawn
        for agt in stillBanking
            #println("Running Agent ",agt.idx)
            # get the neighbors of the agent
            neighbors=neighborList(mod,agt)
            #println("Agent ",agt.idx," has ",length(neighbors)," neighbors")
            withdrawnNeighbors::Array{Agent}=Agent[]
            for n in neighbors
                if !n.banked
                    push!(withdrawnNeighbors,n)
                end
            end
            #println("Agent ",agt.idx," has ",length(withdrawnNeighbors)," withdrawn neighbors")
            # now calculate the proportion of neighbors that have withdrawn
            propWithdrawn = isempty(neighbors) ? 0.0 : (length(withdrawnNeighbors) / length(neighbors))
            #println("Prop Withdrawn for Agent ",agt.idx," is ",propWithdrawn)
            # Infer total withdrawals in population from neighbor sample.
            totalWithdrawn=round(Int64,propWithdrawn*length(mod.agtList))
            #println("Total Withdrawn for Agent ",agt.idx," is ",totalWithdrawn)
            # Draw possible total withdrawals and convert to additional (endogenous) count.
            totalWithdrawnRaw = totalWithdrawn
            totalWithdrawn = clamp(totalWithdrawn, 0, length(mod.agtList)-1)
            if totalWithdrawn != totalWithdrawnRaw
                println(
                    "Clamp triggered. key=", mod.key,
                    " totalWithdrawnRaw=", totalWithdrawnRaw,
                    " totalWithdrawn=", totalWithdrawn,
                    " N=", length(mod.agtList),
                    " neighbors=", length(neighbors),
                    " withdrawnNeighbors=", length(withdrawnNeighbors),
                    " propWithdrawn=", propWithdrawn
                )
            end
            totalWithdrawnPoint = totalWithdrawn  # clamped neighbor-signal point estimate
            # Draw from the untruncated exogenous distribution — the agent's own prior
            # belief about total population withdrawals, independent of local observation.
            # Blend with the neighbor-signal point estimate via individualism λ:
            #   λ=0 (individualist): ignores neighbor signal, relies on own MC prior.
            #   λ=1 (collectivist):  follows neighbor signal, ignores own MC prior.
            # Low λ_I (0.1–0.3) → individualists weight social signal weakly → self-reliant.
            # High λ_C (0.5–0.9) → collectivists weight social signal heavily → herd behavior.
            mcDraws = rand(mod.exogProb, depth)
            λ = agt.individualism
            blendedTotal = round.(Int64, (1.0 .- λ) .* Float64.(mcDraws) .+ λ .* Float64(totalWithdrawnPoint))
            blendedTotal = clamp.(blendedTotal, 0, length(mod.agtList)-1)
            additionalWithdrawals=max.(0, blendedTotal .- length(withdrawnNeighbors))
            # Monte Carlo: compare outcomes if the agent withdraws now vs. stays.
            subModResults=[]
            initWithdrawResults=[]
            global depth
            #println("Simulating for agent ",agt.idx)
            for k in 1:depth
                #println("Simulating for agent ",agt.idx)
                push!(subModResults,subModelRun((clone(simModel),agt,withdrawnNeighbors,additionalWithdrawals[k])...))
                baseMod=clone(simModel)
                currAgt=filter(x->x.idx==agt.idx,baseMod.agtList)[1]
                push!(initWithdrawResults,withdraw(baseMod,currAgt))
            end
            # now, have the agent calculate its probability of getting less than its deposit
            resultsStay::Array{Bool}=Bool[]
            for el in subModResults
                push!(resultsStay,el[2])
            end
            resultsWD::Array{Bool}=Bool[]
            for el in initWithdrawResults
                push!(resultsWD,el < agt.deposit)
            end
            #println("submodel results for agent ",agt.idx," are ",subModResults)
            #println("initial withdrawal results for agent ",agt.idx," are ",initWithdrawResults)

            # now calculate the probability of getting less than its deposit
            # should this be 1-?
            probLessThanDepositStay=1-mean(resultsStay)
            probLessThanDepositWD=1-mean(resultsWD)
            # now if the probability is greater than the threshold, withdraw
            global dataDir
            if probLessThanDepositWD > probLessThanDepositStay || probLessThanDepositWD==0.0
                #println("Endogenous Withdawal Agent ",agt.idx," at p(WD)=",probLessThanDepositWD, " where deposit was ",agt.deposit," and vault was ",mod.theBank.vault," and P(Stay)=",probLessThanDepositStay, " at tick=",t)
                withdraw(mod,agt)
                reportRow=DataFrame(key=mod.key,agent=agt.idx,withdraw=true,deposit=agt.deposit,
                tick=t,vault=mod.theBank.vault,wdProb=probLessThanDepositWD,stayProb=probLessThanDepositStay)
                CSV.write(dataDir*"/"*"bankRunEndogenous"*string(workerCore)*".csv",reportRow,writeheader=false,append=true)
                halt=false
            else
                #println("No Endogenous Withdawal Agent ",agt.idx," at p(WD)=",probLessThanDepositWD, " where deposit was ",agt.deposit," and vault was ",mod.theBank.vault," and P(Stay)=",probLessThanDepositStay, " at tick=",t)
                reportRow=DataFrame(key=mod.key,agent=agt.idx,withdraw=false,deposit=agt.deposit,
                tick=t,vault=mod.theBank.vault,wdProb=probLessThanDepositWD,stayProb=probLessThanDepositStay)
                CSV.write(dataDir*"/"*"bankRunEndogenous"*string(workerCore)*".csv",reportRow,writeheader=false,append=true)
            end

            if mod.theBank.vault<=0.0
                # if the bank is bankrupt, we need to stop the simulation
                runState=true
                break
            end
            #readline()   
        end
        #if  !halt && !runState
        #    println("Halting at tick ",t," with vault ",mod.theBank.vault)
        #end
    end
    return (runState, runSize(mod)...)
end

# |S*| — the realised withdrawal set. The cascade converges to a FRACTIONAL
# withdrawal set (the least fixed point of the best-response map, REPOSITORY_REVIEW
# §9.7); `runState` only records whether that set drained the vault. Reporting the
# binary alone throws away the quantity the policy discussion actually needs — how
# much liquidity a run consumes — and is why no run-size exhibit exists.
# withdrawHistory accumulates every agent that left, exogenous and endogenous alike.
function runSize(mod::Model)
    n = length(mod.theBank.withdrawHistory)
    d = isempty(mod.theBank.withdrawHistory) ? 0.0 :
        sum(a.deposit for a in mod.theBank.withdrawHistory)
    return (n, d)
end

# now the parallelization functions
    

function isReady(arg::Future)
    return isready(arg)
end
function isReady(arg::Symbol)
    return false
end
function isReady(arg::Nothing)
    return false
end

# Lock used by the master process to avoid row assignment races.
const rowLock = ReentrantLock()

# we need a function that calls the model generation function from other workers and fetches the result
function rowPull()
    global jointFrame
    lock(rowLock)
    try
        startIndex = findfirst(!, jointFrame.started)
        if startIndex === nothing
            return nothing
        end
        jointFrame[startIndex, :started] = true
        return (jointFrame[startIndex, :], startIndex)
    finally
        unlock(rowLock)
    end
end

function checkOff(currentIndex)
    global jointFrame
    # check off the row
    jointFrame[currentIndex,:completed]=true
end

function modelCall()
    # pull the first row of data
        proc=@spawnat 1 rowPull()
        while !isReady(proc)
            sleep(1)
        end
        # now we need to fetch the result
        results=fetch(proc)
        if !isnothing(results)
            startIndex=results[1]
            currentIndex=results[2]
            mod=modelGen(startIndex[:key],
                         startIndex[:seed1],
                         startIndex[:seed2],
                                1000,
                                .1,
                                startIndex[:network],
                                startIndex[:depositDist],
                                startIndex[:reserveRatio],
                                startIndex[:depositInsuranceQuantile],
                                startIndex[:withdrawRV],
                                startIndex[:warmupAlpha],
                                startIndex[:fracIndividualists],
                                startIndex[:lambdaI],
                                startIndex[:lambdaC])
                rMod, nWithdrawn, depositWithdrawn = modelRun(mod)
                proc2=@spawnat 1 checkOff(currentIndex)
                while !isReady(proc2)
                    sleep(1)
                end
                # now we need to fetch the result              
                fetch(proc2)
        end
        # write out model results
        if !isnothing(results)
        # Widened 2026-08-13 from (key, result) to carry |S*|. Readers that
        # take only the first two columns are unaffected.
        resultRow=DataFrame(key=results[1][:key],result=rMod,
                            nWithdrawn=nWithdrawn,depositWithdrawn=depositWithdrawn)
        CSV.write(dataDir*"/"*"bankRunResults"*string(workerCore)*".csv",resultRow,writeheader=false,append=true)
        end

    return nothing
end

# we need a function to set a global variable for each worker indicating its core
function myCore(c)
    global workerCore
    workerCore=c
    #println("Worker Core is ",workerCore)
end
