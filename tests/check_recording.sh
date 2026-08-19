#!/usr/bin/env bash
# check_recording.sh — post-run acceptance gate for a single-cell (smoke) arm.
#
# Distinct from check_sweep_run.py, which asks "did the array tasks finish?".
# This asks "did the 2026-08-13 recording fixes actually land in the output?" —
# the parameter dump widened 12 -> 16 (sigma, assignRule, mcDepth), the result
# row widened 2 -> 4 (|S*|), and both new run parameters reached Julia rather
# than merely the shell.
#
# Usage:
#   ./tests/check_recording.sh                                   # arm 'smoke', task 1
#   ./tests/check_recording.sh --tag smoke-placebo --rule random
#   ./tests/check_recording.sh --tag depth1000 --depth 1000
#
# Logs are auto-discovered in /scratch/$USER; override with --log / --errlog.
#
# Exit codes:
#   0  every check passed, including the decisive |S*| implication
#   1  at least one FAIL — do not consolidate or quote numbers from this arm
#   2  INCONCLUSIVE — nothing failed, but the cell produced no bankRun==true run,
#      so the decisive check-6 assertion was never exercised. Re-smoke at a lower
#      reserve ratio. This is deliberately NOT 0: a gate that could not run its
#      own decisive test has not certified anything.

set -uo pipefail

# EXPECT_RUNS=250, not 50. parameterGen.jl:111 is
#   seed1 = repeat(sample(1:1000000, seedRun, replace=false), seedRun)
# which yields 25 seedFrame rows (5 distinct seeds, each 5x), crossjoined with
# iteration 1:runSize=10 -> 250 rows per cell. `iteration` never reaches the
# model, so the structure is 5 initialisations x 50 shock draws, NOT the
# "5 x 10 = 50" the comments at parameterGen.jl:39-42 describe. Confirmed
# against the 2026-04 legacy sweep: 2,833 of 2,835 cells hold exactly 250 rows
# with exactly 5 distinct seed1 (the other two hold 500 / 10 — genuine top-ups).
TAG="smoke"; TASK=1; EXPECT_RUNS=250; EXPECT_RULE="warmup"; EXPECT_DEPTH=100
EXPECT_AGENTS=1000; LOG=""; ERRLOG=""; DECISIVE_UNTESTED=0
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)     TAG="$2"; shift 2 ;;
        --task)    TASK="$2"; shift 2 ;;
        --runs)    EXPECT_RUNS="$2"; shift 2 ;;
        --rule)    EXPECT_RULE="$2"; shift 2 ;;
        --depth)   EXPECT_DEPTH="$2"; shift 2 ;;
        --agents)  EXPECT_AGENTS="$2"; shift 2 ;;
        --log)     LOG="$2"; shift 2 ;;
        --errlog)  ERRLOG="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

T="${PROJECT_ROOT}/outputs/${TAG}/task_${TASK}"
PASS=0; FAIL=0; WARN=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

echo "======================================================================"
echo "check_recording.sh — arm=${TAG} task=${TASK}"
echo "  expecting: ${EXPECT_RUNS} runs, rule=${EXPECT_RULE}, depth=${EXPECT_DEPTH}"
echo "  task dir:  ${T}"
echo "======================================================================"

if [[ ! -d "$T" ]]; then
    echo "FATAL: task dir not found: $T" >&2
    echo "       (arm not run, or --tag/--task wrong)" >&2
    exit 1
fi

# Locate the slurm logs if not given. %A_%a means the array task's own file.
# BOTH streams matter: run_all.sh sends stdout to .out and stderr to .err with the
# same basename, and an include-time Julia error lands ONLY in .err while the three
# startup PASSes below still appear in .out. Discovering .out alone is how the
# 2026-08-13 smoke failure read as "3 PASS" on a job that accomplished nothing.
if [[ -z "$LOG" ]]; then
    LOG=$(ls -t /scratch/"${USER}"/bankrun-"${TAG}"-sweep-*_"${TASK}".out 2>/dev/null | head -1 || true)
fi
if [[ -z "$ERRLOG" ]]; then
    if [[ -n "$LOG" && -f "${LOG%.out}.err" ]]; then
        ERRLOG="${LOG%.out}.err"
    else
        ERRLOG=$(ls -t /scratch/"${USER}"/bankrun-"${TAG}"-sweep-*_"${TASK}".err 2>/dev/null | head -1 || true)
    fi
fi

PARAMS="${T}/bankRunParametersInit.csv"
shopt -s nullglob
RESULTS=("${T}"/bankRunResults*.csv)
AGENTS=("${T}"/agents*.csv)
shopt -u nullglob

# ── 1. parameter dump width ───────────────────────────────────────────────────
hdr "1. Parameter dump width (expect 16; was 12 before sigma/assignRule/mcDepth)"
if [[ -f "$PARAMS" ]]; then
    PARAM_W=$(awk -F, '{print NF; exit}' "$PARAMS")
    if [[ "$PARAM_W" == "16" ]]; then ok "bankRunParametersInit.csv has 16 columns"
    elif [[ "$PARAM_W" == "12" ]]; then bad "12 columns — the parameterGen.jl recording fix did NOT land"
    else bad "unexpected width: $PARAM_W"; fi
    # widths must be uniform: a mid-run code change would show as mixed widths
    uniq_w=$(awk -F, '{print NF}' "$PARAMS" | sort -u | tr '\n' ' ')
    [[ $(echo "$uniq_w" | wc -w) -eq 1 ]] || bad "mixed row widths in params dump: $uniq_w"
else
    bad "missing $PARAMS"
fi

# ── 2. result row width ───────────────────────────────────────────────────────
hdr "2. Result row width (expect 4; was 2 before |S*|)"
if [[ ${#RESULTS[@]} -gt 0 ]]; then
    RES_W=$(cat "${RESULTS[@]}" | awk -F, '{print NF; exit}')
    if [[ "$RES_W" == "4" ]]; then ok "bankRunResults*.csv has 4 columns (key,result,nWithdrawn,depositWithdrawn)"
    elif [[ "$RES_W" == "2" ]]; then bad "2 columns — the runSetSize() instrumentation did NOT land"
    else bad "unexpected width: $RES_W"; fi
else
    bad "no bankRunResults*.csv found in $T"
fi

# ── 3. run count ──────────────────────────────────────────────────────────────
hdr "3. Run count (expect ${EXPECT_RUNS} = 5 initialisations x 50 shock draws)"
if [[ ${#RESULTS[@]} -gt 0 ]]; then
    n=$(cat "${RESULTS[@]}" | grep -c . || true)
    if [[ "$n" -eq "$EXPECT_RUNS" ]]; then ok "$n runs across ${#RESULTS[@]} worker files"
    elif [[ "$n" -lt "$EXPECT_RUNS" ]]; then
        bad "$n of ${EXPECT_RUNS} — under-filled. TIMEOUT or a worker died (the 2026-04 failure mode)"
    elif [[ $((n % EXPECT_RUNS)) -eq 0 ]]; then
        warn "$n = $((n / EXPECT_RUNS)) x ${EXPECT_RUNS} — an exact multiple, so this task was submitted $((n / EXPECT_RUNS)) times. restart.jl is not wired in, so a re-submitted task APPENDS a fresh block under new keys rather than resuming"
    else
        warn "$n of ${EXPECT_RUNS} — surplus, and not an exact multiple. Neither a clean re-submission nor a clean single run; inspect the key timestamps"
    fi
    # 5 distinct seed1 per block. Runs sharing a seed1 share network, warm-up,
    # lambda assignment AND deposit vector (functions4.jl:28,82,92) — they differ
    # only in seed2, the exogenous shock and cascade order. So the independent
    # unit is the initialisation, not the run.
    blocks=$(( n / EXPECT_RUNS )); [[ "$blocks" -lt 1 ]] && blocks=1
    nseed1=$(cat "${RESULTS[@]}" | awk -F, '{k=split($1,a,"-"); print a[k-1]}' | sort -u | wc -l)
    if [[ "$nseed1" -eq $(( 5 * blocks )) ]]; then
        ok "$nseed1 distinct seed1 over $n runs — 5 initialisations per block, as designed"
    else
        warn "$nseed1 distinct seed1 over $n runs — expected $(( 5 * blocks )). Runs within a seed1 are NOT independent"
    fi
    # keys must be unique — duplicates mean two blocks were merged
    dups=$(cat "${RESULTS[@]}" | awk -F, '{print $1}' | sort | uniq -d | wc -l)
    if [[ "$dups" -eq 0 ]]; then ok "no duplicate keys"
    else bad "$dups duplicate key(s) — two run blocks merged into one arm"; fi
else
    bad "no results to count"
fi

# ── 4. stderr, then run parameters reached Julia ──────────────────────────────
# Read stderr FIRST. The three startup assertions below fire at finMain0001.jl:49
# and :82 — before the @everywhere includes and before any model code — so they
# pass on a task that died at include time. Only .err distinguishes the two.
hdr "4a. Task stderr (read this first — a fast failure lives here, not in .out)"
if [[ -n "$ERRLOG" && -f "$ERRLOG" ]]; then
    echo "     err: $ERRLOG"
    if [[ ! -s "$ERRLOG" ]]; then
        ok "stderr is empty"
    elif grep -qE '^(ERROR|fatal|Fatal|Segmentation|ERROR: LoadError)' "$ERRLOG" \
      || grep -qiE 'error: loaderror|invalid redefinition|UndefVarError|MethodError|out of memory|Killed|CANCELLED|DUE TO TIME LIMIT' "$ERRLOG"; then
        bad "stderr reports a hard error — the checks below say nothing about the model:"
        grep -nEm1 -B2 -A12 'ERROR|error:|UndefVarError|MethodError|CANCELLED|Killed' "$ERRLOG" \
            | sed 's/^/       | /'
    else
        warn "stderr is non-empty but shows no recognised error pattern — read it:"
        head -20 "$ERRLOG" | sed 's/^/       | /'
    fi
else
    warn "stderr log not found — pass --errlog <path>. A silent include-time failure would be invisible"
fi

hdr "4b. Startup lines (proves the exports reached JULIA, not just the shell)"
if [[ -n "$LOG" && -f "$LOG" ]]; then
    echo "     log: $LOG"
    echo "     NOTE: these three fire before any model code; they are necessary, not sufficient."
    grep -q "matches Manifest pin" "$LOG" \
        && ok "Julia/Manifest version guard passed" \
        || bad "version guard line absent — old sweep_task.slurm, or the guard did not run"
    if grep -q "assignment rule: ${EXPECT_RULE}\b" "$LOG"; then
        ok "Julia reports assignment rule: ${EXPECT_RULE}"
    else
        bad "expected 'assignment rule: ${EXPECT_RULE}', got: $(grep -m1 'assignment rule' "$LOG" || echo '(absent)')"
    fi
    if grep -q "Monte Carlo depth: ${EXPECT_DEPTH}\b" "$LOG"; then
        ok "Julia reports Monte Carlo depth: ${EXPECT_DEPTH}"
    else
        bad "expected 'Monte Carlo depth: ${EXPECT_DEPTH}', got: $(grep -m1 'Monte Carlo depth' "$LOG" || echo '(absent)')"
    fi
else
    warn "slurm log not found — pass --log <path> to check the startup lines"
fi

# ── 5. run parameters recorded in the dump ────────────────────────────────────
hdr "5. Run parameters recorded in the dump (cols 15,16)"
if [[ -f "$PARAMS" && "${PARAM_W:-0}" == "16" ]]; then
    rules=$(awk -F, '{print $15}' "$PARAMS" | sort -u | tr -d '"' | tr '\n' ' ')
    depths=$(awk -F, '{print $16}' "$PARAMS" | sort -u | tr '\n' ' ')
    [[ "$(echo "$rules" | xargs)" == "$EXPECT_RULE" ]] \
        && ok "assignRule column == ${EXPECT_RULE}" \
        || bad "assignRule column holds '$(echo "$rules" | xargs)', expected ${EXPECT_RULE}"
    [[ "$(echo "$depths" | xargs)" == "$EXPECT_DEPTH" ]] \
        && ok "mcDepth column == ${EXPECT_DEPTH}" \
        || bad "mcDepth column holds '$(echo "$depths" | xargs)', expected ${EXPECT_DEPTH}"
    sig=$(awk -F, '{print $14}' "$PARAMS" | sort -u | tr '\n' ' ')
    [[ -n "$(echo "$sig" | xargs)" ]] \
        && ok "lognSigma column populated (${sig%% *})" \
        || bad "lognSigma empty — the sigma join fix did not land"
else
    warn "skipped (params dump missing or still 12 columns)"
fi

# ── 6. |S*| sanity ────────────────────────────────────────────────────────────
hdr "6. |S*| sanity — THE decisive check"
if [[ ${#RESULTS[@]} -eq 0 ]]; then
    bad "no results to check"
elif [[ "${RES_W:-0}" != "4" ]]; then
    warn "skipped — result rows are ${RES_W:-?} columns wide, so there is no |S*| to check (see check 2)"
else
    read -r mn mx <<<"$(cat "${RESULTS[@]}" | awk -F, 'NR==1{mn=mx=$3} {if($3+0<mn)mn=$3; if($3+0>mx)mx=$3} END{print mn, mx}')"
    if awk -v a="$mn" -v b="$mx" -v c="$EXPECT_AGENTS" 'BEGIN{exit !(a>=0 && b<=c)}'; then
        ok "nWithdrawn in [0, ${EXPECT_AGENTS}] (observed ${mn}..${mx})"
    else
        bad "nWithdrawn out of range: ${mn}..${mx} against ${EXPECT_AGENTS} agents"
    fi
    # the one that distinguishes "plausible numbers" from "the right state"
    viol=$(cat "${RESULTS[@]}" | awk -F, 'tolower($2)=="true" && $3+0==0' | wc -l)
    ntrue=$(cat "${RESULTS[@]}" | awk -F, 'tolower($2)=="true"' | wc -l)
    if [[ "$ntrue" -eq 0 ]]; then
        warn "no bankRun==true rows in this cell — cannot test the implication (try a lower reserve ratio)"
        DECISIVE_UNTESTED=1
    elif [[ "$viol" -eq 0 ]]; then
        ok "all ${ntrue} bankRun==true rows have nWithdrawn > 0"
    else
        bad "${viol} of ${ntrue} bankRun==true rows report nWithdrawn == 0 — runSetSize() is NOT reading withdrawHistory correctly; |S*| is wrong everywhere downstream"
    fi
    # deposit-weighted sum must move with the count
    viol2=$(cat "${RESULTS[@]}" | awk -F, '$3+0>0 && $4+0<=0' | wc -l)
    [[ "$viol2" -eq 0 ]] \
        && ok "depositWithdrawn > 0 wherever nWithdrawn > 0" \
        || bad "${viol2} row(s) withdraw agents but zero deposits — the deposit-weighted sum is broken"
fi

# ── 7. agents file ────────────────────────────────────────────────────────────
hdr "7. Agents file (expect 6 cols: key,idx,deposit,individualism,warmupLambda,agentType)"
if [[ ${#AGENTS[@]} -gt 0 ]]; then
    AG_W=$(cat "${AGENTS[@]}" | awk -F, '{print NF; exit}')
    [[ "$AG_W" == "6" ]] && ok "agents*.csv has 6 columns" || bad "agents*.csv has $AG_W columns, expected 6"
    # the intervention itself: is type I the top-mu of warmupLambda, or not?
    read -r mI mC <<<"$(cat "${AGENTS[@]}" | awk -F, '
        {gsub(/"/,"",$6); if($6=="I"){si+=$5; ni++} else {sc+=$5; nc++}}
        END{printf "%.4f %.4f", (ni?si/ni:0), (nc?sc/nc:0)}')"
    echo "     mean warmupLambda:  type I = ${mI}   type C = ${mC}"
    case "$EXPECT_RULE" in
        warmup)
            awk -v a="$mI" -v b="$mC" 'BEGIN{exit !(a>b)}' \
                && ok "type I has higher mean warm-up lambda — ranking is active, as published" \
                || bad "type I does NOT rank above type C — the warmup assignment path is broken" ;;
        random)
            awk -v a="$mI" -v b="$mC" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.10)}' \
                && ok "type I and C means are close — cultural type is decoupled from warm-up position, as the placebo requires" \
                || bad "means differ by more than 0.10 — the random arm is still tracking warm-up lambda" ;;
        reverse)
            awk -v a="$mI" -v b="$mC" 'BEGIN{exit !(a<b)}' \
                && ok "type I ranks BELOW type C — anti-treatment active" \
                || bad "reverse arm did not invert the ranking" ;;
    esac
else
    bad "no agents*.csv found"
fi

echo ""
echo "======================================================================"
printf "RESULT: %d passed, %d failed, %d warnings\n" "$PASS" "$FAIL" "$WARN"
if [[ "$FAIL" -gt 0 ]]; then
    echo "STATUS: FAIL — do not consolidate or quote numbers from this arm"
    echo "======================================================================"
    exit 1
fi
if [[ "$DECISIVE_UNTESTED" -eq 1 ]]; then
    echo "STATUS: INCONCLUSIVE — nothing failed, but this cell never produced a"
    echo "        bankRun==true run, so check 6's decisive assertion"
    echo "        (bankRun ⇒ nWithdrawn > 0) was never exercised. runSetSize() is"
    echo "        therefore still unverified. Re-smoke at a lower reserve ratio."
    echo "        This is NOT a pass."
    echo "======================================================================"
    exit 2
fi
echo "STATUS: OK"
echo "======================================================================"
