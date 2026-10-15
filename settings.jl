# Run settings: the BANKRUN_* switches, their defaults, and the ENV parsers.
#
# One home for every switch default (added 2026-10-15). finMain0001.jl parses the
# switches from ENV on the master and broadcasts them as consts; functions4.jl
# reads them through switchValue(), which falls back to the default when a
# script includes the model without finMain0001.jl (test_run.jl, tests/,
# scripts/who_runs_pilot.jl). Every default is the published model.
#
# Include this file before functions4.jl, in the same module.
#
# Not here: BANKRUN_ASSIGN_RULE and BANKRUN_MC_DEPTH, which finMain0001.jl
# parses directly (tests/test_assignment_rules.jl evaluates the ASSIGN_RULE
# fallback in functions4.jl modelGen by text marker).

const SWITCH_DEFAULTS = (
    PUBLIC_ALPHA     = 0.0,    # share of the social signal that is the public announcement
    PUBLIC_BIAS      = 0.0,    # spin: announcement understates withdrawals by b·N at tick 1
    PUBLIC_RHO       = 1.0,    # spin persistence: understatement b·ρ^(t-1)·N
    WEIGHT_PHI       = 1.0,    # social-weight decay: ω_t = λ·φ^(t-1)
    FIX_DOUBLE_COUNT = false,  # skip already-withdrawn agents in sub-simulations
    FRESH_CLONE      = false,  # simulate from the current state, not the post-shock snapshot
)

"""The value of switch `name` in this module, or its default if it is not set."""
switchValue(name::Symbol) =
    isdefined(@__MODULE__, name) ? getfield(@__MODULE__, name) : SWITCH_DEFAULTS[name]

# `get(ENV, k, default)` returns "" for a SET-BUT-EMPTY variable, and SLURM
# --export=ALL,FOO= propagates exactly that, so empty is treated as absent.
function envFloat(name, default, lo, hi; loOpen=false)
    s = strip(get(ENV, name, ""))
    isempty(s) && return default
    v = tryparse(Float64, s)
    ok = v !== nothing && (loOpen ? v > lo : v >= lo) && v <= hi
    ok || error("$name must be a number in $(loOpen ? "(" : "[")$lo,$hi], got \"$s\"")
    return v
end
function envBool(name, default=false)
    s = lowercase(strip(get(ENV, name, "")))
    isempty(s) && return default
    s in ("true", "1") && return true
    s in ("false", "0") && return false
    error("$name must be true|false, got \"$s\"")
end
