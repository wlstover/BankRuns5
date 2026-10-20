# STATUS 2026-10-20: diagnostic, NOT in tests/run_tests.sh. It exits non-zero:
# the legacy @tests fail at depth 30 on Monte Carlo noise (stale clone: all 24
# flips vanish at depth 4000) and on 8 genuine fresh-clone violations at depth
# 4000 (more withdrawals of small deposits make staying look safer, since the
# belief is a head count). Redesign (assert at high depth, stale clone only)
# before adding it to the suite.
#
# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_order_preservation.jl
#
# Order preservation of the per-agent decision (REPOSITORY_REVIEW.md §9.7,
# "Theorem 3", Step 1): for nested withdrawal sets S ⊆ S′, every agent still
# banked under S′ who withdraws under S also withdraws under S′.
#
# The decision is evaluated exactly as modelRun does it (functions4.jl, the
# per-agent loop): neighbourSignal → beliefDraws → anticipatedWithdrawals
# (alreadyOut = length(withdrawHistory) under the fresh clone, the number of
# withdrawn neighbours under the stale clone) → simulateStay on the decision
# state (SubState of the current model under the fresh clone; the post-shock
# snapshot under the stale clone) → payoffIfWithdrawNow → decide. Public signal
# off (α = 0, φ = 1, t = 1), geometric prior, depth = 30. Common random numbers:
# the agent's RNG is reseeded with the same seed before its draws under S and
# under S′ (the prior draws then coincide; the sub-simulation shuffles are seeded
# alike but run over banking lists of different lengths).
#
# Arms: tiebreak ∈ {legacy, schuler, strict} × {stale (skipWithdrawn false and
# true), fresh (skipWithdrawn true, as modelRun forces)}. @test only for legacy;
# schuler/strict violation counts are reported with @info.
#
# Part B (findings only): a simultaneous-moves best-response map. All banked
# agents decide on the same tick-start state; the tick's withdrawers are then
# served in a random queue (withdraw()). Checks T(S) ⊆ T(S′) for S ⊆ S′, iterates
# T to its fixed point from S and from S′, and records whether the tick's
# withdrawals exceeded the vault and how many withdrawers were paid short.

using Test
using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase, Printf

const ROOT = abspath(joinpath(@__DIR__, ".."))
for f in ("settings.jl", "objects.jl", "functions4.jl")
    include(joinpath(ROOT, f))
end
dataDir = mktempdir(); workerCore = 1
const DEPTH = 30
const TIEBREAKS = ("legacy", "schuler", "strict")
const CLONES = ((name="stale/skip=false", fresh=false, skip=false),
                (name="stale/skip=true",  fresh=false, skip=true),
                (name="fresh/skip=true",  fresh=true,  skip=true))

function build(seed; n, reserve, ins)
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, 1.0), n)
    λs = [rand() < 0.4 ? clamp(0.2 + 0.1randn(), 0, 1) : clamp(0.7 + 0.1randn(), 0, 1) for _ in 1:n]
    agents = [Agent(i, deposits[i], true, λs[i]) for i in 1:n]
    bank = Bank(reserve * sum(deposits), copy(agents), Agent[])
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return Model("k$seed", agents, reserve, bank, ins, seed, seed, LogNormal(1.0, 1.0), net, 0.1,
                 truncated(Geometric(0.2), 0, n))
end

"""A copy of `base` with the agents in `set` withdrawn, in the given order, via withdraw()."""
function withdrawn_copy(base::Model, set::Vector{Int})
    m = deepcopy(base)
    for i in set
        withdraw(m, m.agtList[i])
    end
    return m
end

"""(P_WD, P_stay, alreadyOut) for agent i of `mod`, as modelRun computes them."""
function evaluate(mod::Model, stale::SubState, i::Int, seed; fresh, skip, depth=DEPTH)
    agt = mod.agtList[i]
    nAgents = length(mod.agtList)
    Random.seed!(seed)
    withdrawnNeighbors, neighbourEstimate = neighbourSignal(mod, agt)
    priorDraws = beliefDraws(mod, depth)
    alreadyOut = fresh ? length(mod.theBank.withdrawHistory) : length(withdrawnNeighbors)
    additional = anticipatedWithdrawals(agt, priorDraws, neighbourEstimate, 0, alreadyOut, nAgents, 1;
                                        pubAlpha=0.0, weightPhi=1.0)
    decisionState = fresh ? SubState(mod) : stale
    pStay = simulateStay(decisionState, agt, withdrawnNeighbors, additional; skipWithdrawn=skip)
    pWD = payoffIfWithdrawNow(decisionState, agt)
    return (pWD=pWD, pStay=pStay, alreadyOut=alreadyOut, nHistory=decisionState.nHistory)
end

const CONFIGS = [(n=n, reserve=r, ins=ins) for n in (30, 60), r in (0.05, 0.1, 0.2, 0.35), ins in (0.0, 0.1)]
const SEEDS = 1:5
const PAIRS = 12

# Nested S0 ⊆ S ⊆ S′: S0 is the "exogenous shock" (the stale snapshot), S adds
# a random block, S′ a further block. Sizes vary so that S′ often drains the vault.
function nested_sets(rng, n)
    perm = randperm(rng, n)
    a = rand(rng, 1:max(1, n ÷ 10))
    b = a + rand(rng, 0:n ÷ 3)
    c = b + rand(rng, 1:n ÷ 2)
    c = min(c, n - 2)
    return perm[1:a], perm[1:b], perm[1:c]
end

viol = Dict((tb, cl.name) => 0 for tb in TIEBREAKS, cl in CLONES)
viol_vault = Dict((tb, cl.name) => 0 for tb in TIEBREAKS, cl in CLONES)   # with P_WD(S′) = 0
comparisons = Dict(cl.name => 0 for cl in CLONES)
legacy_examples = Any[]
schuler_examples = Any[]

alreadyOut_ok = Ref(true)
t0 = time()
redirect_stdout(devnull) do      # neighbourSignal prints a line whenever its clamp binds
    rng = MersenneTwister(31)
    for (ci, cfg) in enumerate(CONFIGS), seed in SEEDS
        base = build(seed; cfg...)
        for pair in 1:PAIRS
            S0, S, Sp = nested_sets(rng, cfg.n)
            m0 = withdrawn_copy(base, S0)
            stale = SubState(m0)
            mS = withdrawn_copy(base, S)
            mSp = withdrawn_copy(base, Sp)       # S′ withdrawn in the order S, then S′ \ S
            for i in 1:cfg.n
                mSp.agtList[i].banked || continue
                crn = hash((ci, seed, pair, i))
                for cl in CLONES
                    a = evaluate(mS, stale, i, crn; fresh=cl.fresh, skip=cl.skip)
                    b = evaluate(mSp, stale, i, crn; fresh=cl.fresh, skip=cl.skip)
                    if cl.fresh
                        alreadyOut_ok[] &= a.alreadyOut == length(mS.theBank.withdrawHistory) == a.nHistory
                        alreadyOut_ok[] &= b.alreadyOut == length(mSp.theBank.withdrawHistory) == b.nHistory
                    end
                    comparisons[cl.name] += 1
                    for tb in TIEBREAKS
                        dS = decide(a.pWD, a.pStay; tiebreak=tb)
                        dSp = decide(b.pWD, b.pStay; tiebreak=tb)
                        v = dS && !dSp
                        if v
                            viol[(tb, cl.name)] += 1
                            b.pWD == 0.0 && (viol_vault[(tb, cl.name)] += 1)
                            ex = (cfg=cfg, seed=seed, pair=pair, agent=i, deposit=base.agtList[i].deposit,
                                  λ=base.agtList[i].individualism, clone=cl.name, S0=sort(S0), S=sort(S), Sp=sort(Sp),
                                  vaultS=mS.theBank.vault, vaultSp=mSp.theBank.vault,
                                  pWD_S=a.pWD, pStay_S=a.pStay, pWD_Sp=b.pWD, pStay_Sp=b.pStay, crn=crn)
                            tb == "legacy" && push!(legacy_examples, ex)
                            tb == "schuler" && length(schuler_examples) < 3 && push!(schuler_examples, ex)
                        end
                    end
                end
            end
        end
    end
end
tA = time() - t0

println("\n=== Part A: sequential decision, nested S ⊆ S′ (depth $DEPTH, CRN) ===")
@printf("%-18s %10s | %-28s | %-28s | %-28s\n", "clone", "compares", "legacy viol (P_WD′=0)", "schuler viol (P_WD′=0)", "strict viol (P_WD′=0)")
for cl in CLONES
    @printf("%-18s %10d | %-28s | %-28s | %-28s\n", cl.name, comparisons[cl.name],
            [string(viol[(tb, cl.name)], " (", viol_vault[(tb, cl.name)], ")") for tb in TIEBREAKS]...)
end
for tb in ("schuler", "strict"), cl in CLONES
    @info "finding: $tb / $(cl.name)" violations=viol[(tb, cl.name)] with_PWD_Sprime_zero=viol_vault[(tb, cl.name)] comparisons=comparisons[cl.name]
end
if !isempty(legacy_examples)
    println("\nLEGACY COUNTEREXAMPLES: $(length(legacy_examples)) (first 3 shown; P_stay re-estimated at depth 4000 with the same seed)")
    for cl in CLONES
        exs = filter(e -> e.clone == cl.name, legacy_examples)
        isempty(exs) && continue
        println("  ", cl.name, ": ", length(exs), " violations; P_WD(S′)=0 in ", count(e -> e.pWD_Sp == 0, exs),
                "; P_stay(S′)==1 in ", count(e -> e.pStay_Sp == 1, exs))
    end
    for ex in vcat([filter(e -> e.clone == cl.name, legacy_examples)[1:min(2, end)] for cl in CLONES]...)
        println(ex)
        base = build(ex.seed; ex.cfg...)
        cl = only(filter(c -> c.name == ex.clone, CLONES))
        st = SubState(withdrawn_copy(base, ex.S0))
        mS = withdrawn_copy(base, ex.S); mSp = withdrawn_copy(base, ex.Sp)
        a, b = redirect_stdout(devnull) do
            (evaluate(mS, st, ex.agent, ex.crn; fresh=cl.fresh, skip=cl.skip, depth=4000),
             evaluate(mSp, st, ex.agent, ex.crn; fresh=cl.fresh, skip=cl.skip, depth=4000))
        end
        @printf("  depth 4000: P_stay(S)=%.4f  P_stay(S′)=%.4f  P_WD(S)=%.0f  P_WD(S′)=%.0f\n", a.pStay, b.pStay, a.pWD, b.pWD)
    end
    # Every legacy counterexample re-estimated at depth 4000 (same seed): does the
    # decision still flip, and does P_stay itself rise from S to S′?
    println("\n  all legacy counterexamples at depth 4000:")
    for cl in CLONES
        exs = filter(e -> e.clone == cl.name, legacy_examples)
        isempty(exs) && continue
        still, rises = 0, 0
        for ex in exs
            base = build(ex.seed; ex.cfg...)
            st = SubState(withdrawn_copy(base, ex.S0))
            mS = withdrawn_copy(base, ex.S); mSp = withdrawn_copy(base, ex.Sp)
            a, b = redirect_stdout(devnull) do
                (evaluate(mS, st, ex.agent, ex.crn; fresh=cl.fresh, skip=cl.skip, depth=4000),
                 evaluate(mSp, st, ex.agent, ex.crn; fresh=cl.fresh, skip=cl.skip, depth=4000))
            end
            flip = decide(a.pWD, a.pStay) && !decide(b.pWD, b.pStay)
            flip && still == 0 && @printf("    first depth-4000 flip: n=%d r=%.2f ins=%.1f seed=%d pair=%d agent=%d deposit=%.4f λ=%.3f S=%s S′=%s vault S=%.3f S′=%.3f  P_WD %g/%g  P_stay %.4f/%.4f\n",
                ex.cfg.n, ex.cfg.reserve, ex.cfg.ins, ex.seed, ex.pair, ex.agent, ex.deposit, ex.λ, ex.S, ex.Sp,
                ex.vaultS, ex.vaultSp, a.pWD, b.pWD, a.pStay, b.pStay)
            still += flip
            rises += b.pStay > a.pStay
        end
        println("    ", cl.name, ": ", length(exs), " cases; decision still flips in ", still,
                "; P_stay(S′) > P_stay(S) in ", rises)
    end
end
if !isempty(schuler_examples)
    println("\nschuler examples (first $(length(schuler_examples))):")
    for ex in schuler_examples
        @printf("  n=%d r=%.2f ins=%.1f seed=%d pair=%d agent=%d deposit=%.3f clone=%s vault S=%.3f S′=%.3f  P_WD %g→%g  P_stay %.3f→%.3f\n",
                ex.cfg.n, ex.cfg.reserve, ex.cfg.ins, ex.seed, ex.pair, ex.agent, ex.deposit, ex.clone,
                ex.vaultS, ex.vaultSp, ex.pWD_S, ex.pWD_Sp, ex.pStay_S, ex.pStay_Sp)
    end
end

# ---------------------------------------------------------------- Part B
# Simultaneous moves. D(S) = banked agents who withdraw when all decide on the
# tick-start state of S; T(S) = S ∪ D(S). Each agent's seed depends on the agent
# and the model only, so D is a deterministic function of the state.

function tick(mod::Model, stale::SubState, seeds, qrng; fresh, skip, tiebreak)
    D = Int[]
    for agt in mod.theBank.bankingList
        e = evaluate(mod, stale, agt.idx, seeds[agt.idx]; fresh=fresh, skip=skip)
        decide(e.pWD, e.pStay; tiebreak=tiebreak) && push!(D, agt.idx)
    end
    vault0 = mod.theBank.vault
    excess = !isempty(D) && sum(mod.agtList[i].deposit for i in D) > vault0
    short = 0
    for i in shuffle(qrng, D)                       # served in a random queue
        paid = withdraw(mod, mod.agtList[i])
        paid < mod.agtList[i].deposit && (short += 1)
    end
    return D, excess, short
end

function fixed_point(base::Model, start::Vector{Int}, stale, seeds, qrng; kw...)
    m = withdrawn_copy(base, start)
    for _ in 1:length(base.agtList)
        D, _, _ = tick(m, stale, seeds, qrng; kw...)
        isempty(D) && break
        m.theBank.vault <= 0.0 && break             # modelRun stops on a drained vault too
    end
    return Set(a.idx for a in m.theBank.withdrawHistory)
end

t0 = time()
B = Dict{Tuple{String,String},Vector{Int}}()     # [compares, viol, viol_with_excess, ticks_excess, short_paid, fp_compares, fp_viol, queue_state_diff]
rng = MersenneTwister(77)
redirect_stdout(devnull) do
for (ci, cfg) in enumerate(CONFIGS), seed in SEEDS[1:3]
    base = build(seed; cfg...)
    seeds = [hash((ci, seed, i, :sim)) for i in 1:cfg.n]
    for pair in 1:6
        S0, S, Sp = nested_sets(rng, cfg.n)
        stale = SubState(withdrawn_copy(base, S0))
        for cl in CLONES, tb in TIEBREAKS
            acc = get!(B, (tb, cl.name), zeros(Int, 8))
            mS = withdrawn_copy(base, S); mSp = withdrawn_copy(base, Sp)
            DS, exS, shS = tick(mS, stale, seeds, MersenneTwister(1); fresh=cl.fresh, skip=cl.skip, tiebreak=tb)
            DSp, exSp, shSp = tick(mSp, stale, seeds, MersenneTwister(1); fresh=cl.fresh, skip=cl.skip, tiebreak=tb)
            TS = union(Set(S), DS); TSp = union(Set(Sp), DSp)
            nv_ = length(setdiff(TS, TSp))
            acc[1] += 1; acc[2] += nv_ > 0; acc[3] += (nv_ > 0) && (exS || exSp)
            acc[4] += exS + exSp; acc[5] += shS + shSp
            # queue order: does the post-tick state depend on it?
            mQ = withdrawn_copy(base, S)
            tick(mQ, stale, seeds, MersenneTwister(2); fresh=cl.fresh, skip=cl.skip, tiebreak=tb)
            sa, sb = SubState(mS), SubState(mQ)
            acc[8] += !(sa.vault ≈ sb.vault && sa.banked == sb.banked && sa.histMax == sb.histMax)
            fS = fixed_point(base, S, stale, seeds, MersenneTwister(3); fresh=cl.fresh, skip=cl.skip, tiebreak=tb)
            fSp = fixed_point(base, Sp, stale, seeds, MersenneTwister(3); fresh=cl.fresh, skip=cl.skip, tiebreak=tb)
            acc[6] += 1; acc[7] += !issubset(fS, fSp)
        end
    end
end
end
tB = time() - t0
println("\n=== Part B: simultaneous moves (decisions on the tick-start state, random service queue) ===")
@printf("%-8s %-18s %6s %8s %12s %12s %10s %8s %10s\n", "tiebreak", "clone", "pairs", "T-viol", "viol&excess", "excessTicks", "paidShort", "FP-viol", "queueDiff")
for cl in CLONES, tb in TIEBREAKS
    a = B[(tb, cl.name)]
    @printf("%-8s %-18s %6d %8d %12d %12d %10d %8d %10d\n", tb, cl.name, a[1], a[2], a[3], a[4], a[5], a[7], a[8])
end
println("T-viol: pairs with T(S) ⊄ T(S′); viol&excess: of those, a tick (under S or S′) whose withdrawals exceeded the vault;")
println("excessTicks: such ticks (2 per pair); paidShort: withdrawers paid < deposit; FP-viol: fixed point from S ⊄ fixed point from S′;")
println("queueDiff: pairs where a second queue order changed the post-tick state (vault, banked set, histMax).")
@printf("\nruntime: part A %.1f s, part B %.1f s\n", tA, tB)

@testset "order preservation (legacy tie-break; fresh-clone alreadyOut)" begin
    @test alreadyOut_ok[]          # fresh clone: alreadyOut == length(withdrawHistory) == SubState.nHistory
    for cl in CLONES
        @test viol[("legacy", cl.name)] == 0
    end
end
