# Run settings: the BANKRUN_* switches, their defaults, and the ENV parsers.
#
# One home for every switch default (added 2026-10-15). finMain0001.jl parses the
# switches from ENV on the master and broadcasts them as consts; functions4.jl
# reads them through switchValue(), which falls back to the default when a
# script includes the model without finMain0001.jl (test_run.jl, tests/,
# scripts/who_runs_pilot.jl). Every default is the published model, except
# FIX_DOUBLE_COUNT (default on since 2026-10-20; BANKRUN_FIX_DOUBLE_COUNT=false
# reproduces the published model).
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
    FIX_DOUBLE_COUNT = true,   # skip already-withdrawn agents in sub-simulations (false = published)
    FRESH_CLONE      = false,  # simulate from the current state, not the post-shock snapshot
    # schuler-sync (2026-10-15): Schuler's BankRunsFinal changes, as switches.
    TIEBREAK         = "legacy",     # decision rule at the margin; see decide() in functions4.jl
    BELIEF           = "geometric",  # the agent's own prior draws; see beliefDraws()
    BELIEF_P0        = 0.02,         # withdrawal probability of the "point" prior (Schuler's p0)
    # Signal structure for docking with Chapter 1 (2026-10-20).
    PUBLIC_MODE      = "markup",     # announcement: markup = true count − spin each tick; stale = level, and the agent's view of the bank, frozen between refreshes
    PUBLIC_REFRESH   = 0,            # stale mode: refresh the level every k ticks (0 = never after tick 1)
    PRIVATE_SIGNAL   = "none",       # none = uninformative prior draws; shock = posterior given a noisy signal of the realised shock
    PRIVATE_NOISE    = 5.0,          # shock mode: s.d. of the private signal, in agents
    # Stayers' return (2026-10-20): Chapter 1's R. 1 = published (stayers earn nothing).
    STAY_RETURN      = 1.0,          # R ≥ 1: withdraw iff P_WD > R·P_stay (L = 0); see decide()
    # Balance sheet and fundamental (2026-10-21), docking with Chapter 1's
    # fire-sale bank (Rochet–Vives). The defaults are today's model; the values
    # of the four numeric settings matter only under firesale / theta.
    PAYOFF           = "full",       # full = compare P(paid in full); recovery = expected recovery fraction
    BALANCE          = "vault",      # vault = pay from reserves only, fail when they run out; firesale = sell the long asset at a discount, fail when insolvent at the end
    FIRE_DISCOUNT    = 0.25,         # firesale: the long asset sells for 1 − d per unit
    EQUITY           = 0.10,         # firesale: equity per unit of deposits, held in the long asset
    FUNDAMENTAL      = "none",       # none = the long asset returns RETURN_HI; theta = θ ~ U[0,1] per run, return R_lo + (R_hi − R_lo)·θ
    RETURN_LO        = 0.9,          # firesale: gross return of the long asset at θ = 0
    RETURN_HI        = 1.3,          # firesale: gross return at θ = 1
    THETA_NOISE      = 0.10,         # PRIVATE_SIGNAL = theta: s.d. of x_i = θ + s·Z_i
    # Public signal of θ (2026-10-22): Chapter 1's y, blended with x_i by the
    # cultural weight, est_i = (1 − ω)·x_i + ω·y, and its subjective window.
    THETA_PUBLIC       = "none",     # none; stale = y fixed at THETA_PUBLIC_LEVEL whatever θ is (Ch 1); tracks = y = θ + THETA_PUBLIC_GAP
    THETA_PUBLIC_LEVEL = 0.6,        # stale: the level y₀ (the gap y₀ − θ varies run by run)
    THETA_PUBLIC_GAP   = 0.0,        # tracks: the constant gap δ = y − θ
    THETA_PUBLIC_RHO   = 1.0,        # the gap decays as gap₀·ρ^(t-1) (1 = it persists; < 1 = y corrects)
    THETA_PUBLIC_NOISE = 0.10,       # ε_y: the noise agents attribute to y; window (1 − ω)·s_x + ω·s_y
    LAMBDA_SCOPE       = "count",    # which blend λ weights: count (published) | theta | both; the other uses the population mean λ̄
    # Seeding and allocation (2026-10-22; parameterGen.jl, scripts/sweep_task.slurm).
    SEEDING          = "task",       # task: GEN_SEED = SEED_OFFSET + array index (each cell its own banks); common: GEN_SEED = SEED_OFFSET in every cell, seeds from their own stream (same banks and θ in every cell)
    N_INIT           = 5,            # initialisations per cell (1, 5 or 25), each run 250 / N_INIT times
    # Partial withdrawals (2026-10-22; decision by the user): all = the whole
    # balance or nothing (published); partial = a fraction of the remaining
    # balance, chosen from {0, ¼, ½, ¾, 1} by expected value (functions4.jl,
    # chooseFraction). Only agents whose balance exceeds PARTIAL_MIN_SHARE of the
    # bank's current period-1 capacity evaluate the interior fractions.
    WITHDRAW         = "all",
    PARTIAL_MIN_SHARE = 0.01,
    # Risk aversion (2026-10-22; the user): 0 = risk neutral (published). > 0 =
    # CARA utility −exp(−a·w), a = CARA / mean initial deposit, so the depositor
    # holding the mean deposit has a·b = CARA (functions4.jl ceValue). Fire-sale
    # bank only; with WITHDRAW = partial every agent values the fractions.
    CARA             = 0.0,
    # Output (2026-10-15): "full" writes the per-agent and per-decision logs;
    # "summary" keeps run-level results and the per-type summary only (replay a
    # run with scripts/replay_run.jl to regenerate its full logs).
    LOG              = "full",
)
# Switches that change only what is written, not the model: not a reason to
# require --tag in run_all.sh (scripts/switch_names.sh --model drops them).
const OUTPUT_ONLY_SWITCHES = (:LOG,)
const LOG_CHOICES      = ("full", "summary")
const TIEBREAK_CHOICES = ("legacy", "schuler", "strict")
const BELIEF_CHOICES   = ("geometric", "point")
const PUBLIC_MODE_CHOICES    = ("markup", "stale")
const PRIVATE_SIGNAL_CHOICES = ("none", "shock", "theta")
const PAYOFF_CHOICES      = ("full", "recovery")
const BALANCE_CHOICES     = ("vault", "firesale")
const FUNDAMENTAL_CHOICES = ("none", "theta")
const THETA_PUBLIC_CHOICES = ("none", "stale", "tracks")
const LAMBDA_SCOPE_CHOICES = ("count", "theta", "both")
const SEEDING_CHOICES      = ("task", "common")
const N_INIT_CHOICES       = (1, 5, 25)
const WITHDRAW_CHOICES     = ("all", "partial")

"""The combinations of switches the model refuses, as an error message (or
nothing). Checked when the switches are parsed, so a sweep fails at startup, and
again in modelRun, for scripts and tests that set the switches directly."""
function switchComboError(sw)
    sw.PUBLIC_MODE == "stale" && !sw.FIX_DOUBLE_COUNT && !sw.FRESH_CLONE &&
        return "BANKRUN_PUBLIC_MODE=stale needs BANKRUN_FIX_DOUBLE_COUNT=true or BANKRUN_FRESH_CLONE=true"
    # Pro-rata payouts make "paid in full" the wrong criterion, and phase 1 of a
    # sub-simulation must not sell assets for neighbours already out.
    sw.BALANCE == "firesale" && sw.PAYOFF != "recovery" &&
        return "BANKRUN_BALANCE=firesale needs BANKRUN_PAYOFF=recovery"
    sw.BALANCE == "firesale" && !sw.FIX_DOUBLE_COUNT && !sw.FRESH_CLONE &&
        return "BANKRUN_BALANCE=firesale needs BANKRUN_FIX_DOUBLE_COUNT=true or BANKRUN_FRESH_CLONE=true"
    sw.FUNDAMENTAL == "theta" && sw.BALANCE != "firesale" &&
        return "BANKRUN_FUNDAMENTAL=theta needs BANKRUN_BALANCE=firesale (θ enters only the terminal valuation)"
    sw.PRIVATE_SIGNAL == "theta" && sw.FUNDAMENTAL != "theta" &&
        return "BANKRUN_PRIVATE_SIGNAL=theta needs BANKRUN_FUNDAMENTAL=theta"
    # y is blended with the private signal x_i, so it needs one.
    sw.THETA_PUBLIC != "none" && sw.PRIVATE_SIGNAL != "theta" &&
        return "BANKRUN_THETA_PUBLIC needs BANKRUN_PRIVATE_SIGNAL=theta"
    # (modelRun passes only the switches it checks; N_INIT is checked at parse time)
    !hasproperty(sw, :N_INIT) || sw.N_INIT in N_INIT_CHOICES ||
        return "BANKRUN_N_INIT must be one of $(join(N_INIT_CHOICES, "|")) (250 runs per cell)"
    # Partial withdrawals need the fire-sale bank's recovery payoff, and decisions
    # that see current balances (a snapshot would hold balances already withdrawn).
    if hasproperty(sw, :WITHDRAW) && sw.WITHDRAW == "partial"
        sw.BALANCE != "firesale" &&
            return "BANKRUN_WITHDRAW=partial needs BANKRUN_BALANCE=firesale"
        !sw.FRESH_CLONE &&
            return "BANKRUN_WITHDRAW=partial needs BANKRUN_FRESH_CLONE=true"
        sw.PUBLIC_MODE == "stale" &&
            return "BANKRUN_WITHDRAW=partial is not built for BANKRUN_PUBLIC_MODE=stale"
    end
    hasproperty(sw, :CARA) && sw.CARA > 0.0 && sw.BALANCE != "firesale" &&
        return "BANKRUN_CARA > 0 needs BANKRUN_BALANCE=firesale"
    sw.RETURN_HI < sw.RETURN_LO &&
        return "BANKRUN_RETURN_HI must be at least BANKRUN_RETURN_LO"
    return nothing
end

"""The value of switch `name`: a const of that name in this module (finMain0001.jl's
per-switch consts, or a test setting it), else the SWITCHES NamedTuple finMain0001.jl
broadcasts (so a new switch needs no per-switch const), else its default."""
switchValue(name::Symbol) =
    isdefined(@__MODULE__, name) ? getfield(@__MODULE__, name) :
    isdefined(@__MODULE__, :SWITCHES) ? getfield(getfield(@__MODULE__, :SWITCHES), name) :
    SWITCH_DEFAULTS[name]

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
function envInt(name, default, lo, hi)
    s = strip(get(ENV, name, ""))
    isempty(s) && return default
    v = tryparse(Int, s)
    (v !== nothing && lo <= v <= hi) || error("$name must be an integer in [$lo,$hi], got \"$s\"")
    return v
end
function envBool(name, default=false)
    s = lowercase(strip(get(ENV, name, "")))
    isempty(s) && return default
    s in ("true", "1") && return true
    s in ("false", "0") && return false
    error("$name must be true|false, got \"$s\"")
end
function envChoice(name, default, choices)
    s = lowercase(strip(get(ENV, name, "")))
    isempty(s) && return default
    s in choices || error("$name must be one of $(join(choices, "|")), got \"$s\"")
    return String(s)
end

"""Every BANKRUN_* switch parsed from ENV, as a NamedTuple (defaults above)."""
function parseSwitchesFromEnv()
    D = SWITCH_DEFAULTS
    sw = (PUBLIC_ALPHA     = envFloat("BANKRUN_PUBLIC_ALPHA", D.PUBLIC_ALPHA, 0.0, 1.0),
          PUBLIC_BIAS      = envFloat("BANKRUN_PUBLIC_BIAS",  D.PUBLIC_BIAS,  0.0, 1.0),
          PUBLIC_RHO       = envFloat("BANKRUN_PUBLIC_RHO",   D.PUBLIC_RHO,   0.0, 1.0),
          WEIGHT_PHI       = envFloat("BANKRUN_WEIGHT_PHI",   D.WEIGHT_PHI,   0.0, 1.0; loOpen=true),
          FIX_DOUBLE_COUNT = envBool("BANKRUN_FIX_DOUBLE_COUNT", D.FIX_DOUBLE_COUNT),
          FRESH_CLONE      = envBool("BANKRUN_FRESH_CLONE",      D.FRESH_CLONE),
          TIEBREAK         = envChoice("BANKRUN_TIEBREAK", D.TIEBREAK, TIEBREAK_CHOICES),
          BELIEF           = envChoice("BANKRUN_BELIEF",   D.BELIEF,   BELIEF_CHOICES),
          BELIEF_P0        = envFloat("BANKRUN_BELIEF_P0", D.BELIEF_P0, 0.0, 1.0; loOpen=true),
          PUBLIC_MODE      = envChoice("BANKRUN_PUBLIC_MODE", D.PUBLIC_MODE, PUBLIC_MODE_CHOICES),
          PUBLIC_REFRESH   = envInt("BANKRUN_PUBLIC_REFRESH", D.PUBLIC_REFRESH, 0, 10^6),
          PRIVATE_SIGNAL   = envChoice("BANKRUN_PRIVATE_SIGNAL", D.PRIVATE_SIGNAL, PRIVATE_SIGNAL_CHOICES),
          PRIVATE_NOISE    = envFloat("BANKRUN_PRIVATE_NOISE", D.PRIVATE_NOISE, 0.0, 1.0e6; loOpen=true),
          STAY_RETURN      = envFloat("BANKRUN_STAY_RETURN", D.STAY_RETURN, 1.0, 100.0),
          PAYOFF           = envChoice("BANKRUN_PAYOFF", D.PAYOFF, PAYOFF_CHOICES),
          BALANCE          = envChoice("BANKRUN_BALANCE", D.BALANCE, BALANCE_CHOICES),
          FIRE_DISCOUNT    = envFloat("BANKRUN_FIRE_DISCOUNT", D.FIRE_DISCOUNT, 0.0, 0.99),
          EQUITY           = envFloat("BANKRUN_EQUITY", D.EQUITY, 0.0, 10.0),
          FUNDAMENTAL      = envChoice("BANKRUN_FUNDAMENTAL", D.FUNDAMENTAL, FUNDAMENTAL_CHOICES),
          RETURN_LO        = envFloat("BANKRUN_RETURN_LO", D.RETURN_LO, 0.0, 100.0),
          RETURN_HI        = envFloat("BANKRUN_RETURN_HI", D.RETURN_HI, 0.0, 100.0),
          THETA_NOISE      = envFloat("BANKRUN_THETA_NOISE", D.THETA_NOISE, 0.0, 100.0; loOpen=true),
          THETA_PUBLIC       = envChoice("BANKRUN_THETA_PUBLIC", D.THETA_PUBLIC, THETA_PUBLIC_CHOICES),
          THETA_PUBLIC_LEVEL = envFloat("BANKRUN_THETA_PUBLIC_LEVEL", D.THETA_PUBLIC_LEVEL, 0.0, 1.0),
          THETA_PUBLIC_GAP   = envFloat("BANKRUN_THETA_PUBLIC_GAP", D.THETA_PUBLIC_GAP, -1.0, 1.0),
          THETA_PUBLIC_RHO   = envFloat("BANKRUN_THETA_PUBLIC_RHO", D.THETA_PUBLIC_RHO, 0.0, 1.0),
          THETA_PUBLIC_NOISE = envFloat("BANKRUN_THETA_PUBLIC_NOISE", D.THETA_PUBLIC_NOISE, 0.0, 100.0; loOpen=true),
          LAMBDA_SCOPE       = envChoice("BANKRUN_LAMBDA_SCOPE", D.LAMBDA_SCOPE, LAMBDA_SCOPE_CHOICES),
          SEEDING          = envChoice("BANKRUN_SEEDING", D.SEEDING, SEEDING_CHOICES),
          N_INIT           = envInt("BANKRUN_N_INIT", D.N_INIT, 1, 25),
          WITHDRAW         = envChoice("BANKRUN_WITHDRAW", D.WITHDRAW, WITHDRAW_CHOICES),
          PARTIAL_MIN_SHARE = envFloat("BANKRUN_PARTIAL_MIN_SHARE", D.PARTIAL_MIN_SHARE, 0.0, 1.0),
          CARA             = envFloat("BANKRUN_CARA", D.CARA, 0.0, 1.0e6),
          LOG              = envChoice("BANKRUN_LOG",      D.LOG,      LOG_CHOICES))
    msg = switchComboError(sw)
    msg === nothing || error(msg)
    return sw
end
