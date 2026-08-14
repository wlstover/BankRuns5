# Run from the BankRuns5 repo root:
#     julia test/test_name_collisions.jl
#
# Guards the failure class that killed job 9363073_1 on 2026-08-13.
#
# finMain0001.jl includes objects.jl / warmup.jl / functions4.jl @everywhere
# (lines 84-88), and THEN includes parameterGen.jl into Main (line 130). Every
# `function foo(...)` in the first group binds `foo` as a CONSTANT in Main. If
# parameterGen.jl (or finMain0001.jl itself) later does a top-level `foo = ...`,
# Julia refuses with `invalid redefinition of constant foo` and the task dies
# before writing a single output file — a full walltime slot and an HPC
# round-trip spent on a name.
#
# That is exactly what `function runSize(mod::Model)` did against Schuler's
# `runSize=10` at parameterGen.jl:42. It is invisible to test_runsize.jl and
# test_assignment_rules.jl, because those extract a block by text marker and
# eval it in a bare namespace where parameterGen.jl does not exist. The blind
# spot is structural, not an oversight: it is the price of testing the shipped
# source with no project dependencies.
#
# Static check, no dependencies, no Julia session that loads the model.

const DEFINERS = ["objects.jl", "warmup.jl", "functions4.jl"]   # included first, @everywhere
const ASSIGNERS = ["parameterGen.jl", "finMain0001.jl"]         # included into Main afterwards

read_lf(f) = replace(read(f, String), "\r\n" => "\n")           # Schuler's files are CRLF

# Names bound as constants by the @everywhere includes.
defs = Dict{String,Vector{String}}()
for f in DEFINERS
    for line in split(read_lf(f), '\n')
        startswith(strip(line), "#") && continue
        for re in (r"^\s*function\s+([A-Za-z_][\w!]*)\s*\(",   # function foo(...)
                   r"^([A-Za-z_][\w!]*)\s*\([^)]*\)\s*=(?!=)", # foo(x) = ...
                   r"^\s*const\s+([A-Za-z_][\w!]*)")           # const FOO
            m = match(re, line)
            m === nothing || push!(get!(defs, m.captures[1], String[]), f)
        end
    end
end

# Top-level variable assignments in the files included afterwards.
assigns = Dict{String,Vector{String}}()
for f in ASSIGNERS
    for (i, line) in enumerate(split(read_lf(f), '\n'))
        startswith(strip(line), "#") && continue
        m = match(r"^([A-Za-z_][\w!]*)\s*\.?=(?!=)", line)      # foo = ... and foo .= ...
        m === nothing || push!(get!(assigns, m.captures[1], String[]), "$f:$i")
    end
end

collisions = sort(collect(intersect(keys(defs), keys(assigns))))

println("$(length(defs)) names bound by $(join(DEFINERS, ", "))")
println("$(length(assigns)) top-level assignment targets in $(join(ASSIGNERS, ", "))\n")

if !isempty(collisions)
    for c in collisions
        println("COLLISION: $c")
        println("   bound as a function/const in : $(join(unique(defs[c]), ", "))")
        println("   assigned as a variable at    : $(join(assigns[c], ", "))")
    end
    error("$(length(collisions)) name collision(s) — the task will die at include time " *
          "with `invalid redefinition of constant`, before writing any output")
end

println("✅ no name collisions across the include order")
