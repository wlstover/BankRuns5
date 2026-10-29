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
    # BANKRUN_DEPOSIT_CAP (2026-10-23; the user): no deposit above that share of
    # the bank's total. Deterministic, so the draws (and pairing) are unchanged.
    depositCap = switchValue(:DEPOSIT_CAP)
    depositCap > 0.0 && (deposits = capDeposits(deposits, depositCap))

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
    # BANKRUN_BALANCE = firesale (2026-10-21): the rest of the balance sheet is the
    # long asset, deposits not held as reserves plus equity e per unit of deposits.
    switchValue(:BALANCE) == "firesale" &&
        (theBank.illiquid = (1.0 - reserveRatio + switchValue(:EQUITY)) * sum(deposits))
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
        simAgent[],
        mod.theBank.illiquid
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
        simAgent[],
        mod.theBank.illiquid
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

# Fire sale (2026-10-21, BANKRUN_BALANCE = firesale). Before paying a deposit
# the vault cannot cover, the bank sells the long asset at 1 − d per unit:
# enough to cover it if it can, everything otherwise (a period-1 liquidity
# failure, Chapter 1's rationing footnote). Returns the new (vault, illiquid).
# One pure function, used by withdraw() and by both sub-simulations, so all three
# do the same arithmetic. With nothing to sell (the vault bank, illiquid = 0) it
# returns its inputs, so the default model is unchanged bit for bit.
function raiseCash(vault::Float64, illiquid::Float64, dep::Float64, d::Float64)
    (dep > vault && illiquid > 0.0) || return (vault, illiquid)
    need = dep - vault                   # vault >= 0 here: it goes negative only once illiquid is 0
    capacity = (1.0 - d) * illiquid
    capacity >= need && return (dep, max(illiquid - need / (1.0 - d), 0.0))
    return (vault + capacity, 0.0)
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
    # fire-sale bank: sell the long asset first if the vault falls short
    mod.theBank.vault, mod.theBank.illiquid =
        raiseCash(mod.theBank.vault, mod.theBank.illiquid, agt.deposit, switchValue(:FIRE_DISCOUNT))
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
    mod.theBank.vault, mod.theBank.illiquid =
        raiseCash(mod.theBank.vault, mod.theBank.illiquid, agt.deposit, switchValue(:FIRE_DISCOUNT))
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

# A stayer's payoff at period 2 in the fire-sale bank (2026-10-21; Chapter 1's
# stay branch). Stayers hold debt worth R·deposit (R = BANKRUN_STAY_RETURN). The
# bank pays the promises in full if its terminal assets, cash plus the long asset
# at gross return Rθ, cover them; otherwise stayers share the assets pro rata,
# and insurance tops each up to min(deposit, cap). With no stayers left the
# promises are 0 and the bank is solvent.
function stayerPayoff(vault::Float64, illiquid::Float64, Rθ::Float64, promises::Float64,
                      dep::Float64, cap::Float64, R::Float64)
    promises <= 0.0 && return R * dep
    rho = (max(vault, 0.0) + illiquid * Rθ) / promises
    return rho >= 1.0 ? R * dep : max(rho * R * dep, min(dep, cap))
end

# The insurance cap a withdrawal from `mod` would face now (withdraw()'s rule).
currentCap(mod) = !(0.0 <= mod.depositInsurance < 1.0) ?
    (isempty(mod.theBank.withdrawHistory) ? 0.0 : maximum(deposit.(mod.theBank.withdrawHistory))) :
    quantile(mod.depositDistribution, mod.depositInsurance)

function subModelRun(mod::simModel,agt::Agent,withdrawingAgents::Array{Agent},additionalWithdrawals::Int64;
                     skipWithdrawn::Bool=false, terminalReturn=nothing, stayReturn::Float64=1.0)
    # Deposits of the agents banked at the start, summed in agent order, and of
    # those this sub-simulation withdraws (for the stayers' promises, firesale).
    bankedDep = sum(a.deposit for a in mod.agtList if a.banked; init=0.0)
    removedDep = 0.0
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
        currAgt.banked && (removedDep += currAgt.deposit)
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
            removedDep += stillBanking[idx].deposit
            withdraw(mod,stillBanking[idx])
            numWithdrawn+=1
        end
        idx+=1
    end
    # Fire-sale bank: the focal agent stays to period 2 instead (Chapter 1's stay).
    if terminalReturn !== nothing
        pay = stayerPayoff(mod.theBank.vault, mod.theBank.illiquid, Float64(terminalReturn),
                           stayReturn * (bankedDep - removedDep), agt.deposit, currentCap(mod), stayReturn)
        return (pay, pay < stayReturn * agt.deposit)
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
    illiquid::Float64               # long asset, face units (firesale; 0 in the vault bank)
    discount::Float64               # fire-sale discount d
    bankedDep::Float64              # deposits of the banked agents, summed in agent order
    focalInsUsed::Float64           # insurance already paid to the focal agent in this
                                    # valuation (partial withdrawals; 0 otherwise)
end

# The state clone() would produce: banking list and history are the banked and
# withdrawn agents in agent order, whatever order the source lists hold.
function SubState(agtList, vault::Float64, depositInsurance::Float64, depositDistribution;
                  illiquid::Float64=0.0, discount::Float64=0.0)
    deps = [a.deposit for a in agtList]
    banked = BitVector([a.banked for a in agtList])
    out = [a.deposit for a in agtList if !a.banked]
    adaptive = !(0.0 <= depositInsurance < 1.0)
    return SubState(vault, deps, banked, [a.idx for a in agtList if a.banked],
                    length(out), isempty(out) ? -Inf : maximum(out), adaptive,
                    adaptive ? 0.0 : quantile(depositDistribution, depositInsurance),
                    illiquid, discount, sum(a.deposit for a in agtList if a.banked; init=0.0), 0.0)
end
SubState(mod::simModel) = SubState(mod.agtList, mod.theBank.vault, mod.depositInsurance, mod.depositDistribution;
                                   illiquid=mod.theBank.illiquid, discount=switchValue(:FIRE_DISCOUNT))
SubState(mod::Model)    = SubState(mod.agtList, mod.theBank.vault, mod.depositInsurance, mod.depositDistribution;
                                   illiquid=mod.theBank.illiquid, discount=switchValue(:FIRE_DISCOUNT))

# The withdrawals a sub-simulation from `s` contains once phase 1 has replayed
# the observed neighbours: those already out in `s`, plus each replayed
# neighbour, counted as subModelRunSparse counts them. This is what an agent's
# anticipated total is measured against (alreadyOut in modelRun), so the
# anticipated extra withdrawals are never ones the sub-model already holds.
nInView(s::SubState, withdrawnNeighbors; skipWithdrawn::Bool) =
    s.nHistory + count(nb -> !skipWithdrawn || s.banked[nb.idx], withdrawnNeighbors)

# Same signature and result as subModelRun(clone(decisionModel), ...).
# terminalReturn (fire-sale bank): the long asset's gross return in this draw;
# the focal agent then stays to period 2 and the result is its stayer payoff.
# Every withdrawal goes through raiseCash first, as in withdraw(); with nothing
# to sell (the vault bank) that is a no-op.
function subModelRunSparse(s::SubState, agt::Agent, withdrawingAgents::Array{Agent},
                           additionalWithdrawals::Int64; skipWithdrawn::Bool=false,
                           terminalReturn=nothing, stayReturn::Float64=1.0)
    vault, nHist, histMax = s.vault, s.nHistory, s.histMax
    ill, d = s.illiquid, s.discount
    removed = Int[]
    removedDep = 0.0
    # Phase 1: replay the observed withdrawals (the double count when not skipped).
    for nb in withdrawingAgents
        i = nb.idx
        skipWithdrawn && !s.banked[i] && continue
        s.banked[i] && (push!(removed, i); removedDep += s.deposits[i])
        vault, ill = raiseCash(vault, ill, s.deposits[i], d)
        nHist += 1; histMax = max(histMax, s.deposits[i]); vault -= s.deposits[i]
    end
    # Phase 2: the anticipated additional withdrawals, in a random order.
    stillBanking = isempty(removed) ? copy(s.bankedIdx) : filter(i -> !(i in removed), s.bankedIdx)
    Random.shuffle!(stillBanking)
    numWithdrawn, j = 0, 1
    while numWithdrawn < additionalWithdrawals && j <= length(stillBanking)
        i = stillBanking[j]
        if i != agt.idx
            removedDep += s.deposits[i]
            vault, ill = raiseCash(vault, ill, s.deposits[i], d)
            nHist += 1; histMax = max(histMax, s.deposits[i]); vault -= s.deposits[i]
            numWithdrawn += 1
        end
        j += 1
    end
    cap = s.adaptive ? (nHist == 0 ? 0.0 : histMax) : s.quantileCap
    cap -= s.focalInsUsed     # the focal agent's cover left (0.0 subtracted otherwise)
    dep = s.deposits[agt.idx]
    # Fire-sale bank: the focal agent stays to period 2 (Chapter 1's stay).
    if terminalReturn !== nothing
        pay = stayerPayoff(vault, ill, Float64(terminalReturn), stayReturn * (s.bankedDep - removedDep),
                           dep, cap, stayReturn)
        return (pay, pay < stayReturn * agt.deposit)
    end
    # Phase 3: the focal agent withdraws (withdraw()'s payout rule).
    vault, ill = raiseCash(vault, ill, dep, d)
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

# BANKRUN_PRIVATE_SIGNAL = shock (2026-10-20): an informative private signal,
# the ABM counterpart of Chapter 1's x_i = θ + ε_i. The vault is known, so the
# uncertain fundamental is the size of the liquidity shock (the number of
# exogenous withdrawals, n_exog). Each agent receives one signal per run,
#   x_i = n_exog + s·Z_i,   Z_i ~ N(0, 1),   s = BANKRUN_PRIVATE_NOISE (agents),
# and its prior draws come from the posterior p(n | x_i) ∝ prior(n)·φ((x_i − n)/s),
# where prior is the belief law above (geometric: the shock distribution itself;
# point: Binomial(N−1, p0)). As s → ∞ the posterior is the prior, i.e. the
# uninformative model. All signal and posterior draws use their own RNG stream,
# and modelRun still makes the prior draws on the main stream (and discards
# them), so the shuffles and sub-simulations are draw-for-draw those of the
# uninformative model: a shock arm is paired with its none arm by construction.
struct PrivatePosterior
    lo::Int                    # support of the prior: lo, lo+1, ..., lo+length-1
    signal::Vector{Float64}    # x_i by agent idx
    samplers::Vector{Any}      # alias-table sampler of each agent's posterior
    rng::MersenneTwister
end

function beliefPrior(mod::Model; belief::String, p0::Float64)
    belief == "geometric" && return mod.exogProb
    belief == "point" && return Binomial(length(mod.agtList) - 1, p0)
    error("unknown belief law \"$belief\"")
end

function privatePosteriors(mod::Model, nExog::Integer, s::Float64; belief::String, p0::Float64)
    prior = beliefPrior(mod; belief=belief, p0=p0)
    lo = Int(minimum(prior))
    hi = isfinite(maximum(prior)) ? Int(maximum(prior)) : Int(quantile(prior, 1 - 1e-12))
    support = lo:hi
    logPrior = logpdf.(Ref(prior), support)
    rng = MersenneTwister(xor(reinterpret(UInt64, mod.seed2), 0x5bd1e995))
    n = length(mod.agtList)
    signal = Vector{Float64}(undef, n)
    samplers = Vector{Any}(undef, n)
    for agt in mod.agtList
        x = nExog + s * randn(rng)
        lw = logPrior .- ((x .- support) .^ 2) ./ (2 * s^2)
        w = exp.(lw .- maximum(lw))
        signal[agt.idx] = x
        samplers[agt.idx] = sampler(Categorical(w ./ sum(w)))
    end
    return PrivatePosterior(lo, signal, samplers, rng)
end

privateDraws(pp::PrivatePosterior, agt::Agent, depth::Integer) =
    pp.lo .- 1 .+ rand(pp.rng, pp.samplers[agt.idx], depth)

# The agent's belief about θ given its private signal x_i (s.d. sx) and, when
# BANKRUN_THETA_PUBLIC is on, the public signal y (2026-10-22). Chapter 1's
# subjective belief: the agent treats est_i = (1 − ω)·x_i + ω·y as if it were
# Bayes-optimal, with the window (1 − ω)·sx + ω·sy, where sy is the noise it
# attributes to y (BANKRUN_THETA_PUBLIC_NOISE; it does not see the gap y − θ).
# ω is the agent's λ (LAMBDA_SCOPE theta / both) or the population mean λ̄
# (count). Chapter 1's uniform window is a normal here, truncated to θ's support
# [0, 1]. With y = nothing it is the private posterior of 2026-10-21 exactly.
function thetaBelief(x::Float64, sx::Float64, y, ω::Float64, sy::Float64)
    y === nothing && return truncated(Normal(x, sx), 0.0, 1.0)
    return truncated(Normal((1.0 - ω) * x + ω * y, (1.0 - ω) * sx + ω * sy), 0.0, 1.0)
end

# The public signal of θ at tick t: θ plus a gap that decays as gap₀·ρ^(t-1).
#   stale:  gap₀ = y₀ − θ, so with ρ = 1 y stays at y₀ whatever θ is (Chapter 1's
#           realised, stale y; δ = y₀ − θ varies run by run);
#   tracks: gap₀ = δ, a constant markup that moves with θ (the alternative
#           Chapter 1 declines because it restores uniqueness).
# ρ < 1 is Table 1.x's "error corrects" column: y converges on θ during the run.
# Clamped to θ's support. Deterministic: no RNG draws.
function thetaPublicAt(mode::String, theta::Float64, t::Integer; level::Float64,
                       gap::Float64, rho::Float64)
    gap0 = mode == "stale" ? level - theta : gap
    rho == 1.0 && mode == "stale" && return level
    return clamp(theta + gap0 * rho^(t - 1), 0.0, 1.0)
end

# Blend each prior draw with the social signal, then convert to the number of
# additional withdrawals the agent anticipates beyond those already out.
#   social = α·publicPoint + (1−α)·neighbourEstimate,   ω_t = λ·φ^(t−1)
# λ = agt.individualism is the weight on the social signal, so a higher λ is a
# more collectivist agent: λ_I (0.1–0.3) relies mostly on its own prior, λ_C
# (0.5–0.9) mostly follows the social signal. With α = 0 and φ = 1 (the
# defaults) this is the published expression, λ·neighbourEstimate.
# Scale of `alreadyOut` (next_steps.md #9): under BANKRUN_FRESH_CLONE it is the
# population total withdrawn, the same scale as blendedTotal, and the sub-model
# already contains every withdrawal. On the published stale-clone path it is the
# number of withdrawn NEIGHBOURS, so a population-scale total is reduced by a
# local count (the sub-model replays only those neighbours). Production runs
# use the fresh clone (decided 2026-10-20). Under BANKRUN_PUBLIC_MODE=stale it
# is the population total in the agent's stale view (nInView), 2026-10-21.
# λ (2026-10-22): the agent's own λ unless BANKRUN_LAMBDA_SCOPE = theta, where the
# head-count blend carries no culture and every agent uses the population mean λ̄.
function anticipatedWithdrawals(agt::Agent, priorDraws, neighbourEstimate, publicPoint,
                                alreadyOut, nAgents, t; pubAlpha, weightPhi,
                                λ::Float64=agt.individualism)
    ω = weightPhi == 1.0 ? λ : λ * weightPhi^(t-1)
    socialPoint = pubAlpha == 0.0 ? Float64(neighbourEstimate) :
        pubAlpha * Float64(publicPoint) + (1.0 - pubAlpha) * Float64(neighbourEstimate)
    blendedTotal = round.(Int64, (1.0 .- ω) .* Float64.(priorDraws) .+ ω .* socialPoint)
    blendedTotal = clamp.(blendedTotal, 0, nAgents - 1)
    return max.(0, blendedTotal .- alreadyOut)
end

# The value of staying, one sub-simulation per prior draw (sparse; identical to
# subModelRun on clones).
#   payoff = full (published): P(full deposit | stay), the share of draws in which
#            the agent is paid in full when it withdraws after the anticipated others.
#   payoff = recovery (2026-10-21): the expected share of its deposit it is paid then.
#   returns (fire-sale bank): the long asset's gross return in each draw; the agent
#            stays to period 2, and the value is its expected payoff over its
#            promise R·deposit, so decide()'s R·P_stay is the expected payoff per
#            unit of deposit.
function simulateStay(s::SubState, agt::Agent, withdrawnNeighbors::Array{Agent},
                      additionalWithdrawals; skipWithdrawn::Bool, payoff::String="full",
                      returns=nothing, stayReturn::Float64=1.0)
    if returns === nothing
        if payoff == "full"
            lossStay = Bool[subModelRunSparse(s, agt, withdrawnNeighbors, additionalWithdrawals[k];
                                              skipWithdrawn=skipWithdrawn)[2] for k in eachindex(additionalWithdrawals)]
            return 1 - mean(lossStay)
        end
        paid = Float64[subModelRunSparse(s, agt, withdrawnNeighbors, additionalWithdrawals[k];
                                         skipWithdrawn=skipWithdrawn)[1] for k in eachindex(additionalWithdrawals)]
        return mean(paid) / agt.deposit
    end
    pay = stayDraws(s, agt, withdrawnNeighbors, additionalWithdrawals;
                    skipWithdrawn=skipWithdrawn, returns=returns, stayReturn=stayReturn)
    return mean(pay) / (stayReturn * agt.deposit)
end

# The fire-sale bank's stayer payoff to the focal agent in each sub-simulation
# draw (an amount, R per unit if the bank survives): simulateStay's mean, and the
# distribution CARA values (BANKRUN_CARA).
function stayDraws(s::SubState, agt::Agent, withdrawnNeighbors::Array{Agent},
                   additionalWithdrawals; skipWithdrawn::Bool, returns, stayReturn::Float64)
    return Float64[subModelRunSparse(s, agt, withdrawnNeighbors, additionalWithdrawals[k];
                                     skipWithdrawn=skipWithdrawn, terminalReturn=returns[k],
                                     stayReturn=stayReturn)[1] for k in eachindex(additionalWithdrawals)]
end

# The deposit cap (BANKRUN_DEPOSIT_CAP = c, 2026-10-23; the user). At N = 1,000 a
# log-normal(1, 2.5) bank has a depositor holding ~15% of deposits (median), who
# fails the bank whenever it leaves (F12d); Celsius's largest account held 0.94%
# among ~541K users, and N would have to reach the platform's size for the draw
# to match (scripts/whale_scaling.py). The cap removes that last straw and keeps
# most of the concentration: the k largest deposits are set to a common level L
# with L = c · (total after capping), the smallest k for which the (k+1)th
# deposit is at or below L. Order and every deposit below L are unchanged.
function capDeposits(d::Vector{Float64}, c::Float64)
    n = length(d)
    c * n > 1.0 || error("BANKRUN_DEPOSIT_CAP = $c is infeasible for $n depositors (needs c > 1/n)")
    order = sortperm(d, rev=true)
    rest = sum(d)
    for k in 1:n-1
        rest -= d[order[k]]
        L = c * rest / (1.0 - k * c)
        if d[order[k+1]] <= L
            d[order[1]] <= L * (1.0 + 1e-12) && return d     # nobody above the cap (to rounding)
            out = copy(d)
            out[order[1:k]] .= L
            return out
        end
    end
    error("unreachable: c > 1/n caps at most n - 1 deposits")
end

# Risk aversion (BANKRUN_CARA, 2026-10-22; the user): u(w) = −exp(−a·w), with
# absolute risk aversion a = CARA / (the bank's mean initial deposit), so a
# depositor holding the mean deposit has a·b = CARA. The certainty equivalent of
# payoffs w over equally likely draws (shifted by the smallest, so no overflow).
# As a → 0 it is mean(w), the risk-neutral value.
function ceValue(w::AbstractVector{Float64}, a::Float64)
    m = minimum(w)
    return m - log1p(mean(expm1.(-a .* (w .- m)))) / a     # log1p/expm1: exact as a → 0
end

# The value of withdrawing now (withdraw()'s payout rule on the decision state,
# without a clone, after any fire sale). It involves no random draw. Under
# payoff = full it is exactly 1.0 (the bank or the insurance cap covers the
# deposit) or 0.0; under payoff = recovery it is the share of the deposit paid.
# Until 2026-10-15 it was recomputed `depth` times with identical results.
function payoffIfWithdrawNow(s::SubState, agt::Agent; recovery::Bool=false)
    cap = (s.adaptive ? (s.nHistory == 0 ? 0.0 : s.histMax) : s.quantileCap) - s.focalInsUsed
    dep = s.deposits[agt.idx]
    vault = raiseCash(s.vault, s.illiquid, dep, s.discount)[1]
    received = dep > vault ? max(0.0, vault, min(dep, cap)) : dep
    recovery && return received / agt.deposit
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
# stayReturn (BANKRUN_STAY_RETURN, 2026-10-20) is Chapter 1's R: a stayer is paid
# R if the bank survives and L = 0 if it fails (an uninsured stayer gets nothing),
# so every rule compares P_WD with R·P_stay. Withdrawing pays 1 (at par) when
# P_WD = 1, so the rule is P_stay < p* = (1−L)/(R−L) = 1/R, Chapter 1's cutoff.
# R = 1 (default) is exactly the published comparison (x * 1.0 == x).
# P_WD is exactly 0 or 1 (payoffIfWithdrawNow), so schuler and strict make the
# same decisions: P_WD > P_stay already fails when P_stay == 1. Both differ from
# legacy only when the vault cannot cover the agent now (P_WD == 0), where they
# stay and legacy withdraws.
function decide(probFullDepositWD, probFullDepositStay; tiebreak::String="legacy",
                stayReturn::Float64=1.0)
    stayValue = stayReturn * probFullDepositStay
    tiebreak == "legacy" &&
        return probFullDepositWD > stayValue || probFullDepositWD == 0.0
    tiebreak == "schuler" &&
        return probFullDepositStay != 1.0 && probFullDepositWD > stayValue
    tiebreak == "strict" && return probFullDepositWD > stayValue
    error("unknown tie-break rule \"$tiebreak\"")
end

# ---- Partial withdrawals (2026-10-22, BANKRUN_WITHDRAW = partial) ----
# An agent may withdraw a fraction f of its remaining balance b, f in {0, 1/n,
# ..., (n−1)/n, 1}, n = PARTIAL_STEPS (4 by default: {0, ¼, ½, ¾, 1}). Its value per unit of balance is what the bank pays now on f·b, plus R
# times the expected stayer payoff on the (1 − f)·b it leaves in, from the bank
# after its own sale:  V(f) = paid(f·b)/b + R·P_stay(state after f·b).
# V(0) is decide()'s R·P_stay and V(1) its P_WD. A small depositor's withdrawal
# does not move the bank, so V is linear in f and the best f is 0 or 1; only an
# agent large enough to move the bank can gain from an interior f. So only agents
# whose balance exceeds PARTIAL_MIN_SHARE of the bank's current period-1
# capacity evaluate the interior fractions (tests/test_partial.jl checks the cutoff against
# a run with no cutoff); the rest use decide() exactly as under WITHDRAW = all.
# Every fraction is valued on the same sub-simulation draws (common random
# numbers: the main stream is rewound for each), and the stream then continues
# from where V(0) left it, so the agents after a large one draw what they
# would have drawn.
# The interior fractions for PARTIAL_STEPS = n. A finer grid (2026-10-23, the
# user: S1b's pilot) lets an agent take a fraction just short of draining the bank.
partialGrid(n::Int) = Tuple(k / n for k in 1:n-1)

# The decision state after the focal agent withdraws `a` now, and what it is
# paid (withdraw()'s rule, after any fire sale).
# Insurance is a cumulative quantile cap per depositor (2026-10-22, the user).
# withdraw()'s rule, max(vault, min(claim, cap)), guarantees a depositor
# min(claim, cap) in total, bank and insurer together, on the claim the bank
# cannot pay. A withdrawal the bank pays in full uses no cover (cover applies to
# the balance at failure); one it cannot pay uses cover equal to all it pays
# the depositor, so the balance left in is covered only by the rest of the cap
# (focalInsUsed) and splitting never recovers more than withdrawing at once
# (tests/test_partial.jl G). In a run a shortfall only happens on the withdrawal
# that fails the bank, after which the run stops, so the cap binds inside the
# valuation: a fraction that tips the bank, then the balance left in.
function afterOwnWithdrawal(s::SubState, idx::Int, a::Float64)
    vault, ill = raiseCash(s.vault, s.illiquid, a, s.discount)
    cap = s.quantileCap - s.focalInsUsed      # adaptive insurance is refused under partial
    paid = a > vault ? max(0.0, vault, min(a, cap)) : a
    ins = a > vault ? paid : 0.0
    deps = copy(s.deposits)
    deps[idx] -= a
    return SubState(vault - a, deps, s.banked, s.bankedIdx, s.nHistory, s.histMax, s.adaptive,
                    s.quantileCap, ill, s.discount, s.bankedDep - a, s.focalInsUsed + ins), paid
end

# The bank's period-1 capacity in a decision state: cash plus the long asset at
# its fire-sale price.
capacityOf(s::SubState) = max(s.vault, 0.0) + (1.0 - s.discount) * s.illiquid

# V(f) for an interior f (see above).
function partialValue(s::SubState, agt::Agent, f::Float64, withdrawnNeighbors::Array{Agent},
                      additionalWithdrawals; skipWithdrawn::Bool, returns, stayReturn::Float64)
    b = s.deposits[agt.idx]
    sf, paid = afterOwnWithdrawal(s, agt.idx, f * b)
    sf.vault < 0.0 && return -Inf        # drains the bank (see above chooseFraction)
    stay = simulateStay(sf, agt, withdrawnNeighbors, additionalWithdrawals;
                        skipWithdrawn=skipWithdrawn, payoff="recovery", returns=returns,
                        stayReturn=stayReturn)
    return paid / b + stayReturn * stay
end

# A fraction the bank cannot pay in full fails it, and pays the depositor what
# the bank has, as withdrawing everything would (with insurance, no more:
# tests/test_partial.jl G). Such a fraction is not offered (V = −Inf), so a
# withdrawal that fails the bank is a full one. Until 2026-10-22 the tie went to
# the smallest such fraction, which recorded the run's failing withdrawal as a
# partial one (r1p: the only partial withdrawals under risk neutrality).

# The best fraction: the largest V on the grid, ties to the smaller fraction.
# With no interior values this is decide() (strict comparison), and the
# tie-break rules keep their margins: legacy withdraws everything when even
# withdrawing pays nothing; schuler stays when staying pays in full for sure.
function chooseFraction(vStay::Float64, vAll::Float64, vInterior; tiebreak::String,
                        pStay::Float64, grid=partialGrid(4))
    tiebreak == "legacy" && vAll == 0.0 && return 1.0
    tiebreak == "schuler" && pStay == 1.0 && return 0.0
    best, bestV = 0.0, vStay
    for (f, v) in zip(grid, vInterior)
        v > bestV && ((best, bestV) = (f, v))
    end
    vAll > bestV && (best = 1.0)
    return best
end

# withdraw() for part of a balance: the bank sells what it must, pays a, and the
# agent stays banked with the rest. The last fraction goes through withdraw().
function withdrawPart!(mod::Model, agt::Agent, a::Float64)
    cap = currentCap(mod)
    mod.theBank.vault, mod.theBank.illiquid =
        raiseCash(mod.theBank.vault, mod.theBank.illiquid, a, switchValue(:FIRE_DISCOUNT))
    paid = a > mod.theBank.vault ? max(0.0, mod.theBank.vault, min(a, cap)) : a
    mod.theBank.vault -= a
    agt.deposit -= a
    return paid
end

# neighbourSignal() when a partial withdrawal counts as withdrawing (the user,
# 2026-10-22: neighbours see that someone pulled money, not how much). The
# neighbours returned for the sub-simulation's phase 1 are those fully out, as
# before; partial withdrawers still banked count in the estimate only.
function neighbourSignalPartial(mod::Model, agt::Agent, anyOut::BitVector)
    neighbors = neighborList(mod, agt)
    withdrawnNeighbors::Array{Agent} = filter(n -> !n.banked, neighbors)
    nAgents = length(mod.agtList)
    propWithdrawn = isempty(neighbors) ? 0.0 : count(n -> anyOut[n.idx], neighbors) / length(neighbors)
    return withdrawnNeighbors, clamp(round(Int64, propWithdrawn * nAgents), 0, nAgents - 1)
end

# now the main model function
# thetaWeight (2026-10-28, L2): per-agent weights on y in the θ blend, replacing
# λthetaOf when given (learned from experience; runRow passes them only under
# BANKRUN_LEARN). nothing = the cultural weight, the model as before.
function modelRun(mod::Model; record=nothing, thetaWeight=nothing)
    runState::Bool=false
    # set the seed
    Random.seed!(mod.seed2)
    vault0, illiquid0 = mod.theBank.vault, mod.theBank.illiquid   # before the shock



    exogList = exogWithdrawals(mod; record=record)
    
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
    publicMode    = switchValue(:PUBLIC_MODE)
    publicRefresh = switchValue(:PUBLIC_REFRESH)
    privateSignal = switchValue(:PRIVATE_SIGNAL)
    privateNoise  = switchValue(:PRIVATE_NOISE)
    stayReturn    = switchValue(:STAY_RETURN)
    payoffMode    = switchValue(:PAYOFF)
    balanceMode   = switchValue(:BALANCE)
    fireDiscount  = switchValue(:FIRE_DISCOUNT)
    equity        = switchValue(:EQUITY)
    fundamental   = switchValue(:FUNDAMENTAL)
    returnLo      = switchValue(:RETURN_LO)
    returnHi      = switchValue(:RETURN_HI)
    thetaNoise    = switchValue(:THETA_NOISE)
    thetaPublic   = switchValue(:THETA_PUBLIC)
    thetaPubLevel = switchValue(:THETA_PUBLIC_LEVEL)
    thetaPubGap   = switchValue(:THETA_PUBLIC_GAP)
    thetaPubRho   = switchValue(:THETA_PUBLIC_RHO)
    thetaPubNoise = switchValue(:THETA_PUBLIC_NOISE)
    lambdaScope   = switchValue(:LAMBDA_SCOPE)
    partial       = switchValue(:WITHDRAW) == "partial"
    partialMin    = switchValue(:PARTIAL_MIN_SHARE)
    partialSteps  = switchValue(:PARTIAL_STEPS)
    grid          = partial ? partialGrid(partialSteps) : ()
    caraGamma     = switchValue(:CARA)
    depositCap    = switchValue(:DEPOSIT_CAP)
    publicStale = publicMode == "stale"
    publicOn = pubAlpha > 0.0 || pubBias > 0.0 || weightPhi < 1.0 || publicStale
    privatePost = privateSignal == "shock" ?
        privatePosteriors(mod, length(exogList), privateNoise; belief=belief, p0=beliefP0) : nothing
    # Refused combinations (settings.jl switchComboError), e.g. stale mode's view
    # needs the double-count fix: phase 1 would otherwise take neighbours already
    # out of the snapshot off its vault a second time.
    comboErr = switchComboError((PUBLIC_MODE=publicMode, FIX_DOUBLE_COUNT=switchValue(:FIX_DOUBLE_COUNT),
                                 FRESH_CLONE=freshClone, PAYOFF=payoffMode, BALANCE=balanceMode,
                                 FUNDAMENTAL=fundamental, PRIVATE_SIGNAL=privateSignal,
                                 RETURN_LO=returnLo, RETURN_HI=returnHi, THETA_PUBLIC=thetaPublic,
                                 WITHDRAW=switchValue(:WITHDRAW), CARA=caraGamma))
    comboErr === nothing || error(comboErr)
    # Insurance under partial withdrawals is a cumulative quantile cap
    # (afterOwnWithdrawal). The adaptive scheme's cap, the largest deposit
    # withdrawn so far, has no settled meaning with fractions: refused (the user).
    partial && isnan(insuranceCap(mod)) &&
        error("BANKRUN_WITHDRAW=partial needs quantile deposit insurance (0 <= q < 1), not the adaptive scheme")
    # Fire-sale bank and fundamental (2026-10-21). θ is drawn once per run, and
    # each agent's private signal of it once per run, from their own stream; the
    # agents' Monte Carlo draws of θ from another. Neither touches the main
    # stream, so arms that differ only in these switches see the same shocks and
    # shuffles, and paired arms share each run's θ. FUNDAMENTAL = none: θ = 1,
    # the long asset returns RETURN_HI for sure.
    balanceFire = balanceMode == "firesale"
    thetaOn = fundamental == "theta"
    returnOf(x) = returnLo + (returnHi - returnLo) * x
    theta, thetaSignal, beliefRng = 1.0, nothing, nothing
    if balanceFire
        thetaRng = MersenneTwister(xor(reinterpret(UInt64, mod.seed2), 0x7f4a7c15f39cc060))
        beliefRng = MersenneTwister(xor(reinterpret(UInt64, mod.seed2), 0x2545f4914f6cdd1d))
        thetaOn && (theta = rand(thetaRng))
        privateSignal == "theta" &&
            (thetaSignal = [theta + thetaNoise * randn(thetaRng) for _ in 1:length(mod.agtList)])
    end
    # The vault bank fails when its vault is exhausted; the fire-sale bank fails
    # in period 1 only when it has sold everything and still cannot pay (vault < 0).
    failedNow() = balanceFire ? mod.theBank.vault < 0.0 : mod.theBank.vault <= 0.0
    staleLevel = 0
    staleView = staleState
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
    # The Chapter 1 signal switches (2026-10-20), likewise in their own files and
    # only when non-default.
    if publicStale
        CSV.write(dataDir*"/"*"bankRunPublicMode"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, publicMode=publicMode, publicRefresh=publicRefresh),
                  writeheader=false, append=true)
    end
    if privatePost !== nothing
        CSV.write(dataDir*"/"*"bankRunPrivateParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, privateSignal=privateSignal, privateNoise=privateNoise,
                            nExog=length(exogList)),
                  writeheader=false, append=true)
        if logFull()
            CSV.write(dataDir*"/"*"bankRunPrivate"*string(workerCore)*".csv",
                      DataFrame(key=mod.key, agent=1:nAgents, signal=privatePost.signal),
                      writeheader=false, append=true)
        end
    end

    if stayReturn != SWITCH_DEFAULTS.STAY_RETURN
        CSV.write(dataDir*"/"*"bankRunStayReturn"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, stayReturn=stayReturn),
                  writeheader=false, append=true)
    end
    if payoffMode != SWITCH_DEFAULTS.PAYOFF || balanceFire || thetaOn
        CSV.write(dataDir*"/"*"bankRunBalanceParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, payoff=payoffMode, balance=balanceMode,
                            fireDiscount=fireDiscount, equity=equity, fundamental=fundamental,
                            returnLo=returnLo, returnHi=returnHi, thetaNoise=thetaNoise),
                  writeheader=false, append=true)
    end
    if thetaSignal !== nothing
        CSV.write(dataDir*"/"*"bankRunPrivateParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, privateSignal=privateSignal, privateNoise=privateNoise,
                            nExog=length(exogList)),
                  writeheader=false, append=true)
        if logFull()
            CSV.write(dataDir*"/"*"bankRunPrivate"*string(workerCore)*".csv",
                      DataFrame(key=mod.key, agent=1:nAgents, signal=thetaSignal),
                      writeheader=false, append=true)
        end
    end

    # Public signal of θ and the scope of λ (2026-10-22). λ̄ is the population
    # mean of the agents' λ: the weight of the blend that carries no culture.
    thetaPubOn = thetaPublic != "none"
    lambdaBar = sum(a.individualism for a in mod.agtList) / nAgents
    if thetaPubOn || lambdaScope != SWITCH_DEFAULTS.LAMBDA_SCOPE
        CSV.write(dataDir*"/"*"bankRunThetaPublicParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, thetaPublic=thetaPublic, thetaPublicLevel=thetaPubLevel,
                            thetaPublicGap=thetaPubGap, thetaPublicRho=thetaPubRho,
                            thetaPublicNoise=thetaPubNoise, lambdaScope=lambdaScope),
                  writeheader=false, append=true)
        y1 = thetaPubOn ? thetaPublicAt(thetaPublic, theta, 1; level=thetaPubLevel,
                                        gap=thetaPubGap, rho=thetaPubRho) : NaN
        CSV.write(dataDir*"/"*"bankRunThetaPublic"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, theta=theta, y1=y1, gap1=y1 - theta, lambdaBar=lambdaBar),
                  writeheader=false, append=true)
    end
    λcountOf(a) = lambdaScope == "theta" ? lambdaBar : a.individualism
    λthetaOf(a) = thetaWeight !== nothing ? thetaWeight[a.idx] :
                  lambdaScope == "count" ? lambdaBar : a.individualism

    # Partial withdrawals (2026-10-22): agt.deposit is the remaining balance
    # during the run (the bank's arithmetic and the stayers' promises use it);
    # the original deposits are restored before the run returns, for the outputs.
    # anyOut: the agent has withdrawn something (exogenous shocks take it all).
    dep0 = partial ? [a.deposit for a in mod.agtList] : Float64[]
    anyOut = falses(partial ? nAgents : 0)
    partial && for a in exogList; anyOut[a.idx] = true; end
    nPartialEvents, nBigDecisions = 0, 0
    # CARA (2026-10-22): absolute risk aversion, scaled by the mean initial deposit.
    caraA = caraGamma > 0.0 ? caraGamma / mean(a.deposit for a in mod.agtList) : 0.0
    if caraGamma > 0.0
        CSV.write(dataDir*"/"*"bankRunRiskParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, cara=caraGamma), writeheader=false, append=true)
    end
    if partial
        CSV.write(dataDir*"/"*"bankRunWithdrawParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, withdraw="partial", partialMinShare=partialMin),
                  writeheader=false, append=true)
    end
    # PARTIAL_STEPS (2026-10-23): written only when it is not the default 4, so
    # outputs from before the switch stay valid.
    if depositCap > 0.0
        CSV.write(dataDir*"/"*"bankRunDepositParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, depositCap=depositCap), writeheader=false, append=true)
    end
    if partial && partialSteps != 4
        CSV.write(dataDir*"/"*"bankRunGridParams"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, partialSteps=partialSteps), writeheader=false, append=true)
    end

    # now, whenever an agent withdraws, we reset a state variable since this means all other agents will
    # re-examing their decision to bank
    halt::Bool=false
    # now, randomize the order of the agents still banking
    t=0
    if failedNow()
        # if the bank is bankrupt, we need to stop the simulation
        runState=true
    end
    while !halt && !runState
        halt=true
        t=t+1
        record === nothing || (record.nTicks = t)
        # The platform's announcement for this tick: the true number withdrawn so
        # far, understated by the spin b·ρ^(t-1)·N. Announced once at the start of
        # the tick, so it lags withdrawals made within the tick. Common to all
        # agents (contrast the neighbour share, which is local). No RNG draws.
        # BANKRUN_PUBLIC_MODE = stale (Chapter 1's stale level y): the announced
        # level is the true count at its last refresh, at tick 1 and then every
        # BANKRUN_PUBLIC_REFRESH ticks (0 = never), so it falls behind the run.
        # The agent's view of the bank is frozen with it (2026-10-21): decisions
        # simulate from the bank's state at the last refresh plus the agent's
        # own withdrawn neighbours, never from the true current state. With
        # refresh 0 the view is the post-shock snapshot (the published stale clone).
        if publicOn
            trueWithdrawn = partial ? count(anyOut) : length(mod.theBank.withdrawHistory)
            if publicStale && (t == 1 || (publicRefresh > 0 && (t - 1) % publicRefresh == 0))
                staleLevel = trueWithdrawn
                staleView = SubState(mod)
            end
            announced = publicStale ? staleLevel : trueWithdrawn
            publicPoint = clamp(round(Int64, announced - pubBias * pubRho^(t-1) * nAgents),
                                0, nAgents-1)
            record === nothing || notePublic!(record, t, publicPoint - trueWithdrawn)
            CSV.write(dataDir*"/"*"bankRunPublic"*string(workerCore)*".csv",
                      DataFrame(key=mod.key, tick=t, trueWithdrawn=trueWithdrawn,
                                publicPoint=publicPoint),
                      writeheader=false, append=true)
        end
        yNow = thetaPubOn ? thetaPublicAt(thetaPublic, theta, t; level=thetaPubLevel,
                                          gap=thetaPubGap, rho=thetaPubRho) : nothing
        stillBanking=Random.shuffle(mod.theBank.bankingList)
        # each agent observes the percentage of its neighbors that have withdrawn
        for agt in stillBanking
            withdrawnNeighbors, neighbourEstimate = partial ?
                neighbourSignalPartial(mod, agt, anyOut) : neighbourSignal(mod, agt)
            priorDraws = beliefDraws(mod, depth; belief=belief, p0=beliefP0)
            # Informative private signal: replace the draws (made above anyway, to
            # keep the main RNG stream aligned with the uninformative model).
            privatePost === nothing || (priorDraws = privateDraws(privatePost, agt, depth))
            # The state the agent simulates from. Stale mode: its stale view.
            # BANKRUN_FRESH_CLONE: the current state, not the post-shock
            # snapshot taken once above (the "stale clone").
            decisionState = publicStale ? staleView : freshClone ? SubState(mod) : staleState
            # The extra count is measured against the withdrawals the sub-model
            # already holds: with a fresh clone the true total, in stale mode the
            # view's total plus newly out neighbours (nInView). The published
            # stale clone measures it against the observed neighbours.
            alreadyOut = (publicStale || freshClone) ?
                nInView(decisionState, withdrawnNeighbors; skipWithdrawn=skipWithdrawn) :
                length(withdrawnNeighbors)
            additionalWithdrawals = anticipatedWithdrawals(agt, priorDraws, neighbourEstimate, publicPoint,
                                                           alreadyOut, nAgents, t;
                                                           pubAlpha=pubAlpha, weightPhi=weightPhi,
                                                           λ=λcountOf(agt))
            # Fire-sale bank: the long asset's return in each draw, from the
            # agent's belief about θ (its prior, its posterior given x_i, or
            # Chapter 1's blend of x_i and y). ω decays with φ as the
            # head-count weight does (φ = 1 by default).
            ωθ = yNow === nothing ? 0.0 :
                (weightPhi == 1.0 ? λthetaOf(agt) : λthetaOf(agt) * weightPhi^(t-1))
            returns = !balanceFire ? nothing :
                !thetaOn ? fill(returnHi, depth) :
                thetaSignal === nothing ? returnOf.(rand(beliefRng, depth)) :
                returnOf.(rand(beliefRng, thetaBelief(thetaSignal[agt.idx], thetaNoise, yNow, ωθ,
                                                      thetaPubNoise), depth))
            rngBefore = partial ? copy(Random.default_rng()) : nothing
            payStay = caraA > 0.0 ?
                stayDraws(decisionState, agt, withdrawnNeighbors, additionalWithdrawals;
                          skipWithdrawn=skipWithdrawn, returns=returns, stayReturn=stayReturn) : nothing
            probFullDepositStay = payStay !== nothing ? mean(payStay) / (stayReturn * agt.deposit) :
                simulateStay(decisionState, agt, withdrawnNeighbors, additionalWithdrawals;
                             skipWithdrawn=skipWithdrawn, payoff=payoffMode,
                             returns=returns, stayReturn=stayReturn)
            probFullDepositWD = payoffIfWithdrawNow(decisionState, agt; recovery=payoffMode == "recovery")
            withdrew = decide(probFullDepositWD, probFullDepositStay; tiebreak=tiebreak,
                              stayReturn=stayReturn)
            frac = withdrew ? 1.0 : 0.0
            if caraA > 0.0
                # CARA: certainty equivalents per unit of balance. Staying values
                # the stay draws; withdrawing all is paid for sure. Under partial,
                # every agent values the interior fractions (risk aversion can
                # make even a small depositor hedge). A large one (above the
                # cutoff) moves the bank, so each fraction is re-simulated on the
                # same draws, as in the risk-neutral rule; a small one does not,
                # so the fraction's stay draws are the balance left in times
                # staying's, and the fraction is paid in full.
                b = agt.deposit
                big = partial && b > partialMin * capacityOf(decisionState)
                big && (nBigDecisions += 1)
                rngAfter = big ? copy(Random.default_rng()) : nothing
                vInterior = !partial ? () : map(grid) do f
                    sf, paid = afterOwnWithdrawal(decisionState, agt.idx, f * b)
                    sf.vault < 0.0 && return -Inf
                    pay = big ? (copy!(Random.default_rng(), rngBefore);
                                 stayDraws(sf, agt, withdrawnNeighbors, additionalWithdrawals;
                                           skipWithdrawn=skipWithdrawn, returns=returns,
                                           stayReturn=stayReturn)) :
                                (1.0 - f) .* payStay
                    ceValue(paid .+ pay, caraA) / b
                end
                big && copy!(Random.default_rng(), rngAfter)
                frac = chooseFraction(ceValue(payStay, caraA) / b, probFullDepositWD, vInterior;
                                      tiebreak=tiebreak, pStay=probFullDepositStay, grid=grid)
                withdrew = frac > 0.0
            elseif partial && agt.deposit > partialMin * capacityOf(decisionState)
                nBigDecisions += 1
                rngAfter = copy(Random.default_rng())
                vInterior = map(grid) do f
                    copy!(Random.default_rng(), rngBefore)
                    partialValue(decisionState, agt, f, withdrawnNeighbors, additionalWithdrawals;
                                 skipWithdrawn=skipWithdrawn, returns=returns, stayReturn=stayReturn)
                end
                copy!(Random.default_rng(), rngAfter)
                frac = chooseFraction(stayReturn * probFullDepositStay, probFullDepositWD, vInterior;
                                      tiebreak=tiebreak, pStay=probFullDepositStay, grid=grid)
                withdrew = frac > 0.0
            end
            if balanceFire && record !== nothing
                push!(record.nbAgent, agt.idx)
                push!(record.nbShare, neighbourEstimate / nAgents)
                push!(record.nbWithdrew, withdrew)
            end
            if withdrew
                amount = frac * agt.deposit
                paid = frac == 1.0 ? withdraw(mod, agt) : withdrawPart!(mod, agt, amount)
                frac < 1.0 && (nPartialEvents += 1)
                partial && (anyOut[agt.idx] = true)
                record === nothing || record!(record, agt.idx, paid, t, amount)
            end
            if logFull()
                reportRow=DataFrame(key=mod.key,agent=agt.idx,withdraw=withdrew,deposit=agt.deposit,
                    tick=t,vault=mod.theBank.vault,wdProb=probFullDepositWD,stayProb=probFullDepositStay)
                CSV.write(dataDir*"/"*"bankRunEndogenous"*string(workerCore)*".csv",reportRow,writeheader=false,append=true)
            end
            withdrew && (halt = false)

            if failedNow()
                # if the bank is bankrupt, we need to stop the simulation
                runState=true
                break
            end
        end
    end
    # Fire-sale bank: once the cascade has stopped without a liquidity failure,
    # period 2. The bank fails if cash plus the long asset at its realised return
    # cannot pay the stayers' promises (Chapter 1's A > A*(θ)).
    if balanceFire
        liquidityFail = runState
        promises = stayReturn * sum(a.deposit for a in mod.theBank.bankingList; init=0.0)
        assetsT = max(mod.theBank.vault, 0.0) + mod.theBank.illiquid * returnOf(theta)
        solvent = !liquidityFail && assetsT >= promises
        runState = !solvent
        record === nothing ||
            (record.endRho = liquidityFail ? 0.0 : promises > 0.0 ? assetsT / promises : Inf)
        deps = partial ? dep0 : [a.deposit for a in mod.agtList]
        big = argmax(deps)
        CSV.write(dataDir*"/"*"bankRunBalance"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, theta=theta, returnTheta=returnOf(theta),
                            vaultInit=vault0, illiquidInit=illiquid0,
                            vaultFinal=mod.theBank.vault, illiquidFinal=mod.theBank.illiquid,
                            assetsT=assetsT, promises=promises, solvent=solvent,
                            failType=liquidityFail ? "liquidity" : (solvent ? "none" : "insolvency"),
                            largestShare=deps[big] / sum(deps),
                            largestToCapacity=deps[big] / (vault0 + (1.0 - fireDiscount) * illiquid0),
                            largestWithdrew=partial ? anyOut[big] : !mod.agtList[big].banked),
                  writeheader=false, append=true)
    end
    if partial
        # Remaining balances (0 for agents fully out), then the original deposits back.
        left = [a.banked ? a.deposit : 0.0 for a in mod.agtList]
        big = argmax(dep0)
        out = dep0 .- left
        CSV.write(dataDir*"/"*"bankRunPartial"*string(workerCore)*".csv",
                  DataFrame(key=mod.key, nAnyOut=count(anyOut),
                            nStillIn=count(i -> anyOut[i] && mod.agtList[i].banked, 1:nAgents),
                            nPartialEvents=nPartialEvents, nBigDecisions=nBigDecisions,
                            withdrawnShare=sum(out) / sum(dep0),
                            largestFracWithdrawn=out[big] / dep0[big]),
                  writeheader=false, append=true)
        for a in mod.agtList; a.deposit = dep0[a.idx]; end
        return (runState, count(anyOut), sum(out))
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
    # Docking outputs (2026-10-20; scripts/README.md "Docking outputs"):
    tick::Vector{Int}          # tick of each withdrawal (0 = exogenous shock)
    nTicks::Int                # ticks the run lasted
    pubErr1::Float64           # public announcement − true count at tick 1 (NaN if no announcement)
    pubErrSum::Float64         # … summed over ticks with an announcement
    pubErrN::Int               # … number of such ticks
    amount::Vector{Float64}    # amount withdrawn (endogenous; NaN for the exogenous shock)
    # Every decision in a fire-sale run (2026-10-22, rung-4 scorecard S3): the
    # agent, the share of its neighbours already out when it decided (any
    # withdrawal counts under WITHDRAW = partial), and whether it withdrew.
    nbAgent::Vector{Int}
    nbShare::Vector{Float64}
    nbWithdrew::Vector{Bool}
    # Fire-sale bank, end of the run (2026-10-29, Rule B): assets over the stayers'
    # promises (0 after a liquidity failure, Inf if nobody stayed; NaN otherwise).
    endRho::Float64
end
RunRecord() = RunRecord(Int[], Float64[], 0, Int[], 0, NaN, 0.0, 0, Float64[], Int[], Float64[], Bool[], NaN)
record!(r::RunRecord, idx::Int, paid::Float64, tick::Int=0, amount::Float64=NaN) =
    (push!(r.order, idx); push!(r.paid, paid); push!(r.tick, tick); push!(r.amount, amount); r)
function notePublic!(r::RunRecord, t::Int, err::Real)
    t == 1 && (r.pubErr1 = err)
    r.pubErrSum += err; r.pubErrN += 1
    return r
end

# One row per type: who withdrew (exogenously / endogenously), how much they held
# and were paid, deposits left with stayers, and the endogenous withdrawers'
# position in the withdrawal order (0 = first, 1 = last; 0.5 if only one), as in
# scripts/who_runs_pilot.py.
# Insured vs uninsured (2026-10-20): an agent is insured when its deposit is at
# most the quantile insurance cap (insuranceCap below). Under the adaptive scheme
# the cap moves during the run, insuranceCap is NaN and every agent counts as
# uninsured, so these five columns are not meaningful there.
insuranceCap(mod::Model) = 0.0 <= mod.depositInsurance < 1.0 ?
    quantile(mod.depositDistribution, mod.depositInsurance) : NaN

function typeSummary(mod::Model, isI::AbstractVector{Bool}, rec::RunRecord)
    cap = insuranceCap(mod)
    n = length(mod.agtList)
    how = zeros(Int8, n)                 # 0 stayed, 1 exogenous, 2 endogenous
    paid = zeros(Float64, n)
    pos = fill(NaN, n)
    # WITHDRAW = partial: an agent can withdraw several times. It counts once, at
    # its first endogenous withdrawal; paid and wd sum over its withdrawals. With
    # one withdrawal per agent (WITHDRAW = all) this is the published summary.
    partial = switchValue(:WITHDRAW) == "partial"
    wd = zeros(Float64, n)
    endogOrder = Int[]
    for (k, i) in enumerate(rec.order)
        paid[i] += rec.paid[k]
        if k <= rec.nExog
            how[i] = 1
            wd[i] = mod.agtList[i].deposit
        else
            how[i] == 2 || push!(endogOrder, i)
            how[i] = 2
            partial && (wd[i] += rec.amount[k])
        end
    end
    nEndog = length(endogOrder)
    for (r, i) in enumerate(endogOrder)
        pos[i] = nEndog > 1 ? (r - 1) / (nEndog - 1) : 0.5
    end
    rows = DataFrame(key=String[], type=String[], n=Int[], nExog=Int[], nEndog=Int[],
                     depTotal=Float64[], depExog=Float64[], depEndog=Float64[],
                     paidExog=Float64[], paidEndog=Float64[], depStayers=Float64[],
                     posSumEndog=Float64[], nFirstQuarter=Int[],
                     nInsured=Int[], nEndogInsured=Int[], depUninsured=Float64[],
                     depStayersUninsured=Float64[], nStayersUninsured=Int[])
    for (lab, sel) in (("I", isI), ("C", .!isI))
        idx = findall(sel)
        d = [mod.agtList[i].deposit for i in idx]
        h = how[idx]
        w = wd[idx]
        # partial: deposits withdrawn endogenously, and every balance left in
        push!(rows, (mod.key, lab, length(idx), count(==(1), h), count(==(2), h),
                     sum(d; init=0.0), sum(d[h .== 1]; init=0.0),
                     partial ? sum(w[h .== 2]; init=0.0) : sum(d[h .== 2]; init=0.0),
                     sum(paid[idx][h .== 1]; init=0.0), sum(paid[idx][h .== 2]; init=0.0),
                     partial ? sum((d .- w)[h .!= 1]; init=0.0) : sum(d[h .== 0]; init=0.0),
                     sum(pos[idx][h .== 2]; init=0.0), count(<=(0.25), pos[idx][h .== 2]),
                     count(d .<= cap), count((d .<= cap) .& (h .== 2)),
                     sum(d[.!(d .<= cap)]; init=0.0), sum(d[.!(d .<= cap) .& (h .== 0)]; init=0.0),
                     count(.!(d .<= cap) .& (h .== 0))))
    end
    return rows
end

# Docking outputs (2026-10-20), written by runRow next to bankRunTypes. The model
# is unchanged; these only expose quantities the Ch 1 mapping and the Ch 2
# comparison need (scripts/README.md "Docking outputs").
#   bankRunDock:   one row per run. The exogenous shock (count, deposit share),
#                  Chapter 1's theta as solvency slack after it, the public
#                  announcement's error (announced − true count, at tick 1 and
#                  averaged over ticks; NaN when there is no announcement), and
#                  how many ticks the run lasted.
#                  reserveShare and slack are vault-bank quantities: they ignore
#                  the long asset. Under BANKRUN_BALANCE = firesale the bank's
#                  period-1 capacity is vault + (1 − d)·illiquid and its solvency
#                  is decided at period 2; read bankRunBalance for those arms
#                  (2026-10-21), not slack.
#   bankRunTiming: one row per run x type. Endogenous withdrawals by tick
#                  (1..TIMING_TICKS-1, then TIMING_TICKS and later) and their
#                  tick sum: the discrete-time hazard counterpart to Ch 2's Cox model.
#   bankRunWealth: one row per run x type. Agents and endogenous withdrawers by
#                  decile of the run's own deposit distribution (1 = smallest).
const TIMING_TICKS = 10

function dockRow(mod::Model, rec::RunRecord, vaultInit::Float64)
    depTotal = sum(a.deposit for a in mod.agtList; init=0.0)
    exog = rec.order[1:rec.nExog]
    depExog = sum(mod.agtList[i].deposit for i in exog; init=0.0)
    paidExog = sum(rec.paid[1:rec.nExog]; init=0.0)
    return DataFrame(key=mod.key, nExog=rec.nExog, depExogShare=depExog / depTotal,
                     reserveShare=vaultInit / depTotal, slack=(vaultInit - paidExog) / depTotal,
                     pubErr1=rec.pubErr1,
                     pubErrMean=rec.pubErrN > 0 ? rec.pubErrSum / rec.pubErrN : NaN,
                     nTicks=rec.nTicks)
end

function timingRows(mod::Model, isI::AbstractVector{Bool}, rec::RunRecord)
    cols = [Symbol("t", k == TIMING_TICKS ? "$(k)plus" : "$k") for k in 1:TIMING_TICKS]
    df = DataFrame(key=String[], type=String[], tickSumEndog=Int[])
    for c in cols; df[!, c] = Int[]; end
    for (lab, want) in (("I", true), ("C", false))
        counts = zeros(Int, TIMING_TICKS); tsum = 0
        seen = falses(length(isI))       # partial: an agent counts at its first withdrawal
        for k in (rec.nExog + 1):length(rec.order)
            isI[rec.order[k]] == want || continue
            seen[rec.order[k]] && continue
            seen[rec.order[k]] = true
            t = rec.tick[k]; tsum += t
            counts[clamp(t, 1, TIMING_TICKS)] += 1
        end
        push!(df, (mod.key, lab, tsum, counts...))
    end
    return df
end

# bankRunNeighbour (2026-10-22, fire-sale runs only): one row per run x type.
# Decisions and withdrawals by the share of the agent's neighbours already out
# when it decided (the neighbour signal's share, to 1/N), in NB_BINS: 0, then
# (0, 0.1], (0.1, 0.2], (0.2, 0.35], (0.35, 0.5], (0.5, 1]. The discrete-time
# counterpart of "depositors run when their network runs" (Iyer & Puri 2012;
# Kelly & Ó Gráda 2000).
const NB_BINS = (0.0, 0.1, 0.2, 0.35, 0.5, 1.0)
nbBin(x) = x <= 0.0 ? 1 : 1 + something(findfirst(b -> x <= b, NB_BINS[2:end]), length(NB_BINS) - 1)

function neighbourRows(mod::Model, isI::AbstractVector{Bool}, rec::RunRecord)
    nb = length(NB_BINS)
    df = DataFrame(key=String[], type=String[])
    for j in 1:nb; df[!, Symbol("dec_b$(j-1)")] = Int[]; end
    for j in 1:nb; df[!, Symbol("wd_b$(j-1)")] = Int[]; end
    for (lab, want) in (("I", true), ("C", false))
        dec, wd = zeros(Int, nb), zeros(Int, nb)
        for k in eachindex(rec.nbAgent)
            isI[rec.nbAgent[k]] == want || continue
            j = nbBin(rec.nbShare[k])
            dec[j] += 1
            rec.nbWithdrew[k] && (wd[j] += 1)
        end
        push!(df, (mod.key, lab, dec..., wd...))
    end
    return df
end

# bankRunExitShape (2026-10-22, WITHDRAW = partial; rung-4 S1, docs/rung4_prereg.md):
# one row per run x type. For each size group of the bank's own deposits (deciles
# D1-D10, the top 1% and the top 0.1% of agents, at least one agent each): agents
# not hit by the shock, exiters (withdrew anything endogenously), one-shot
# exiters (a single endogenous withdrawal, so all of it in one tick), and partial
# exiters (still holding part of their deposit at the end).
const EXIT_GROUPS = vcat(["d$j" for j in 1:10], ["top1", "top01"])

function exitShapeRows(mod::Model, isI::AbstractVector{Bool}, rec::RunRecord)
    n = length(mod.agtList)
    d = [a.deposit for a in mod.agtList]
    cuts = quantile(d, 0.1:0.1:0.9)
    dec = [1 + count(x .> cuts) for x in d]
    ord = sortperm(d; rev=true)
    top1 = falses(n); top1[ord[1:max(1, round(Int, 0.01n))]] .= true
    top01 = falses(n); top01[ord[1:max(1, round(Int, 0.001n))]] .= true
    exog = falses(n); for k in 1:rec.nExog; exog[rec.order[k]] = true; end
    events = zeros(Int, n); taken = zeros(Float64, n)
    for k in (rec.nExog + 1):length(rec.order)
        i = rec.order[k]; events[i] += 1; taken[i] += rec.amount[k]
    end
    exit = events .> 0
    oneshot = events .== 1
    part = exit .& (taken .< d .* (1 - 1e-9))
    df = DataFrame(key=String[], type=String[])
    for g in EXIT_GROUPS, f in ("n", "exit", "oneshot", "partial")
        df[!, Symbol("$(f)_$(g)")] = Int[]
    end
    for (lab, want) in (("I", true), ("C", false))
        vals = Int[]
        for g in EXIT_GROUPS
            sel = (isI .== want) .& .!exog .&
                  (g == "top1" ? top1 : g == "top01" ? top01 : dec .== parse(Int, g[2:end]))
            push!(vals, count(sel), count(sel .& exit), count(sel .& oneshot), count(sel .& part))
        end
        push!(df, (mod.key, lab, vals...))
    end
    return df
end

function wealthRows(mod::Model, isI::AbstractVector{Bool}, rec::RunRecord)
    d = [a.deposit for a in mod.agtList]
    cuts = quantile(d, 0.1:0.1:0.9)
    dec = [1 + count(x .> cuts) for x in d]
    endog = falses(length(d))
    for k in (rec.nExog + 1):length(rec.order); endog[rec.order[k]] = true; end
    df = DataFrame(key=String[], type=String[])
    for j in 1:10; df[!, Symbol("n_d$j")] = Int[]; end
    for j in 1:10; df[!, Symbol("endog_d$j")] = Int[]; end
    for (lab, want) in (("I", true), ("C", false))
        sel = isI .== want
        push!(df, (mod.key, lab, [count(sel .& (dec .== j)) for j in 1:10]...,
                   [count(sel .& endog .& (dec .== j)) for j in 1:10]...))
    end
    return df
end

# ---- Repeated episodes (2026-10-28; docs/learning_design.md, L1) -------------
# A run of E episodes plays the bank-run phase E times on one population: the
# network, agents, types and λ persist; θ, the shock and the private signals are
# redrawn. Everything modelRun draws comes from mod.seed2 (the main stream, and
# the θ and belief streams derived from it), so an episode is reseeded through
# seed2: episode 1 keeps the run's own seed (E = 1 is the single-episode model,
# byte for byte), episode e > 1 uses episodeSeed(seed2, e), the same in every arm.

"""The seed2 of episode `e` of a run whose own seed2 is `seed2` (non-negative)."""
episodeSeed(seed2::Int64, e::Integer) = e == 1 ? seed2 :
    reinterpret(Int64, (reinterpret(UInt64, seed2) ⊻ (UInt64(e - 1) * 0x9e3779b97f4a7c15)) &
                       0x7fffffffffffffff)

"""θ as modelRun draws it for a model with this seed2 (1 unless the fire-sale bank
draws a fundamental): the first draw of its θ stream."""
episodeTheta(seed2::Int64) =
    switchValue(:BALANCE) == "firesale" && switchValue(:FUNDAMENTAL) == "theta" ?
        rand(MersenneTwister(xor(reinterpret(UInt64, seed2), 0x7f4a7c15f39cc060))) : 1.0

"""The bank and deposits as modelGenTyped left them, to restore between episodes
(EPISODE_RESET = bank: a fresh bank, the same people)."""
struct BankStart
    deposits::Vector{Float64}
    vault::Float64
    illiquid::Float64
    seed2::Int64
end
BankStart(mod::Model) = BankStart([a.deposit for a in mod.agtList], mod.theBank.vault,
                                  mod.theBank.illiquid, mod.seed2)

"""Give `mod` a fresh bank for episode `e`: initial deposits, everyone banked, the
initial vault and long asset, an empty withdrawal history, and the episode's seed."""
function resetEpisode!(mod::Model, start::BankStart, e::Integer)
    for a in mod.agtList
        a.deposit = start.deposits[a.idx]
        a.banked = true
    end
    mod.theBank.vault = start.vault
    mod.theBank.illiquid = start.illiquid
    mod.theBank.bankingList = copy(mod.agtList)      # modelGenTyped's order
    mod.theBank.withdrawHistory = Agent[]
    mod.seed2 = episodeSeed(start.seed2, e)
    return mod
end

meanOrNaN(x) = isempty(x) ? NaN : mean(x)
sdOrNaN(x) = length(x) > 1 ? std(x) : NaN

# ---- Learning, L2 Rule A: precision learning of the θ weight (2026-10-28) ------
# docs/learning_design.md §4. Scores the θ signals only (the user): after each
# episode θ is revealed, each agent updates its running squared error of its
# private signal x_i and of the public signal y (y at tick 1, the level announced),
#     MSE ← (1 − η)·MSE + η·error²,   starting at THETA_NOISE² and THETA_PUBLIC_NOISE²,
# and weights y in the θ blend by
#     ω_i = (1 − κ)·λ_i + κ·MSE_x / (MSE_x + MSE_y)
# (κ = LEARN_GRIP, η = LEARN_MEMORY). The cultural λ_i (agt.individualism) never
# changes, so the head-count blend keeps it. Episode 1 uses λ_i (no experience yet),
# so its outcome is the no-learning model's.

"""The learner's state over a run: cultural λ, running squared errors, θ weights."""
mutable struct LearnState
    culture::Vector{Float64}
    msex::Vector{Float64}
    msey::Vector{Float64}
    weight::Vector{Float64}
    learned::Vector{Float64}   # Rule B's ω*, starting at the cultural λ (unused by Rule A)
end
LearnState(culture, msex, msey, weight) = LearnState(culture, msex, msey, weight, copy(culture))
function LearnState(mod::Model)
    # the parse-time checks (settings.jl switchComboError), for scripts and tests
    # that set the switches directly
    (switchValue(:BALANCE) == "firesale" && switchValue(:FUNDAMENTAL) == "theta" &&
     switchValue(:PRIVATE_SIGNAL) == "theta" && switchValue(:THETA_PUBLIC) != "none" &&
     switchValue(:LAMBDA_SCOPE) != "count") ||
        error("BANKRUN_LEARN=$(switchValue(:LEARN)) needs the fire-sale bank with θ, PRIVATE_SIGNAL=theta, " *
              "a THETA_PUBLIC signal and LAMBDA_SCOPE theta or both")
    λ = [a.individualism for a in mod.agtList]
    n = length(λ)
    return LearnState(λ, fill(switchValue(:THETA_NOISE)^2, n),
                      fill(switchValue(:THETA_PUBLIC_NOISE)^2, n), copy(λ))
end

"""θ and the private signals x as modelRun draws them for this seed2 (fire-sale bank,
θ fundamental, private signal of θ): the first draws of its θ stream."""
function episodeThetaDraws(seed2::Int64, n::Integer)
    rng = MersenneTwister(xor(reinterpret(UInt64, seed2), 0x7f4a7c15f39cc060))
    θ = rand(rng)
    s = switchValue(:THETA_NOISE)
    return θ, [θ + s * randn(rng) for _ in 1:n]
end

"""The public signal y at tick 1 for this θ (what Rule A scores)."""
publicAtStart(θ::Float64) =
    thetaPublicAt(switchValue(:THETA_PUBLIC), θ, 1; level=switchValue(:THETA_PUBLIC_LEVEL),
                  gap=switchValue(:THETA_PUBLIC_GAP), rho=switchValue(:THETA_PUBLIC_RHO))

"""Rule A after an episode with fundamental θ, private signals x and public signal y."""
function learnUpdate!(L::LearnState, x::Vector{Float64}, θ::Float64, y::Float64;
                      grip::Float64, memory::Float64)
    @. L.msex = (1.0 - memory) * L.msex + memory * (x - θ)^2
    L.msey .= (1.0 - memory) .* L.msey .+ memory * (y - θ)^2
    @. L.weight = (1.0 - grip) * L.culture + grip * L.msex / (L.msex + L.msey)
    return L
end

# ---- Learning, L2 Rule B: payoff learning, the signal-direction rule (2026-10-29) ---
# docs/learning_design.md §4. The feedback comes from outcomes, so insurance enters
# it. After each episode, for each agent: did staying to the end pay more per unit of
# deposit than withdrawing at par at the start? Staying pays R if the bank is solvent,
# else max(ρR, the insured share) (stayerPayoff's rule). The signal that pointed
# toward the better action (the higher of x_i and y if staying paid more, the lower
# if withdrawing did) is the one to trust, so the learned weight moves toward 1 (y)
# or 0 (x):
#     ω* ← (1 − η)·ω* + η·target,   ω = (1 − κ)·λ + κ·ω*
# No move on a tie in payoff (e.g. a fully insured stayer in a failed bank) or in
# the signals. Uses only what happened: no counterfactual decisions.

"""Per unit of deposit, what staying to the end paid each agent, given the end-of-run
ratio ρ of assets to promises, the deposits, the insurance cap and R."""
stayValue(rho::Float64, deps::Vector{Float64}, cap::Float64, R::Float64) =
    [rho >= 1.0 ? R : max(rho * R, min(d, cap) / d) for d in deps]

"""Rule B after an episode with private signals x, public signal y and stay values."""
function payoffUpdate!(L::LearnState, x::Vector{Float64}, y::Float64, stay::Vector{Float64};
                       grip::Float64, memory::Float64)
    for i in eachindex(x)
        s = sign(stay[i] - 1.0) * sign(y - x[i])    # +1: y pointed the right way; −1: x did
        s == 0 && continue
        L.learned[i] = (1.0 - memory) * L.learned[i] + memory * (s > 0 ? 1.0 : 0.0)
    end
    @. L.weight = (1.0 - grip) * L.culture + grip * L.learned
    return L
end

# ---- Learning, L3a: imitation (2026-10-29) ----------------------------------------
# docs/learning_design.md §5. After each episode each agent looks at one network
# neighbour j, drawn at random, and if j's realised payoff per unit of deposit beat
# its own, moves its learned weight toward j's:
#     ω*_i ← (1 − η)·ω*_i + η·ω*_j   (if π_j > π_i),   ω = (1 − κ)·λ + κ·ω*
# π is what the agent was actually paid: its withdrawals, plus the stay value on
# what it left in (stayValue's rule, so insurance enters). The update is
# synchronous (every j's ω* from before the round). Under payoff+imitate, Rule B
# moves ω* first and imitation reads the result. The neighbour draws use their own
# stream from the episode's seed, so the model's other draws are untouched.

"""Per unit of its deposit at the start of the episode, what each agent was paid:
its withdrawals plus, on what it left in, the stay value per unit (`stay`)."""
function realisedPayoff(mod::Model, rec::RunRecord, deps0::Vector{Float64}, stay::Vector{Float64})
    π = zeros(length(mod.agtList))
    for (k, i) in enumerate(rec.order)
        π[i] += rec.paid[k]
    end
    for a in mod.agtList
        a.banked && a.deposit > 0.0 && (π[a.idx] += stay[a.idx] * a.deposit)
    end
    return π ./ deps0
end

"""The neighbour draws for an episode run under seed `seed2` (mod.seed2 after resetEpisode!)."""
imitationRng(seed2::Int64) = MersenneTwister(xor(reinterpret(UInt64, seed2), 0x2545f4914f6cdd1d))

"""L3a after an episode with realised payoffs π: one random neighbour each."""
function imitateUpdate!(L::LearnState, network, π::Vector{Float64}, rng::AbstractRNG;
                        grip::Float64, memory::Float64)
    before = copy(L.learned)
    for i in eachindex(π)
        nb = all_neighbors(network, i)
        isempty(nb) && continue
        j = nb[rand(rng, 1:length(nb))]
        π[j] > π[i] && (L.learned[i] = (1.0 - memory) * before[i] + memory * before[j])
    end
    @. L.weight = (1.0 - grip) * L.culture + grip * L.learned
    return L
end

"""One row per type for episode `e`: θ, whether the bank failed, withdrawals by
type, cultural λ by type, and the θ weight used and the squared errors entering
the episode (with learning; else the cultural θ weight and NaN)."""
function episodeRows(mod::Model, isI::AbstractVector{Bool}, rec::RunRecord, e::Integer, failed::Bool,
                     learn=nothing)
    ts = typeSummary(mod, isI, rec)
    λ = [a.individualism for a in mod.agtList]
    sel = Dict("I" => isI, "C" => .!isI)
    nanv = fill(NaN, length(λ))
    ω = learn !== nothing ? learn.weight :
        switchValue(:LAMBDA_SCOPE) == "count" ? fill(mean(λ), length(λ)) : λ
    rmse = learn !== nothing && switchValue(:LEARN) == "precision"
    mx = rmse ? learn.msex : nanv
    my = rmse ? learn.msey : nanv
    # key, type first: the per-type layout consolidate_results.py reads (DOCK_FILES)
    return DataFrame(key=ts.key, type=ts.type, episode=e, seed2=mod.seed2,
                     theta=episodeTheta(mod.seed2), failed=failed,
                     n=ts.n, nExog=ts.nExog, nEndog=ts.nEndog,
                     depTotal=ts.depTotal, depEndog=ts.depEndog,
                     lambdaMean=[meanOrNaN(λ[sel[t]]) for t in ts.type],
                     lambdaSd=[sdOrNaN(λ[sel[t]]) for t in ts.type],
                     weightMean=[meanOrNaN(ω[sel[t]]) for t in ts.type],
                     weightSd=[sdOrNaN(ω[sel[t]]) for t in ts.type],
                     msexMean=[meanOrNaN(mx[sel[t]]) for t in ts.type],
                     mseyMean=[meanOrNaN(my[sel[t]]) for t in ts.type])
end

writeEpisode(mod::Model, isI, rec::RunRecord, e::Integer, failed::Bool, learn=nothing) =
    CSV.write(dataDir*"/"*"bankRunEpisodes"*string(workerCore)*".csv",
              episodeRows(mod, isI, rec, e, failed, learn), writeheader=false, append=true)

"""Episodes 1..E-1 of a run, then the reset for episode E. modelRun's own files
(and the per-run files runRow writes) are kept for the last episode only: the
early episodes write them to a scratch directory, which is deleted. Each early
episode adds its rows to bankRunEpisodes. Under BANKRUN_LEARN other than none, the
learner updates after each episode; returns its state (the θ weights for the
last episode), else nothing."""
function earlyEpisodes!(mod::Model, isI::AbstractVector{Bool}, episodes::Integer)
    global dataDir
    switchValue(:EPISODE_RESET) == "bank" ||
        error("BANKRUN_EPISODE_RESET=$(switchValue(:EPISODE_RESET)) is not built")
    start = BankStart(mod)
    rule = switchValue(:LEARN)
    learn = rule == "none" ? nothing : LearnState(mod)
    grip, memory = switchValue(:LEARN_GRIP), switchValue(:LEARN_MEMORY)
    realDir = dataDir
    scratch = mktempdir()
    try
        for e in 1:(episodes - 1)
            resetEpisode!(mod, start, e)
            rec = RunRecord()
            dataDir = scratch
            failed = modelRun(mod; record=rec,
                              thetaWeight=learn === nothing ? nothing : learn.weight)[1]
            dataDir = realDir
            writeEpisode(mod, isI, rec, e, failed, learn)
            if learn !== nothing
                θ, x = episodeThetaDraws(mod.seed2, length(mod.agtList))
                if rule == "precision"
                    learnUpdate!(learn, x, θ, publicAtStart(θ); grip=grip, memory=memory)
                else
                    stay = stayValue(rec.endRho, [a.deposit for a in mod.agtList], currentCap(mod),
                                     switchValue(:STAY_RETURN))
                    rule in ("payoff", "payoff+imitate") &&
                        payoffUpdate!(learn, x, publicAtStart(θ), stay; grip=grip, memory=memory)
                    rule in ("imitate", "payoff+imitate") &&
                        imitateUpdate!(learn, mod.network, realisedPayoff(mod, rec, start.deposits, stay),
                                       imitationRng(mod.seed2); grip=grip, memory=memory)
                end
            end
        end
    finally
        dataDir = realDir
        rm(scratch; recursive=true, force=true)
    end
    resetEpisode!(mod, start, episodes)
    return learn
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
    # BANKRUN_EPISODES > 1: episodes 1..E-1 first, then the last one below, which
    # writes the per-run files exactly as a single-episode run does.
    episodes = switchValue(:EPISODES)
    learn = episodes > 1 ? earlyEpisodes!(mod, isI, episodes) : nothing
    vaultInit = mod.theBank.vault      # before the exogenous shock
    rec = RunRecord()
    rMod, nWithdrawn, depositWithdrawn =
        modelRun(mod; record=rec, thetaWeight=learn === nothing ? nothing : learn.weight)
    episodes > 1 && writeEpisode(mod, isI, rec, episodes, rMod, learn)
    # Widened 2026-08-13 from (key, result) to carry |S*|. Readers that take
    # only the first two columns are unaffected.
    resultRow=DataFrame(key=row[:key],result=rMod,
                        nWithdrawn=nWithdrawn,depositWithdrawn=depositWithdrawn)
    CSV.write(dataDir*"/"*"bankRunResults"*string(workerCore)*".csv",resultRow,writeheader=false,append=true)
    # Vault at start and end of the run (added 2026-10-15), for the share of the
    # vault paid out, 1 - max(vaultFinal, 0) / vaultInit. A separate file, so
    # bankRunResults keeps its 4 columns for the existing checkers.
    # insuranceCap added 2026-10-20 (NaN under the adaptive scheme).
    vaultRow=DataFrame(key=row[:key],vaultInit=vaultInit,vaultFinal=mod.theBank.vault,
                       insuranceCap=insuranceCap(mod))
    CSV.write(dataDir*"/"*"bankRunVault"*string(workerCore)*".csv",vaultRow,writeheader=false,append=true)
    CSV.write(dataDir*"/"*"bankRunTypes"*string(workerCore)*".csv",typeSummary(mod, isI, rec),
              writeheader=false,append=true)
    CSV.write(dataDir*"/"*"bankRunDock"*string(workerCore)*".csv",dockRow(mod, rec, vaultInit),
              writeheader=false,append=true)
    CSV.write(dataDir*"/"*"bankRunTiming"*string(workerCore)*".csv",timingRows(mod, isI, rec),
              writeheader=false,append=true)
    CSV.write(dataDir*"/"*"bankRunWealth"*string(workerCore)*".csv",wealthRows(mod, isI, rec),
              writeheader=false,append=true)
    isempty(rec.nbAgent) ||
        CSV.write(dataDir*"/"*"bankRunNeighbour"*string(workerCore)*".csv",neighbourRows(mod, isI, rec),
                  writeheader=false,append=true)
    switchValue(:WITHDRAW) == "partial" &&
        CSV.write(dataDir*"/"*"bankRunExitShape"*string(workerCore)*".csv",exitShapeRows(mod, isI, rec),
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
