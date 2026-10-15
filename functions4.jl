# initialization functions

# Concentration parameter for within-type Beta distributions of individualism λ.
# Each agent draws λ ~ Beta(mean×κ, (1-mean)×κ) from their type's distribution.
# κ = 20 → σ ≈ 0.09 for a type mean of 0.5, providing within-type heterogeneity
# while keeping the distribution tightly peaked near λ_I or λ_C.
const LAMBDA_CONC = 20.0


function modelGenTyped(key::String,
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

    logFull() && CSV.write(dataDir*"/"*"agents"*string(workerCore)*".csv",agtDF,writeheader=false,append=true)

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
    return mod, isI
end

# The model alone; modelGenTyped also returns the type flags (true = type I).
modelGen(args...) = modelGenTyped(args...)[1]

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
function exogWithdrawals(mod::Model; record=nothing)
    # get the number of agents that will withdraw
    numWithdrawals=rand(mod.exogProb,1)[1]
    # get the list of agents that will withdraw
    withdrawList=sample(mod.agtList,numWithdrawals,replace=false)
    # set the banked status to false
    global dataDir
    global workerCore
    for agt in withdrawList
        paid = withdraw(mod,agt)
        record === nothing || record!(record, agt.idx, paid)
        if logFull()
            reportRow=DataFrame(key=mod.key,agent=agt.idx,exogenous=true,deposit=agt.deposit,tick=0,vault=mod.theBank.vault)
            CSV.write(dataDir*"/"*"bankRunExogenous"*string(workerCore)*".csv",reportRow,writeheader=false,append=true)
        end
    end
    record === nothing || (record.nExog = length(withdrawList))
    return withdrawList
end

function index(agt::Agent)
    return agt.idx
end
function index(agt::simAgent)
    return agt.idx
end

function subModelRun(mod::simModel,agt::Agent,withdrawingAgents::Array{Agent},additionalWithdrawals::Int64;
                     skipWithdrawn::Bool=false)
    # Phase 1: force withdrawals of observed (exogenous) neighbors in the submodel.
    #
    # ⚠️ DOUBLE COUNT (found 2026-10-08). The submodel is cloned AFTER the
    # exogenous shock, so exogenously withdrawn neighbours are already out of it
    # (banked=false, deposit already off the vault). withdraw() does not check
    # `banked`, so replaying them here takes their deposit off the vault a second
    # time. skipWithdrawn=true (BANKRUN_FIX_DOUBLE_COUNT / BANKRUN_FRESH_CLONE)
    # skips them; the default keeps the published behaviour bit-for-bit.
    for idx in index.(withdrawingAgents)
        # get the agent
        currAgt=mod.agtList[idx]
        skipWithdrawn && !currAgt.banked && continue
        # withdraw the agent
        withdraw(mod,currAgt)
    end
    stillBanking=Random.shuffle(mod.theBank.bankingList)
    # Phase 2: remove additional agents to reflect expected endogenous withdrawals.
    # if the current agent is among them, we skip it. 
    numWithdrawn::Int64=0
    idx::Int64=1
    while numWithdrawn < additionalWithdrawals && idx <= length(stillBanking)
        if stillBanking[idx].idx!=agt.idx
            withdraw(mod,stillBanking[idx])
            numWithdrawn+=1
        end
        idx+=1
    end
    # Now simulate the focal agent withdrawing.
    currAgt=filter(x->x.idx==agt.idx,mod.agtList)[1]
    result=withdraw(mod,currAgt)
    return (result,result < agt.deposit)
end

# ---- Sparse sub-simulation (2026-10-15) ----
# A sub-simulation only needs the vault, who is still banked, and the deposits
# of the agents it withdraws, so it does not clone the model or rebuild the
# banking list on every withdrawal (Schuler's LargeSparseNetworkModel idea,
# BankRunsFinal). It reproduces subModelRun on a clone of the same state
# exactly: the same vault subtractions in the same order, the same insurance
# cap, and the same random draw (one shuffle of a vector of the same length;
# shuffle! consumes the RNG by length only). tests/test_switch_identity.jl
# checks this byte for byte; tests/test_sparse_submodel.jl checks it draw by draw.
struct SubState
    vault::Float64
    deposits::Vector{Float64}       # by agent idx
    banked::BitVector               # by agent idx
    bankedIdx::Vector{Int}          # banked agents in banking-list order
    nHistory::Int                   # withdrawals already in the state
    histMax::Float64                # largest deposit among them (-Inf if none)
    adaptive::Bool                  # adaptive insurance (depositInsurance outside [0,1))
    quantileCap::Float64            # quantile insurance cap otherwise
end

# The state clone() would produce: banking list and history are the banked and
# withdrawn agents in agent order, whatever order the source lists hold.
function SubState(agtList, vault::Float64, depositInsurance::Float64, depositDistribution)
    deps = [a.deposit for a in agtList]
    banked = BitVector([a.banked for a in agtList])
    out = [a.deposit for a in agtList if !a.banked]
    adaptive = !(0.0 <= depositInsurance < 1.0)
    return SubState(vault, deps, banked, [a.idx for a in agtList if a.banked],
                    length(out), isempty(out) ? -Inf : maximum(out), adaptive,
                    adaptive ? 0.0 : quantile(depositDistribution, depositInsurance))
end
SubState(mod::simModel) = SubState(mod.agtList, mod.theBank.vault, mod.depositInsurance, mod.depositDistribution)
SubState(mod::Model)    = SubState(mod.agtList, mod.theBank.vault, mod.depositInsurance, mod.depositDistribution)

# Same signature and result as subModelRun(clone(decisionModel), ...).
function subModelRunSparse(s::SubState, agt::Agent, withdrawingAgents::Array{Agent},
                           additionalWithdrawals::Int64; skipWithdrawn::Bool=false)
    vault, nHist, histMax = s.vault, s.nHistory, s.histMax
    removed = Int[]
    # Phase 1: replay the observed withdrawals (the double count when not skipped).
    for nb in withdrawingAgents
        i = nb.idx
        skipWithdrawn && !s.banked[i] && continue
        s.banked[i] && push!(removed, i)
        nHist += 1; histMax = max(histMax, s.deposits[i]); vault -= s.deposits[i]
    end
    # Phase 2: the anticipated additional withdrawals, in a random order.
    stillBanking = isempty(removed) ? copy(s.bankedIdx) : filter(i -> !(i in removed), s.bankedIdx)
    Random.shuffle!(stillBanking)
    numWithdrawn, j = 0, 1
    while numWithdrawn < additionalWithdrawals && j <= length(stillBanking)
        i = stillBanking[j]
        if i != agt.idx
            nHist += 1; histMax = max(histMax, s.deposits[i]); vault -= s.deposits[i]
            numWithdrawn += 1
        end
        j += 1
    end
    # Phase 3: the focal agent withdraws (withdraw()'s payout rule).
    cap = s.adaptive ? (nHist == 0 ? 0.0 : histMax) : s.quantileCap
    dep = s.deposits[agt.idx]
    result = dep > vault ? max(0.0, vault, min(dep, cap)) : dep
    return (result, result < agt.deposit)
end

# ---- Per-agent decision step ----
# Split out of modelRun on 2026-10-15 so each piece (and each future switch) lives
# in one function. The order of random draws is unchanged: beliefDraws (one
# rand(exogProb, depth)), then simulateStay (one shuffle per draw, inside
# subModelRun). The other three steps draw nothing.

# The neighbours who have withdrawn, and the neighbour-signal point estimate of
# total withdrawals: the withdrawn share of neighbours times N, clamped to [0, N-1].
function neighbourSignal(mod::Model, agt::Agent)
    neighbors = neighborList(mod, agt)
    withdrawnNeighbors::Array{Agent} = filter(n -> !n.banked, neighbors)
    nAgents = length(mod.agtList)
    propWithdrawn = isempty(neighbors) ? 0.0 : (length(withdrawnNeighbors) / length(neighbors))
    neighbourEstimateRaw = round(Int64, propWithdrawn * nAgents)
    neighbourEstimate = clamp(neighbourEstimateRaw, 0, nAgents - 1)
    if neighbourEstimate != neighbourEstimateRaw
        println(
            "Clamp triggered. key=", mod.key,
            " neighbourEstimateRaw=", neighbourEstimateRaw,
            " neighbourEstimate=", neighbourEstimate,
            " N=", nAgents,
            " neighbors=", length(neighbors),
            " withdrawnNeighbors=", length(withdrawnNeighbors),
            " propWithdrawn=", propWithdrawn
        )
    end
    return withdrawnNeighbors, neighbourEstimate
end

# The agent's own prior: `depth` draws of total population withdrawals,
# independent of what the agent observes (BANKRUN_BELIEF).
#   geometric (published): the exogenous withdrawal distribution, truncated
#              Geometric(0.1) on [0, 1000].
#   point:     Binomial(N−1, p0), Schuler's PointEstimateBelief without the
#              neighbour fraction (BankRunsFinal network.jl). Neighbour
#              information enters only through the λ blend, as in the rest of
#              the model (option (a), decided 2026-10-15). p0 = BANKRUN_BELIEF_P0.
function beliefDraws(mod::Model, depth::Integer; belief::String="geometric", p0::Float64=0.02)
    belief == "geometric" && return rand(mod.exogProb, depth)
    belief == "point" && return rand(Binomial(length(mod.agtList) - 1, p0), depth)
    error("unknown belief law \"$belief\"")
end

# Blend each prior draw with the social signal, then convert to the number of
# additional withdrawals the agent anticipates beyond those already out.
#   social = α·publicPoint + (1−α)·neighbourEstimate,   ω_t = λ·φ^(t−1)
# λ = agt.individualism is the weight on the social signal, so a higher λ is a
# more collectivist agent: λ_I (0.1–0.3) relies mostly on its own prior, λ_C
# (0.5–0.9) mostly follows the social signal. With α = 0 and φ = 1 (the
# defaults) this is the published expression, λ·neighbourEstimate.
function anticipatedWithdrawals(agt::Agent, priorDraws, neighbourEstimate, publicPoint,
                                alreadyOut, nAgents, t; pubAlpha, weightPhi)
    λ = agt.individualism
    ω = weightPhi == 1.0 ? λ : λ * weightPhi^(t-1)
    socialPoint = pubAlpha == 0.0 ? Float64(neighbourEstimate) :
        pubAlpha * Float64(publicPoint) + (1.0 - pubAlpha) * Float64(neighbourEstimate)
    blendedTotal = round.(Int64, (1.0 .- ω) .* Float64.(priorDraws) .+ ω .* socialPoint)
    blendedTotal = clamp.(blendedTotal, 0, nAgents - 1)
    return max.(0, blendedTotal .- alreadyOut)
end

# P(full deposit | stay): the share of sub-simulations, one per prior draw, in
# which the agent is paid in full when it withdraws after the anticipated others.
# Uses the sparse sub-simulation (identical results to subModelRun on clones).
function simulateStay(s::SubState, agt::Agent, withdrawnNeighbors::Array{Agent},
                      additionalWithdrawals; skipWithdrawn::Bool)
    lossStay = Bool[subModelRunSparse(s, agt, withdrawnNeighbors, additionalWithdrawals[k];
                                      skipWithdrawn=skipWithdrawn)[2] for k in eachindex(additionalWithdrawals)]
    return 1 - mean(lossStay)
end

# P(full deposit | withdraw now). Withdrawing now involves no random draw, so this
# is exactly 1.0 (the vault or the insurance cap covers the deposit) or 0.0.
# Until 2026-10-15 it was recomputed `depth` times with identical results.
# (withdraw()'s payout rule on the decision state, without a clone.)
function payoffIfWithdrawNow(s::SubState, agt::Agent)
    cap = s.adaptive ? (s.nHistory == 0 ? 0.0 : s.histMax) : s.quantileCap
    dep = s.deposits[agt.idx]
    received = dep > s.vault ? max(0.0, s.vault, min(dep, cap)) : dep
    return received < agt.deposit ? 0.0 : 1.0
end

# The decision rule (BANKRUN_TIEBREAK). All three withdraw when withdrawing now
# is strictly more likely to pay in full than staying; they differ at the margin.
#   legacy (published): also withdraw when even withdrawing now cannot pay in
#           full (P_WD == 0: salvage what is left). The monotonicity argument
#           in REPOSITORY_REVIEW.md §9.7 relies on this clause.
#   schuler: Schuler's BankRunsFinal certainty rule: never withdraw when staying
#           pays in full for sure (P_stay == 1); otherwise P_WD > P_stay.
#   strict: P_WD > P_stay only.
# P_WD is exactly 0 or 1 (payoffIfWithdrawNow), so schuler and strict make the
# same decisions: P_WD > P_stay already fails when P_stay == 1. Both differ from
# legacy only when the vault cannot cover the agent now (P_WD == 0), where they
# stay and legacy withdraws.
function decide(probFullDepositWD, probFullDepositStay; tiebreak::String="legacy")
    tiebreak == "legacy" &&
        return probFullDepositWD > probFullDepositStay || probFullDepositWD == 0.0
    tiebreak == "schuler" &&
        return probFullDepositStay != 1.0 && probFullDepositWD > probFullDepositStay
    tiebreak == "strict" && return probFullDepositWD > probFullDepositStay
    error("unknown tie-break rule \"$tiebreak\"")
end

# now the main model function
function modelRun(mod::Model; record=nothing)
    runState::Bool=false
    # set the seed
    Random.seed!(mod.seed2)



    exogWithdrawals(mod; record=record)
    
    # Post-shock snapshot that every decision simulates from (the "stale
    # clone"), unless BANKRUN_FRESH_CLONE. Held in sparse form (SubState).
    staleState=SubState(clone(mod))

    # Switch settings (parsed in finMain0001.jl; defaults in settings.jl, which
    # are the published model, so scripts that include this file without
    # finMain0001.jl behave exactly as before).
    pubAlpha   = switchValue(:PUBLIC_ALPHA)
    pubBias    = switchValue(:PUBLIC_BIAS)
    pubRho     = switchValue(:PUBLIC_RHO)
    weightPhi  = switchValue(:WEIGHT_PHI)
    freshClone = switchValue(:FRESH_CLONE)
    skipWithdrawn = freshClone || switchValue(:FIX_DOUBLE_COUNT)
    tiebreak   = switchValue(:TIEBREAK)
    belief     = switchValue(:BELIEF)
    beliefP0   = switchValue(:BELIEF_P0)
    publicOn = pubAlpha > 0.0 || pubBias > 0.0 || weightPhi < 1.0
    nAgents = length(mod.agtList)
    publicPoint = 0
    global dataDir
    global workerCore
    # Settings are logged once per run, only for non-default runs, so a default
    # run writes exactly the files it always did (bankRunParametersInit.csv's
    # width is checked by tests/check_recording.sh and scripts/check_sweep_run.py).
    if publicOn || skipWithdrawn
        CSV.write(dataDir*"/"*"bankRunPublicParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, publicAlpha=pubAlpha, publicBias=pubBias,
                            publicRho=pubRho, weightPhi=weightPhi,
                            fixDoubleCount=skipWithdrawn, freshClone=freshClone),
                  writeheader=false, append=true)
    end
    # The schuler-sync switches are logged to their own file, only when one is
    # non-default, so runs at the earlier switches write exactly what they did
    # (tests/test_switch_identity.jl).
    if tiebreak != SWITCH_DEFAULTS.TIEBREAK || belief != SWITCH_DEFAULTS.BELIEF
        CSV.write(dataDir*"/"*"bankRunDecisionParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, tiebreak=tiebreak, belief=belief, beliefP0=beliefP0),
                  writeheader=false, append=true)
    end

    # now, whenever an agent withdraws, we reset a state variable since this means all other agents will
    # re-examing their decision to bank
    halt::Bool=false
    # now, randomize the order of the agents still banking
    t=0
    if mod.theBank.vault<=0.0
        # if the bank is bankrupt, we need to stop the simulation
        runState=true
        return (runState, runSetSize(mod)...)
    end
    while !halt && !runState
        halt=true
        t=t+1
        # The platform's announcement for this tick: the true number withdrawn so
        # far, understated by the spin b·ρ^(t-1)·N. Announced once at the start of
        # the tick, so it lags withdrawals made within the tick. Common to all
        # agents (contrast the neighbour share, which is local). No RNG draws.
        if publicOn
            trueWithdrawn = length(mod.theBank.withdrawHistory)
            publicPoint = clamp(round(Int64, trueWithdrawn - pubBias * pubRho^(t-1) * nAgents),
                                0, nAgents-1)
            CSV.write(dataDir*"/"*"bankRunPublic"*string(workerCore)*".csv",
                      DataFrame(key=mod.key, tick=t, trueWithdrawn=trueWithdrawn,
                                publicPoint=publicPoint),
                      writeheader=false, append=true)
        end
        stillBanking=Random.shuffle(mod.theBank.bankingList)
        # each agent observes the percentage of its neighbors that have withdrawn
        for agt in stillBanking
            withdrawnNeighbors, neighbourEstimate = neighbourSignal(mod, agt)
            priorDraws = beliefDraws(mod, depth; belief=belief, p0=beliefP0)
            # With a fresh clone every withdrawal so far is already in the
            # submodel, so the extra count is measured against the true total
            # rather than against the observed neighbours.
            alreadyOut = freshClone ? length(mod.theBank.withdrawHistory) : length(withdrawnNeighbors)
            additionalWithdrawals = anticipatedWithdrawals(agt, priorDraws, neighbourEstimate, publicPoint,
                                                           alreadyOut, nAgents, t;
                                                           pubAlpha=pubAlpha, weightPhi=weightPhi)
            # BANKRUN_FRESH_CLONE: simulate from the current state, not the
            # post-shock snapshot taken once above (the "stale clone").
            decisionState = freshClone ? SubState(mod) : staleState
            probFullDepositStay = simulateStay(decisionState, agt, withdrawnNeighbors, additionalWithdrawals;
                                               skipWithdrawn=skipWithdrawn)
            probFullDepositWD = payoffIfWithdrawNow(decisionState, agt)
            withdrew = decide(probFullDepositWD, probFullDepositStay; tiebreak=tiebreak)
            if withdrew
                paid = withdraw(mod, agt)
                record === nothing || record!(record, agt.idx, paid)
            end
            if logFull()
                reportRow=DataFrame(key=mod.key,agent=agt.idx,withdraw=withdrew,deposit=agt.deposit,
                    tick=t,vault=mod.theBank.vault,wdProb=probFullDepositWD,stayProb=probFullDepositStay)
                CSV.write(dataDir*"/"*"bankRunEndogenous"*string(workerCore)*".csv",reportRow,writeheader=false,append=true)
            end
            withdrew && (halt = false)

            if mod.theBank.vault<=0.0
                # if the bank is bankrupt, we need to stop the simulation
                runState=true
                break
            end
        end
    end
    return (runState, runSetSize(mod)...)
end

# |S*| — the realised withdrawal set. The cascade converges to a FRACTIONAL
# withdrawal set (the least fixed point of the best-response map, REPOSITORY_REVIEW
# §9.7); `runState` only records whether that set drained the vault. Reporting the
# binary alone throws away the quantity the policy discussion actually needs — how
# much liquidity a run consumes — and is why no run-size exhibit exists.
# withdrawHistory accumulates every agent that left, exogenous and endogenous alike.
# NOTE: named runSetSize, NOT runSize. `runSize` is already a global in
# parameterGen.jl (`runSize=10`, crossjoined as `iteration`). NB that
# comment's arithmetic is wrong: parameterGen.jl's `seed1=repeat(sample(...), seedRun)` repeats the 5 sampled
# seeds 5x, so a cell is 25 x 10 = 250 runs over 5 initialisations, not 50.
# A
# function of that name binds it as a const in Main, and parameterGen.jl is
# included after this file, so the assignment then fails with `invalid
# redefinition of constant runSize` -- which killed job 9363073_1 on 2026-08-13.
function runSetSize(mod::Model)
    n = length(mod.theBank.withdrawHistory)
    d = isempty(mod.theBank.withdrawHistory) ? 0.0 :
        sum(a.deposit for a in mod.theBank.withdrawHistory)
    return (n, d)
end

# now the parallelization functions
    

function isReady(arg::Future)
    return isready(arg)
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

# ---- Run record and the who-runs summary (2026-10-15) ----
# BANKRUN_LOG = summary drops the per-agent and per-decision logs (agents,
# bankRunExogenous, bankRunEndogenous: ~0.3 MB per run at N = 1000). Every run
# is reproducible from its cell and seeds (scripts/replay_run.jl), so the full
# logs of any run can be regenerated on demand. What a sweep keeps is the
# run-level results plus this per-type summary, computed in-process from the
# exact payouts.
logFull() = switchValue(:LOG) == "full"

mutable struct RunRecord
    order::Vector{Int}         # agent idx, in withdrawal order (exogenous first)
    paid::Vector{Float64}      # what withdraw() paid each of them
    nExog::Int
end
RunRecord() = RunRecord(Int[], Float64[], 0)
record!(r::RunRecord, idx::Int, paid::Float64) = (push!(r.order, idx); push!(r.paid, paid); r)

# One row per type: who withdrew (exogenously / endogenously), how much they held
# and were paid, deposits left with stayers, and the endogenous withdrawers'
# position in the withdrawal order (0 = first, 1 = last; 0.5 if only one), as in
# scripts/who_runs_pilot.py.
function typeSummary(mod::Model, isI::AbstractVector{Bool}, rec::RunRecord)
    n = length(mod.agtList)
    how = zeros(Int8, n)                 # 0 stayed, 1 exogenous, 2 endogenous
    paid = zeros(Float64, n)
    pos = fill(NaN, n)
    nEndog = length(rec.order) - rec.nExog
    for (k, i) in enumerate(rec.order)
        paid[i] = rec.paid[k]
        if k <= rec.nExog
            how[i] = 1
        else
            how[i] = 2
            r = k - rec.nExog
            pos[i] = nEndog > 1 ? (r - 1) / (nEndog - 1) : 0.5
        end
    end
    rows = DataFrame(key=String[], type=String[], n=Int[], nExog=Int[], nEndog=Int[],
                     depTotal=Float64[], depExog=Float64[], depEndog=Float64[],
                     paidExog=Float64[], paidEndog=Float64[], depStayers=Float64[],
                     posSumEndog=Float64[], nFirstQuarter=Int[])
    for (lab, sel) in (("I", isI), ("C", .!isI))
        idx = findall(sel)
        d = [mod.agtList[i].deposit for i in idx]
        h = how[idx]
        push!(rows, (mod.key, lab, length(idx), count(==(1), h), count(==(2), h),
                     sum(d; init=0.0), sum(d[h .== 1]; init=0.0), sum(d[h .== 2]; init=0.0),
                     sum(paid[idx][h .== 1]; init=0.0), sum(paid[idx][h .== 2]; init=0.0),
                     sum(d[h .== 0]; init=0.0),
                     sum(pos[idx][h .== 2]; init=0.0), count(<=(0.25), pos[idx][h .== 2])))
    end
    return rows
end

# One run of one parameter row, and every file it writes (results, vault,
# who-runs summary, plus the full logs when BANKRUN_LOG = full). Used by
# modelCall, scripts/replay_run.jl and the tests.
function runRow(row)
    mod, isI = modelGenTyped(row[:key], row[:seed1], row[:seed2],
                             nv(row[:network]),   # agent count = network size (parameterGen.jl agtCnts)
                             .1, row[:network], row[:depositDist], row[:reserveRatio],
                             row[:depositInsuranceQuantile], row[:withdrawRV], row[:warmupAlpha],
                             row[:fracIndividualists], row[:lambdaI], row[:lambdaC])
    vaultInit = mod.theBank.vault      # before the exogenous shock
    rec = RunRecord()
    rMod, nWithdrawn, depositWithdrawn = modelRun(mod; record=rec)
    # Widened 2026-08-13 from (key, result) to carry |S*|. Readers that take
    # only the first two columns are unaffected.
    resultRow=DataFrame(key=row[:key],result=rMod,
                        nWithdrawn=nWithdrawn,depositWithdrawn=depositWithdrawn)
    CSV.write(dataDir*"/"*"bankRunResults"*string(workerCore)*".csv",resultRow,writeheader=false,append=true)
    # Vault at start and end of the run (added 2026-10-15), for the share of the
    # vault paid out, 1 - max(vaultFinal, 0) / vaultInit. A separate file, so
    # bankRunResults keeps its 4 columns for the existing checkers.
    vaultRow=DataFrame(key=row[:key],vaultInit=vaultInit,vaultFinal=mod.theBank.vault)
    CSV.write(dataDir*"/"*"bankRunVault"*string(workerCore)*".csv",vaultRow,writeheader=false,append=true)
    CSV.write(dataDir*"/"*"bankRunTypes"*string(workerCore)*".csv",typeSummary(mod, isI, rec),
              writeheader=false,append=true)
    return (rMod, nWithdrawn, depositWithdrawn)
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
            # ⚠ ORDER IS LOAD-BEARING, corrected 2026-08-19. runRow writes the
            # results BEFORE checkOff. finMain0001.jl exits the master loop the
            # instant sum(completed) reaches nrow, then falls off the end of the
            # script and Julia tears down the worker pool. With checkOff first, the
            # worker that completes the final row is still inside its sleep(1) poll
            # when that happens and its result row is never written -- the task
            # exits COMPLETED holding 249 of 250 runs. Measured on the 2026-08-17
            # arms at 53/2160 production and 75/2160 placebo cells, with 120 of the
            # 128 lost runs sitting in the last 20 rows of the frame (35.8 sigma
            # against a positionally-random null).
            runRow(startIndex)
                proc2=@spawnat 1 checkOff(currentIndex)
                while !isReady(proc2)
                    sleep(1)
                end
                # now we need to fetch the result              
                fetch(proc2)
        end

    return nothing
end

# we need a function to set a global variable for each worker indicating its core
function myCore(c)
    global workerCore
    workerCore=c
end
