# Run from the BankRuns5 repo root:
#     julia --project=. scripts/check_warmup_weight.jl [outdir]
#
# Does the warm-up's influence weight matter? (next_steps.md #10/#13, #32)
#
# warmup.jl's header documents  w = 2·sim − 1,  sim = 1 − mean|a−b|/2,
# i.e. w_h = 1 − mean_f |a_if − a_jf|, but influenceWeight() computes the
# normalised dot product w_d = dot(a, b)/F. Both feed the same tie rule
# (w > 0 ⇒ adopt, else resist; λ = resist/(adopt+resist)).
#
# For each (p, α) and 20 seeds this script runs the warm-up under both weights
# from the same seed and reports, averaged over seeds:
#   - agents whose type changes under the top-μ cut, μ ∈ {0.25, 0.5, 0.75};
#   - Spearman corr(λ_d, λ_h);
#   - the share of "moderate" agents (final mean |opinion| < 0.5) classed I at
#     μ = 0.5 under each weight, against their population share;
#   - Moran's I of λ at exact graph distance L = 1, 2, 3 (row-standardised:
#     each agent's lag-L neighbours weighted 1/n_i(L); also the binary
#     pair-sum version used by tests/check_type_clustering.py).
#
# warmup() does not return final opinions, so the loop is reimplemented here,
# parameterised by the weight function. The reimplementation under w_d is
# checked against warmup() itself, bit for bit, for every seed of every cell
# (it aborts if any λ differs). warmup.jl is not modified.

using Distributions, Graphs, LinearAlgebra, Random, StatsBase, Printf

const ROOT = abspath(joinpath(@__DIR__, ".."))
include(joinpath(ROOT, "warmup.jl"))

w_dot(a::Vector{Float64}, b::Vector{Float64}) = dot(a, b) / length(a)
w_header(a::Vector{Float64}, b::Vector{Float64}) = 1.0 - mean(abs.(a .- b))

# warmupInit + warmupRun! + computeLambda, with the weight as an argument.
# Same RNG calls in the same order as warmup.jl.
function warmup_with(wfun, agtCnt, network, seed; alpha)
    agents = warmupInit(agtCnt, network, seed)
    for _ in 1:WARMUP_MAX_TICKS
        total_change = 0.0
        for i in Random.shuffle(1:agtCnt)
            nbrs = all_neighbors(network, i)
            isempty(nbrs) && continue
            j = rand(nbrs)
            ai = agents[i]; aj = agents[j]
            w = wfun(ai.opinions, aj.opinions)
            delta = alpha .* w .* (aj.opinions .- ai.opinions)
            ai.opinions .+= delta
            clamp!(ai.opinions, -1.0, 1.0)
            if w > 0.0
                ai.adoptCount += 1
            else
                ai.resistCount += 1
            end
            total_change += sum(abs.(delta))
        end
        total_change / agtCnt < WARMUP_EPS && break
    end
    return computeLambda(agents), [mean(abs.(a.opinions)) for a in agents]
end

function typeI(lw, μ)
    isI = falses(length(lw))
    isI[sortperm(lw, rev=true)[1:round(Int, μ * length(lw))]] .= true
    return isI
end

# Neighbour lists at exact shortest-path distance L = 1..maxL (BFS per node).
function lag_lists(g, maxL)
    n = nv(g)
    out = [[Int[] for _ in 1:n] for _ in 1:maxL]
    for s in 1:n
        d = gdistances(g, s)
        for t in 1:n
            1 <= d[t] <= maxL && push!(out[d[t]][s], t)
        end
    end
    return out
end

function moran_rowstd(x, lists)
    z = x .- mean(x); den = sum(abs2, z); N = length(x)
    num = 0.0; W = 0
    for i in 1:N
        nb = lists[i]; isempty(nb) && continue
        num += z[i] * mean(z[nb]); W += 1
    end
    return (N / W) * num / den
end
function moran_binary(x, lists)
    z = x .- mean(x); den = sum(abs2, z); N = length(x)
    num = 0.0; W = 0
    for i in 1:N, j in lists[i]
        num += z[i] * z[j]; W += 1
    end
    return (N / W) * num / den
end

function main(outdir)
    mkpath(outdir)
    N, K, nseed = 1000, 6, 20
    μs = (0.25, 0.5, 0.75)
    rows = Vector{Dict{String,Any}}()
    t0 = time()
    for p in (0.05, 0.15), α in (0.1, 0.5), seed in 1:nseed
        Random.seed!(1000 + seed); g = newman_watts_strogatz(N, K, p)
        lists = lag_lists(g, 3)
        lw_ref = warmup(N, g, seed; alpha=α)
        lw_d, mo_d = warmup_with(w_dot, N, g, seed; alpha=α)
        lw_d == lw_ref || error("reimplementation differs from warmup() at p=$p α=$α seed=$seed")
        lw_h, mo_h = warmup_with(w_header, N, g, seed; alpha=α)
        r = Dict{String,Any}("p" => p, "alpha" => α, "seed" => seed)
        for μ in μs
            r["switch_mu$(μ)"] = count(typeI(lw_d, μ) .!= typeI(lw_h, μ))
        end
        r["spearman"] = corspearman(lw_d, lw_h)
        r["sd_lw_d"] = std(lw_d); r["sd_lw_h"] = std(lw_h)
        r["nuniq_lw_d"] = length(unique(lw_d)); r["nuniq_lw_h"] = length(unique(lw_h))
        # ties: sortperm is stable, so tied λ at the cut are split by agent index
        r["frac_zero_lw_d"] = mean(lw_d .== 0); r["frac_zero_lw_h"] = mean(lw_h .== 0)
        Id, Ih = typeI(lw_d, 0.5), typeI(lw_h, 0.5)
        for (tag, mo, I) in (("d", mo_d, Id), ("h", mo_h, Ih))
            m = mo .< 0.5
            r["mod_share_$tag"] = mean(m)                         # population share of moderates
            r["mod_in_I_$tag"] = count(m .& I) / count(I)         # share of type I who are moderate
            r["P_I_given_mod_$tag"] = count(m) == 0 ? NaN : count(m .& I) / count(m)
        end
        for L in 1:3
            r["moranR_d_L$L"] = moran_rowstd(lw_d, lists[L]); r["moranR_h_L$L"] = moran_rowstd(lw_h, lists[L])
            r["moranB_d_L$L"] = moran_binary(lw_d, lists[L]); r["moranB_h_L$L"] = moran_binary(lw_h, lists[L])
        end
        push!(rows, r)
    end
    elapsed = time() - t0
    cols = sort(collect(keys(rows[1])); by=c -> (c in ("p", "alpha", "seed") ? findfirst(==(c), ["p", "alpha", "seed"]) : 9, c))
    open(joinpath(outdir, "warmup_weight_by_seed.csv"), "w") do io
        println(io, join(cols, ","))
        for r in rows
            println(io, join([string(r[c]) for c in cols], ","))
        end
    end
    # summary: mean over seeds per (p, α)
    num = filter(c -> !(c in ("p", "alpha", "seed")), cols)
    cells = unique([(r["p"], r["alpha"]) for r in rows])
    open(joinpath(outdir, "warmup_weight_summary.csv"), "w") do io
        println(io, join(["p", "alpha", "nseeds", num...], ","))
        for (p, α) in cells
            rs = filter(r -> r["p"] == p && r["alpha"] == α, rows)
            println(io, join([string(p), string(α), string(length(rs)),
                              [string(mean(filter(!isnan, [Float64(r[c]) for r in rs]))) for c in num]...], ","))
        end
    end
    println("Warm-up weight check: w_d = dot/F (code) vs w_h = 1 - mean|a-b| (header); N=$N, k=$K, $nseed seeds/cell")
    println("reimplementation reproduces warmup() lambda exactly for all $(length(rows)) (p,alpha,seed) runs")
    @printf("%-5s %-4s | %6s %6s %6s | %6s | %5s %6s %6s %6s %6s | %-20s | %-20s\n",
            "p", "a", "sw.25", "sw.5", "sw.75", "rho_s", "mod_d", "P(I|m)d", "mod_h", "P(I|m)h", "", "MoranR_d L1/L2/L3", "MoranR_h L1/L2/L3")
    for (p, α) in cells
        rs = filter(r -> r["p"] == p && r["alpha"] == α, rows)
        M(c) = mean(filter(!isnan, [Float64(r[c]) for r in rs]))
        @printf("%-5.2f %-4.1f | %6.1f %6.1f %6.1f | %6.3f | %5.3f %6.3f  %6.3f %6.3f        | %+.3f/%+.3f/%+.3f | %+.3f/%+.3f/%+.3f\n",
                p, α, M("switch_mu0.25"), M("switch_mu0.5"), M("switch_mu0.75"), M("spearman"),
                M("mod_share_d"), M("P_I_given_mod_d"), M("mod_share_h"), M("P_I_given_mod_h"),
                M("moranR_d_L1"), M("moranR_d_L2"), M("moranR_d_L3"),
                M("moranR_h_L1"), M("moranR_h_L2"), M("moranR_h_L3"))
    end
    for (p, α) in cells
        rs = filter(r -> r["p"] == p && r["alpha"] == α, rows)
        M(c) = mean([Float64(r[c]) for r in rs])
        @printf("p=%.2f a=%.1f: distinct lambda d/h = %.0f/%.0f; share lambda==0 d/h = %.3f/%.3f; sd d/h = %.3f/%.3f\n",
                p, α, M("nuniq_lw_d"), M("nuniq_lw_h"), M("frac_zero_lw_d"), M("frac_zero_lw_h"), M("sd_lw_d"), M("sd_lw_h"))
    end
    println("sw.mu = agents whose type differs between weights (of $N); mod = population share with final mean|opinion|<0.5;")
    println("P(I|m) = share of moderates classed I at mu=0.5 (compare with 0.5 = baseline P(I)).")
    @printf("elapsed: %.1f s\nCSV: %s\n", elapsed, outdir)
end

main(length(ARGS) >= 1 ? ARGS[1] :
     "/tmp/claude-1000/-home-simal-papers-bank-run-dissertation/41e56539-941d-4b0f-a64a-fe9652438826/scratchpad/abm_part1")
