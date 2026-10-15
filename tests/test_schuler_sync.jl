# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_schuler_sync.jl
#
# The schuler-sync switches (2026-10-15): BANKRUN_TIEBREAK and BANKRUN_BELIEF.
#   A. decide(): the three tie-break rules on the full (P_WD, P_stay) grid.
#   B. beliefDraws(): geometric is the published draw; point is Binomial(N-1, p0).
#   C. Non-default arms run, log bankRunDecisionParams, and stay in range; the
#      default arm writes no such file. Directions are printed, not asserted.
#   D. ENV parsing rejects bad values.
# That the defaults reproduce the earlier model is tests/test_switch_identity.jl.

using Test
using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase

const ROOT = abspath(joinpath(@__DIR__, ".."))

function load_model(name; depth=30)
    m = Module(name)
    Core.eval(m, :(using CSV, DataFrames, Distributions, Distributed, Graphs, Random, StatsBase))
    for f in ("settings.jl", "objects.jl", "functions4.jl")
        Base.include(m, joinpath(ROOT, f))
    end
    dir = mktempdir()
    Core.eval(m, :(dataDir = $dir; workerCore = 1; depth = $depth))
    return m
end

function build(m, seed; n=60, reserve=0.15)
    Random.seed!(10_000 + seed)
    deposits = rand(LogNormal(1.0, 1.0), n)
    λs = [i <= n ÷ 3 ? 0.2 : 0.8 for i in 1:n]
    agents = [m.Agent(i, deposits[i], true, λs[i]) for i in 1:n]
    bank = m.Bank(reserve * sum(deposits), copy(agents), m.Agent[])
    net = newman_watts_strogatz(n, 4, 0.1; seed=seed)
    return m.Model("k$seed", agents, reserve, bank, 0.1, seed, seed, LogNormal(1.0, 1.0), net, 0.1,
                   truncated(Geometric(0.2), 0, n))
end

m0 = load_model(:S0)

# ---------------------------------------------------------------- A
@testset "A. decide() tie-break rules" begin
    # (P_WD, P_stay) => (legacy, schuler, strict)
    cases = [(1.0, 0.0) => (true,  true,  true),
             (1.0, 0.5) => (true,  true,  true),
             (1.0, 1.0) => (false, false, false),
             (0.0, 0.0) => (true,  false, false),   # vault can't cover now: legacy salvages
             (0.0, 0.5) => (true,  false, false),
             (0.0, 1.0) => (true,  false, false),
             (0.7, 0.4) => (true,  true,  true),    # interior P_WD: not reachable today, rules still defined
             (0.4, 0.4) => (false, false, false)]
    for ((pw, ps), (l, s, st)) in cases
        @test m0.decide(pw, ps; tiebreak="legacy")  == l
        @test m0.decide(pw, ps; tiebreak="schuler") == s
        @test m0.decide(pw, ps; tiebreak="strict")  == st
    end
    @test m0.decide(1.0, 0.0) == m0.decide(1.0, 0.0; tiebreak="legacy")   # default = legacy
    # P_WD ∈ {0,1}, so schuler and strict coincide on every reachable input
    for pw in (0.0, 1.0), ps in 0:0.1:1
        @test m0.decide(pw, ps; tiebreak="schuler") == m0.decide(pw, ps; tiebreak="strict")
    end
    @test_throws ErrorException m0.decide(1.0, 0.0; tiebreak="nope")
end

# ---------------------------------------------------------------- B
@testset "B. beliefDraws()" begin
    mod = build(m0, 1; n=200)
    Random.seed!(7); g1 = m0.beliefDraws(mod, 500)
    Random.seed!(7); g2 = rand(mod.exogProb, 500)
    @test g1 == g2                                      # default = the published draw
    Random.seed!(7); p = m0.beliefDraws(mod, 20_000; belief="point", p0=0.05)
    @test all(0 .<= p .<= 199)
    @test abs(mean(p) - 199 * 0.05) < 0.2                # Binomial(N-1, p0) mean
    @test_throws ErrorException m0.beliefDraws(mod, 5; belief="nope")
end

# ---------------------------------------------------------------- C
@testset "C. non-default arms" begin
    seeds = 1:30
    function arm(; kw...)
        m = load_model(gensym(:C))
        for (k, v) in kw; Core.eval(m, :($k = $v)); end
        res = [Base.invokelatest(() -> m.modelRun(build(m, s))) for s in seeds]
        f = joinpath(m.dataDir, "bankRunDecisionParams1.csv")
        log = isfile(f) ? CSV.read(f, DataFrame; header=[:key, :tiebreak, :belief, :beliefP0]) : nothing
        return res, log
    end
    fixed = (FIX_DOUBLE_COUNT=true, FRESH_CLONE=true)
    arms = [("default", (;)),
            ("bug fixes", fixed),
            ("bug fixes + schuler tie-break", (; fixed..., TIEBREAK="schuler")),
            ("bug fixes + strict tie-break", (; fixed..., TIEBREAK="strict")),
            ("bug fixes + schuler + point belief", (; fixed..., TIEBREAK="schuler", BELIEF="point")),
            ("point belief only", (BELIEF="point",))]
    out = Dict{String,Any}()
    for (lab, kw) in arms
        res, log = arm(; kw...)
        out[lab] = res
        @test all(0 <= r[2] <= 60 for r in res)
        nondefault = haskey(kw, :TIEBREAK) || haskey(kw, :BELIEF)
        @test (log === nothing) == !nondefault
        if nondefault
            @test nrow(log) == length(seeds)
            @test all(log.tiebreak .== get(kw, :TIEBREAK, "legacy"))
            @test all(log.belief .== get(kw, :BELIEF, "geometric"))
        end
    end
    @test out["bug fixes + schuler tie-break"] == out["bug fixes + strict tie-break"]   # same decisions (A)
    println("\nDiagnostics over $(length(seeds)) seeds (not asserted):")
    for (lab, _) in arms
        res = out[lab]
        println(rpad(lab, 36), " P(run)=", round(mean(r[1] for r in res), digits=2),
                "  mean |S*|=", round(mean(r[2] for r in res), digits=2))
    end
end

# ---------------------------------------------------------------- D
@testset "D. ENV parsing" begin
    withenv("BANKRUN_TIEBREAK" => "Schuler") do
        @test m0.envChoice("BANKRUN_TIEBREAK", "legacy", m0.TIEBREAK_CHOICES) == "schuler"
    end
    withenv("BANKRUN_TIEBREAK" => "") do
        @test m0.envChoice("BANKRUN_TIEBREAK", "legacy", m0.TIEBREAK_CHOICES) == "legacy"
    end
    withenv("BANKRUN_BELIEF" => "beta") do
        @test_throws ErrorException m0.envChoice("BANKRUN_BELIEF", "geometric", m0.BELIEF_CHOICES)
    end
    withenv("BANKRUN_BELIEF_P0" => "0") do
        @test_throws ErrorException m0.envFloat("BANKRUN_BELIEF_P0", 0.02, 0.0, 1.0; loOpen=true)
    end
end
