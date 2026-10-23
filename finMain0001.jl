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
# Switch defaults and ENV parsers (envFloat, envBool, SWITCH_DEFAULTS).
@everywhere include("settings.jl")
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
# per decision (functions4.jl modelRun). Set by scripts/run_all.sh --depth.
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
# for itself — same pattern as ASSIGN_RULE above. If workers resolved it
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

# Public signal (Level 1, added 2026-10-08; see functions4.jl modelRun). Every
# default reproduces the model as published bit-for-bit: no new random draws,
# and the blend reduces to the old expression. Parsed once on the master and
# broadcast, same pattern as MC_DEPTH. Empty export == absent.
#
#   BANKRUN_PUBLIC_ALPHA  α ∈ [0,1]  share of the social signal that is the common
#                         public announcement rather than the local neighbour
#                         share. 0 = local only (published model), 1 = common only.
#   BANKRUN_PUBLIC_BIAS   b ∈ [0,1]  spin: the announcement understates withdrawals
#                         by b·N at tick 1 ("funds are safe").
#   BANKRUN_PUBLIC_RHO    ρ ∈ [0,1]  spin persistence: understatement b·ρ^(t-1)·N.
#                         1 = the error persists, < 1 = it corrects.
#   BANKRUN_WEIGHT_PHI    φ ∈ (0,1]  social-weight decay: ω_t = λ·φ^(t-1).
#                         1 = the weight persists (published model).
#   BANKRUN_FIX_DOUBLE_COUNT  true|false  skip already-withdrawn agents when a
#                         sub-simulation replays observed withdrawals (fixes the
#                         double count of exogenous neighbours; default false).
#   BANKRUN_FRESH_CLONE   true|false  each decision simulates from the CURRENT bank
#                         state instead of the post-shock snapshot (implies the
#                         double-count fix; default false).
#
# schuler-sync switches (2026-10-15; Schuler's BankRunsFinal changes, see
# settings.jl and functions4.jl decide / beliefDraws):
#   BANKRUN_TIEBREAK      legacy|schuler|strict  decision rule at the margin
#                         (legacy = published: also withdraw when P_WD == 0).
#   BANKRUN_BELIEF        geometric|point  the agent's own prior draws (geometric =
#                         published: the exogenous truncated Geometric).
#   BANKRUN_BELIEF_P0     p0 ∈ (0,1)  withdrawal probability of the point prior.
#   BANKRUN_LOG           full|summary  per-agent/per-decision logs, or only the
#                         run-level results and the who-runs summary (2026-10-15).
#
# Chapter 1 signal switches (2026-10-20; settings.jl, functions4.jl modelRun):
#   BANKRUN_PUBLIC_MODE     markup|stale  announcement = true count − spin, or the
#                           level frozen at its last refresh (Chapter 1's stale y).
#   BANKRUN_PUBLIC_REFRESH  k ≥ 0  stale mode: refresh every k ticks (0 = never).
#   BANKRUN_PRIVATE_SIGNAL  none|shock  uninformative prior draws, or the posterior
#                           given a noisy private signal of the realised shock.
#   BANKRUN_PRIVATE_NOISE   s > 0  s.d. of that signal, in agents (default 5).
#   BANKRUN_STAY_RETURN     R ≥ 1  stayers' return (Chapter 1's R; L = 0): withdraw
#                           iff P_WD > R·P_stay. 1 = published (default).
#   BANKRUN_PAYOFF          full|recovery  decide on P(paid in full) or on the
#                           expected recovery share (2026-10-21).
#   BANKRUN_BALANCE         vault|firesale  reserves only, or Chapter 1's bank:
#                           sell the long asset at 1 − d, fail if insolvent at the end.
#   BANKRUN_FIRE_DISCOUNT, BANKRUN_EQUITY, BANKRUN_RETURN_LO, BANKRUN_RETURN_HI
#                           the fire-sale bank's d, e and R(θ) = R_lo + (R_hi − R_lo)·θ.
#   BANKRUN_FUNDAMENTAL     none|theta  θ = 1, or θ ~ U[0,1] per run.
#   BANKRUN_PRIVATE_SIGNAL=theta with BANKRUN_THETA_NOISE s: x_i = θ + s·Z_i.
#   BANKRUN_THETA_PUBLIC    none|stale|tracks  Chapter 1's public signal y of θ
#                           (2026-10-22): est_i = (1 − ω)·x_i + ω·y. stale: y fixed
#                           at BANKRUN_THETA_PUBLIC_LEVEL; tracks: y = θ + BANKRUN_THETA_PUBLIC_GAP;
#                           the gap decays by BANKRUN_THETA_PUBLIC_RHO per tick;
#                           BANKRUN_THETA_PUBLIC_NOISE is the noise agents attribute to y.
#   BANKRUN_LAMBDA_SCOPE    count|theta|both  which blend λ weights (count =
#                           published); the other uses the population mean λ̄.
#   BANKRUN_WITHDRAW        all|partial  the whole balance or nothing (published), or a
#                           fraction of it in {0, ¼, ½, ¾, 1} (2026-10-22); agents above
#                           BANKRUN_PARTIAL_MIN_SHARE of current capacity value the fractions.
#   BANKRUN_PARTIAL_STEPS   n: the grid is k / n (4 = {0, ¼, ½, ¾, 1}, the default;
#                           2026-10-23); needs BANKRUN_WITHDRAW=partial.
#   BANKRUN_DEPOSIT_CAP     0 = none (published); c = no deposit above c of the total
#                           (2026-10-23; 0.01 = Celsius's largest account).
#   BANKRUN_CARA            0 = risk neutral (published); > 0 = CARA utility, absolute
#                           risk aversion CARA / mean initial deposit (2026-10-22).
# Since 2026-10-20 BANKRUN_FIX_DOUBLE_COUNT defaults to true; =false reproduces
# the published model.
# Defaults and parsing live in settings.jl (SWITCH_DEFAULTS, parseSwitchesFromEnv).
const SWITCHES = parseSwitchesFromEnv()
const PUBLIC_ALPHA      = SWITCHES.PUBLIC_ALPHA
const PUBLIC_BIAS       = SWITCHES.PUBLIC_BIAS
const PUBLIC_RHO        = SWITCHES.PUBLIC_RHO
const WEIGHT_PHI        = SWITCHES.WEIGHT_PHI
const FIX_DOUBLE_COUNT  = SWITCHES.FIX_DOUBLE_COUNT
const FRESH_CLONE       = SWITCHES.FRESH_CLONE
const TIEBREAK          = SWITCHES.TIEBREAK
const BELIEF            = SWITCHES.BELIEF
const BELIEF_P0         = SWITCHES.BELIEF_P0
const LOG               = SWITCHES.LOG
const PUBLIC_MODE       = SWITCHES.PUBLIC_MODE
const PUBLIC_REFRESH    = SWITCHES.PUBLIC_REFRESH
const PRIVATE_SIGNAL    = SWITCHES.PRIVATE_SIGNAL
const PRIVATE_NOISE     = SWITCHES.PRIVATE_NOISE
const STAY_RETURN       = SWITCHES.STAY_RETURN
@everywhere const PUBLIC_ALPHA     = $PUBLIC_ALPHA
@everywhere const PUBLIC_BIAS      = $PUBLIC_BIAS
@everywhere const PUBLIC_RHO       = $PUBLIC_RHO
@everywhere const WEIGHT_PHI       = $WEIGHT_PHI
@everywhere const FIX_DOUBLE_COUNT = $FIX_DOUBLE_COUNT
@everywhere const FRESH_CLONE      = $FRESH_CLONE
@everywhere const TIEBREAK         = $TIEBREAK
@everywhere const BELIEF           = $BELIEF
@everywhere const BELIEF_P0        = $BELIEF_P0
@everywhere const LOG              = $LOG
@everywhere const PUBLIC_MODE      = $PUBLIC_MODE
@everywhere const PUBLIC_REFRESH   = $PUBLIC_REFRESH
@everywhere const PRIVATE_SIGNAL   = $PRIVATE_SIGNAL
@everywhere const PRIVATE_NOISE    = $PRIVATE_NOISE
@everywhere const STAY_RETURN      = $STAY_RETURN
# The whole set, so a switch added to settings.jl reaches the workers through
# switchValue() without a const of its own here.
@everywhere const SWITCHES = $SWITCHES
println("public signal: alpha=", PUBLIC_ALPHA, " bias=", PUBLIC_BIAS, " rho=", PUBLIC_RHO,
        " phi=", WEIGHT_PHI, " fixDoubleCount=", FIX_DOUBLE_COUNT, " freshClone=", FRESH_CLONE)
println("decision: tiebreak=", TIEBREAK, " belief=", BELIEF, " beliefP0=", BELIEF_P0,
        " stayReturn=", STAY_RETURN)
println("signals: publicMode=", PUBLIC_MODE, " publicRefresh=", PUBLIC_REFRESH,
        " privateSignal=", PRIVATE_SIGNAL, " privateNoise=", PRIVATE_NOISE)
# Balance sheet and fundamental (2026-10-21; read through switchValue from SWITCHES).
println("balance: payoff=", SWITCHES.PAYOFF, " balance=", SWITCHES.BALANCE,
        " fireDiscount=", SWITCHES.FIRE_DISCOUNT, " equity=", SWITCHES.EQUITY,
        " fundamental=", SWITCHES.FUNDAMENTAL, " return=[", SWITCHES.RETURN_LO, ", ",
        SWITCHES.RETURN_HI, "] thetaNoise=", SWITCHES.THETA_NOISE)
println("theta public: mode=", SWITCHES.THETA_PUBLIC, " level=", SWITCHES.THETA_PUBLIC_LEVEL,
        " gap=", SWITCHES.THETA_PUBLIC_GAP, " rho=", SWITCHES.THETA_PUBLIC_RHO,
        " noise=", SWITCHES.THETA_PUBLIC_NOISE, " lambdaScope=", SWITCHES.LAMBDA_SCOPE)
println("withdraw: mode=", SWITCHES.WITHDRAW, " partialMinShare=", SWITCHES.PARTIAL_MIN_SHARE, " partialSteps=", SWITCHES.PARTIAL_STEPS)
println("risk: cara=", SWITCHES.CARA)
println("deposits: cap=", SWITCHES.DEPOSIT_CAP)
println("output: log=", LOG)

@everywhere include("objects.jl")

@everywhere include("warmup.jl")

@everywhere include("functions4.jl")

for c in 2:cores
    @spawnat c myCore(c)
end
sleep(5)

# Model outline:
# generate the agents, their network, their deposits and the bank;
# an exogenous number of agents withdraw;
# each agent observes the share of its neighbours that have withdrawn, takes it
# as a sample of the population, and estimates its probability of getting its
# full deposit back, randomising over which agents withdraw and its place in line.
# The structs are generated once, so the sweep uses process-based parallelism.

dataDir = CLI_ARGS[1]
@everywhere dataDir = $dataDir
# Parameter generation runs on the master. restart.jl (resuming from saved
# parameters) is not wired in; see scripts/run_all.sh on --restart.
if myid() == 1
    include("parameterGen.jl")
end

# Work queue for distributed sweep: each worker pulls a row, runs, and checks it off.
coreDict=Dict()
for j in 2:cores
    coreDict[j]=nothing
end
while sum(jointFrame.completed) < size(jointFrame,1)
        for c in keys(coreDict)
            if isnothing(coreDict[c])
                # idle worker: start a run on the next unstarted row
                coreDict[c]=@spawnat c modelCall()
            elseif isReady(coreDict[c])
                coreDict[c]=fetch(coreDict[c])
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
