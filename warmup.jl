################################################################################
#  Warm-up Phase: Flache & Macy (2011) Social Influence Model with Negative
#  Influence — Modified to Track Individualism (λ) Emergence.
#
#  Agents hold opinions on F cultural dimensions ∈ [-1, 1] and interact
#  repeatedly on the Watts-Strogatz network.  The influence weight
#
#      w_ij = 2 × similarity(i,j) − 1  ∈ [-1, 1]
#
#  where similarity = 1 − mean(|a_i − a_j|) / 2, is POSITIVE for culturally
#  similar dyads (agents converge) and NEGATIVE for dissimilar dyads (agents
#  diverge — cultural repulsion).  This produces polarisation into stable
#  cultural clusters rather than full consensus.
#
#  At each interaction the opinion update always executes:
#      Δa_if = α × w_ij × (a_jf − a_if),   clamped to [-1, 1].
#  The sign of w_ij is recorded for the individualism tally:
#      w_ij > 0  →  adoptCount  (culturally aligned, converging signal)
#      w_ij ≤ 0  →  resistCount (culturally opposed, diverging signal)
#
#  After convergence (opinions fixed at ±1 extremes, Δ → 0):
#      λ_i = resistCount_i / (adoptCount_i + resistCount_i)
#
#  Agents who consistently faced dissimilar neighbours (cultural bridge
#  positions) accumulate high resistCount → high λ (individualists).
#  Agents embedded in homogeneous clusters accumulate high adoptCount
#  → low λ (collectivists).
#
#  The learning-rate parameter α (warmupAlpha in the sweep) controls how
#  quickly cultural polarisation occurs; different α values yield different
#  convergence paths and thus different cluster assignments and λ distributions,
#  making α a meaningful sweep parameter.
#
#  Reference: Flache & Macy (2011) "Small Worlds and Cultural Polarization"
#             Journal of Mathematical Sociology 35:146-176.
################################################################################

# Fixed warm-up hyperparameters (not swept; part of model architecture).
const WARMUP_FEATURES = 5      # number of cultural opinion dimensions
const WARMUP_MAX_TICKS = 500   # hard cap on warm-up steps
const WARMUP_EPS = 1e-6        # convergence: mean |Δopinion| per agent per tick

mutable struct CulturalAgent
    idx::Int64
    opinions::Vector{Float64}   # F cultural traits ∈ [-1, 1]
    adoptCount::Int64           # interactions with w_ij > 0 (culturally aligned)
    resistCount::Int64          # interactions with w_ij ≤ 0 (culturally opposed)
end

"""
Influence weight w_ij ∈ [-1, 1] via normalised dot product:
    w_ij = (1/F) × Σ_f (a_if × a_jf)

Inspired by Flache & Macy (2011) §4.2 extended model.  With continuous
opinions a_if ∈ [-1, 1], the dot product is the natural generalisation of
their binary-opinion correlation.  For randomly initialised opinions,
E[w_ij] = 0 (mean zero, independent draws), so roughly half of all initial
dyads have positive influence and half have negative.

w_ij > 0: opinion profiles correlated → agent converges toward neighbour.
w_ij ≤ 0: opinion profiles anti-correlated → agent diverges from neighbour.
"""
function influenceWeight(a::CulturalAgent, b::CulturalAgent)
    F = length(a.opinions)
    return dot(a.opinions, b.opinions) / F
end

"""
Initialise cultural agents with opinions drawn uniformly from [-1, 1].
The network must have the same size as agtCnt; this is asserted here.
"""
function warmupInit(agtCnt::Int64, network::SimpleGraph{Int64}, seed::Int64)
    @assert nv(network) == agtCnt "warmup: network size ($(nv(network))) must equal agtCnt ($agtCnt)"
    Random.seed!(seed)
    return [CulturalAgent(i, rand(Uniform(-1.0, 1.0), WARMUP_FEATURES), 0, 0)
            for i in 1:agtCnt]
end

"""
Run Flache-Macy social influence dynamics (with negative influence) until
convergence or WARMUP_MAX_TICKS.

Each tick:
  - Agents are visited in a random order.
  - Each agent i selects one random neighbour j.
  - Influence weight w_ij is computed.
  - Opinion update always executes: Δa = α × w_ij × (a_j − a_i), clamped.
    • w_ij > 0: agent moves TOWARD j (convergence) → adoptCount++.
    • w_ij ≤ 0: agent moves AWAY from j (repulsion) → resistCount++.

Convergence: mean |Δopinion| across all agents drops below WARMUP_EPS,
which occurs when all opinions have reached ±1 extremes (full polarisation).
"""
function warmupRun!(agents::Vector{CulturalAgent},
                    network::SimpleGraph{Int64};
                    alpha::Float64=0.3)
    agtCnt = length(agents)
    for _ in 1:WARMUP_MAX_TICKS
        total_change = 0.0
        for i in Random.shuffle(1:agtCnt)
            nbrs = all_neighbors(network, i)
            isempty(nbrs) && continue
            j = rand(nbrs)
            ai = agents[i]
            aj = agents[j]
            w = influenceWeight(ai, aj)
            # Opinion update (both convergent and repulsive cases)
            delta = alpha .* w .* (aj.opinions .- ai.opinions)
            ai.opinions .+= delta
            clamp!(ai.opinions, -1.0, 1.0)
            # Tally for λ computation
            if w > 0.0
                ai.adoptCount += 1
            else
                ai.resistCount += 1
            end
            total_change += sum(abs.(delta))
        end
        # Convergence: all opinions at ±1 extremes → no further change possible
        if total_change / agtCnt < WARMUP_EPS
            break
        end
    end
end

"""
Compute λ_i = resistCount_i / (adoptCount_i + resistCount_i) for each agent.
Returns a Vector{Float64} with λ ∈ [0, 1].
Agents with no interactions (isolated nodes) receive λ = 0.5 (neutral).
"""
function computeLambda(agents::Vector{CulturalAgent})
    return [let total = a.adoptCount + a.resistCount
                total == 0 ? 0.5 : Float64(a.resistCount) / Float64(total)
            end for a in agents]
end

"""
Full warm-up pipeline: initialise, run Flache-Macy polarisation dynamics,
return per-agent λ values.
Uses seed for reproducible cultural initialisation.
"""
function warmup(agtCnt::Int64, network::SimpleGraph{Int64}, seed::Int64;
                alpha::Float64=0.3)
    agents = warmupInit(agtCnt, network, seed)
    warmupRun!(agents, network; alpha=alpha)
    return computeLambda(agents)
end
