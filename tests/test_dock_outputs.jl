# Run from the BankRuns5 repo root:
#     julia --project=. tests/test_dock_outputs.jl
#
# The docking outputs (2026-10-20): dockRow / timingRows / wealthRows in
# functions4.jl, written by runRow as bankRunDock / bankRunTiming / bankRunWealth.
#   A. Recording leaves the run unchanged (same results with and without a RunRecord).
#   B. bankRunDock: reserve share and slack identities; public error is NaN with
#      no announcement, 0 when the announcement tracks the truth every tick, and
#      <= 0 for a stale level (it lags the run; 0 at tick 1, its refresh).
#   C. bankRunTiming / bankRunWealth add up to typeSummary's counts.
# That replay reproduces these files is tests/test_replay.jl.

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
                   truncated(Geometric(0.2), 0, n)), λs .< 0.5
end

# One recorded run: (model after the run, isI, record, vault before the shock, result)
function recorded(m, seed; reserve=0.15)
    mod, isI = build(m, seed; reserve=reserve)
    v0 = mod.theBank.vault
    rec = m.RunRecord()
    res = Base.invokelatest(() -> m.modelRun(mod; record=rec))
    return mod, isI, rec, v0, res
end

seeds = 1:20

# ---------------------------------------------------------------- A
@testset "A. recording does not change the run" begin
    m1 = load_model(:A1); m2 = load_model(:A2)
    for s in seeds
        plain = Base.invokelatest(() -> m1.modelRun(build(m1, s)[1]))
        _, _, _, _, rec = recorded(m2, s)
        @test plain == rec
    end
end

# ---------------------------------------------------------------- B
@testset "B. bankRunDock" begin
    m = load_model(:B0)
    for s in seeds
        mod, isI, rec, v0, _ = recorded(m, s)
        d = Base.invokelatest(m.dockRow, mod, rec, v0)
        depTotal = sum(a.deposit for a in mod.agtList)
        @test nrow(d) == 1 && d.nExog[1] == rec.nExog
        @test d.reserveShare[1] * depTotal ≈ v0
        @test d.slack[1] * depTotal + sum(rec.paid[1:rec.nExog]; init=0.0) ≈ v0
        @test isnan(d.pubErr1[1]) && isnan(d.pubErrMean[1])          # no announcement
        @test d.nTicks[1] >= (length(rec.order) > rec.nExog ? 1 : 0)
        @test all(rec.tick[1:rec.nExog] .== 0) && all(rec.tick[rec.nExog+1:end] .>= 1)
    end
    # Reserve 0.4 so runs last several ticks (at 0.15 the bank fails within
    # tick 1 and a stale level never gets the chance to fall behind). A run whose
    # shock alone empties the vault has no tick and no announcement: NaN.
    mf = load_model(:Bf)                       # announcement refreshed every tick, no spin
    Core.eval(mf, :(PUBLIC_MODE = "stale"; PUBLIC_REFRESH = 1; PUBLIC_ALPHA = 0.5))
    ms = load_model(:Bs)                       # frozen at its tick-1 level
    Core.eval(ms, :(PUBLIC_MODE = "stale"; PUBLIC_REFRESH = 0; PUBLIC_ALPHA = 0.5))
    lagged = 0
    for s in seeds
        mod, _, rec, v0, _ = recorded(mf, s; reserve=0.4)
        d = Base.invokelatest(mf.dockRow, mod, rec, v0)
        if d.nTicks[1] == 0
            @test isnan(d.pubErr1[1]) && isnan(d.pubErrMean[1])
        else
            @test d.pubErr1[1] == 0 && d.pubErrMean[1] == 0
        end
        mod, _, rec, v0, _ = recorded(ms, s; reserve=0.4)
        d = Base.invokelatest(ms.dockRow, mod, rec, v0)
        if d.nTicks[1] > 0
            @test d.pubErr1[1] == 0 && d.pubErrMean[1] <= 0
            lagged += d.pubErrMean[1] < 0
        end
    end
    @test lagged > 0                           # the stale level does fall behind somewhere
end

# ---------------------------------------------------------------- C
@testset "C. bankRunTiming and bankRunWealth add up" begin
    m = load_model(:C0)
    for s in seeds
        mod, isI, rec, _, _ = recorded(m, s)
        ts = Base.invokelatest(m.typeSummary, mod, isI, rec)
        tm = Base.invokelatest(m.timingRows, mod, isI, rec)
        wl = Base.invokelatest(m.wealthRows, mod, isI, rec)
        tcols = [c for c in names(tm) if startswith(c, "t") && c != "type" && c != "tickSumEndog"]
        @test length(tcols) == m.TIMING_TICKS
        for lab in ("I", "C")
            t = ts[ts.type .== lab, :]; r = tm[tm.type .== lab, :]; w = wl[wl.type .== lab, :]
            @test sum(r[1, c] for c in tcols) == t.nEndog[1]
            @test sum(w[1, "n_d$j"] for j in 1:10) == t.n[1]
            @test sum(w[1, "endog_d$j"] for j in 1:10) == t.nEndog[1]
        end
        @test sum(tm.tickSumEndog) == sum(rec.tick)
        @test sum(sum(wl[:, "n_d$j"]) for j in 1:10) == length(mod.agtList)
        @test all(sum(wl[:, "n_d$j"]) in (5, 6, 7) for j in 1:10)   # 60 agents, ~6 per decile
    end
end
