# Run from the BankRuns5 repo root:
#     julia test/test_assignment_rules.jl
#
# These tests EXTRACT the relevant block out of functions4.jl by text marker and
# eval it, rather than re-implementing it — so they exercise the shipped source.
# That also means they break loudly if the markers move, which is intended: a
# silently-skipped test on this code is worse than a failing one.
#
# They need no project dependencies (Base + Random only), which is why they exist
# in this form: the full model cannot be run locally (JLD2 absent, Manifest pins
# unmatched, ~/.julia unwritable in-sandbox).

using Random

# Extract the REAL type-assignment block out of functions4.jl (between the
# "---- Type assignment ----" and "---- Per-agent λ draws ----" markers) and
# eval it, so this exercises the shipped source text rather than a copy.
src   = read("functions4.jl", String)
start = findfirst("    # ---- Type assignment ----", src)[1]
stop  = findfirst("    # ---- Per-agent λ draws ----", src)[1]
block = src[start:stop-1]
println("extracted $(count(==('\n'), block)) lines of the real assignment block\n")

# The block references agtCnt / fracIndividualists / lambdas_warmup / seed1 /
# ASSIGN_RULE from its enclosing scope; bind them as Main globals, then eval the
# block at top level exactly as the function body would see them.
function assign(rule, lw, n, mu_, s1)
    @eval Main begin
        ASSIGN_RULE        = $rule
        lambdas_warmup     = $lw
        agtCnt             = $n
        fracIndividualists = $mu_
        seed1              = $s1
    end
    Main.eval(Meta.parse("begin\n" * block * "\nend"))
    return (Main.isI, Main.sortIdx)
end

agtCnt_test = 1000
seed1_test  = 4242
Random.seed!(99)
lambdas_warmup = rand(agtCnt_test)          # stand-in warm-up resistance scores
mu = 0.25
nI_expected = round(Int, mu * agtCnt_test)

results = Dict()
for rule in ("warmup", "random", "reverse")
    global lambdas_warmup
    isI, sortIdx = assign(rule, lambdas_warmup, agtCnt_test, mu, seed1_test)
    sel = findall(isI)
    meanwarm = sum(lambdas_warmup[sel]) / length(sel)
    results[rule] = (count(isI), meanwarm, sel)
    println("rule=$(rpad(rule,8)) nI=$(count(isI))  mean warmup-λ of type I = $(round(meanwarm, digits=4))")
end

println()
overall = sum(lambdas_warmup)/agtCnt_test
println("population mean warmup-λ = $(round(overall, digits=4))")

# ── Assertions ───────────────────────────────────────────────────────────────
w, r, v = results["warmup"], results["random"], results["reverse"]
@assert w[1] == nI_expected "warmup arm picked $(w[1]) individualists, expected $nI_expected"
@assert r[1] == nI_expected && v[1] == nI_expected "arms must hold nI constant"
@assert w[2] > 0.85          "warmup arm must select the TOP of the warmup-λ distribution"
@assert v[2] < 0.15          "reverse arm must select the BOTTOM"
@assert abs(r[2] - overall) < 0.03 "random arm's type I should be a representative sample"

# Determinism: same seed -> same random permutation.
isI_a, _ = assign("random", lambdas_warmup, agtCnt_test, mu, seed1_test)
isI_b, _ = assign("random", lambdas_warmup, agtCnt_test, mu, seed1_test)
@assert isI_a == isI_b "random arm must be reproducible for a given seed1"

# The default path must be identical to the pre-change code.
legacy = falses(agtCnt_test); legacy[sortperm(lambdas_warmup, rev=true)[1:nI_expected]] .= true
isI_w, _ = assign("warmup", lambdas_warmup, agtCnt_test, mu, seed1_test)
@assert isI_w == legacy "default 'warmup' arm is NOT bit-identical to the published code path"

println("\n✅ all assertions passed")
println("   - warmup arm bit-identical to the published sortperm(rev=true) path")
println("   - random arm reproducible, and its type-I set is representative")
println("   - reverse arm selects cluster interiors")
println("   - nI held constant across all three arms (only placement varies)")
