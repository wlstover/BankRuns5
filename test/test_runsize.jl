# Run from the BankRuns5 repo root:
#     julia test/test_runsize.jl
#
# These tests EXTRACT the relevant block out of functions4.jl by text marker and
# eval it, rather than re-implementing it — so they exercise the shipped source.
# That also means they break loudly if the markers move, which is intended: a
# silently-skipped test on this code is worse than a failing one.
#
# They need no project dependencies (Base + Random only), which is why they exist
# in this form: the full model cannot be run locally (JLD2 absent, Manifest pins
# unmatched, ~/.julia unwritable in-sandbox).

# Stub the two structs runSetSize touches, then eval the REAL runSetSize source.
mutable struct Agent; idx::Int64; deposit::Float64; banked::Bool; individualism::Float64; end
mutable struct Bank; vault::Float64; bankingList::Array{Agent}; withdrawHistory::Array{Agent}; end
mutable struct Model; theBank::Bank; end

src = read("functions4.jl", String)
i = findfirst("function runSetSize(mod::Model)", src)[1]
j = findnext("\nend", src, i)[1] + 3
eval(Meta.parse(src[i:j]))
println("evaluated real runSetSize definition\n")

mk(deps) = Model(Bank(0.0, Agent[], [Agent(k, d, false, 0.5) for (k,d) in enumerate(deps)]))

# empty withdrawal set — the sum() would throw on an empty collection without
# the isempty guard, which is the whole reason that branch exists.
n, d = runSetSize(mk(Float64[]))
@assert (n, d) == (0, 0.0) "empty case must be (0, 0.0), got ($n, $d)"
println("empty run:    n=$n  deposits=$d")

n, d = runSetSize(mk([10.0, 250.5, 3.25]))
@assert n == 3 && d ≈ 263.75 "expected (3, 263.75), got ($n, $d)"
println("3 withdrawals: n=$n  deposits=$d")

big = mk(fill(2.0, 1000))
n, d = runSetSize(big)
@assert n == 1000 && d ≈ 2000.0
println("full run:     n=$n  deposits=$d")

println("\n✅ runSetSize: counts and deposit-weights the withdrawal set; empty case guarded")
