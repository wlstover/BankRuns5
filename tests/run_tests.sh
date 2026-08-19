#!/usr/bin/env bash
# run_tests.sh — run every test harness in tests/ and report one verdict.
#
# ⚠️ THE POINT OF THIS SCRIPT IS THAT A SUITE WHICH CANNOT RUN IS NOT A PASS.
# On 2026-08-16 the analysis stage died because hopper's R had no data.table,
# and on 2026-08-17 dump_network.jl died on a Julia 1.8 undefined name that
# parsing could never have caught. In both cases the missing-dependency signal
# and the work signal were decoupled. So SKIPPED is counted separately, printed
# loudly, and makes the overall exit status non-zero. If you want the tally
# without that, you are asking the wrong question.
#
# Usage:
#   ./tests/run_tests.sh              # everything
#   ./tests/run_tests.sh --python     # one language only (--julia, --r)
#   ./tests/run_tests.sh --list       # show what would run
#
# Exit: 0 only if every suite ran AND every suite passed.

set -uo pipefail          # deliberately NOT -e: a failing suite must not abort the run

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}" || exit 2

WANT_PY=1; WANT_JL=1; WANT_R=1; LIST_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --python) WANT_JL=0; WANT_R=0; shift ;;
        --julia)  WANT_PY=0; WANT_R=0; shift ;;
        --r)      WANT_PY=0; WANT_JL=0; shift ;;
        --list)   LIST_ONLY=1; shift ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

PY_TESTS=(test_diagnose_short_cells.py test_endpoint_identity.py test_cascade_reader.py
          test_type_clustering.py)
JL_TESTS=(test_assignment_rules.jl test_conservation.jl test_name_collisions.jl test_runsize.jl)
R_TESTS=(test_p6b_continuous.R)

if [[ ${LIST_ONLY} -eq 1 ]]; then
    [[ ${WANT_PY} -eq 1 ]] && printf 'python  tests/%s\n' "${PY_TESTS[@]}"
    [[ ${WANT_JL} -eq 1 ]] && printf 'julia   tests/%s\n' "${JL_TESTS[@]}"
    [[ ${WANT_R}  -eq 1 ]] && printf 'R       tests/%s\n' "${R_TESTS[@]}"
    exit 0
fi

PASSED=0; FAILED=0; SKIPPED=0
FAILED_NAMES=(); SKIPPED_NAMES=()
LOG_DIR="$(mktemp -d)"

run_suite() {                       # run_suite <label> <cmd...>
    local label="$1"; shift
    local log="${LOG_DIR}/${label//\//_}.log"
    printf '  %-34s ' "${label}"
    if "$@" >"${log}" 2>&1; then
        # A harness that prints "N FAIL" with N>0 but exits 0 would slip through,
        # so check the text too rather than trusting the status alone.
        if grep -Eq '[1-9][0-9]* FAIL' "${log}"; then
            echo "FAIL   (nonzero FAIL count with a zero exit — read ${log})"
            FAILED=$((FAILED+1)); FAILED_NAMES+=("${label}")
        else
            echo "pass   $(grep -Eo '[0-9]+ PASS[^,]*' "${log}" | tail -1)"
            PASSED=$((PASSED+1))
        fi
    else
        local rc=$?
        echo "FAIL   (exit ${rc} — ${log})"
        FAILED=$((FAILED+1)); FAILED_NAMES+=("${label}")
    fi
}

skip_suite() {                      # skip_suite <label> <why>
    printf '  %-34s SKIPPED  %s\n' "$1" "$2"
    SKIPPED=$((SKIPPED+1)); SKIPPED_NAMES+=("$1 — $2")
}

echo "======================================================================"
echo "tests/run_tests.sh    ${PROJECT_ROOT}"
echo "======================================================================"

if [[ ${WANT_PY} -eq 1 ]]; then
    echo; echo "python"
    if command -v python3 >/dev/null 2>&1; then
        for t in "${PY_TESTS[@]}"; do run_suite "tests/${t}" python3 "tests/${t}"; done
    else
        for t in "${PY_TESTS[@]}"; do skip_suite "tests/${t}" "no python3 on PATH"; done
    fi
fi

if [[ ${WANT_JL} -eq 1 ]]; then
    echo; echo "julia"
    # The Julia suites are only meaningful inside the repo's pinned environment.
    # Manifest.toml is hopper's, resolved under the julia/1.8.0 that
    # sweep_task.slurm loads, and sweep_task.slurm hard-fails on any mismatch
    # (the 2026-08-13 fix). Running them under a different Julia is out of
    # contract: it produces failures that say nothing about this repo's code —
    # e.g. 1.12's world-age rules break test_assignment_rules.jl's
    # eval-extracted-source approach. Report that as SKIPPED with the reason
    # rather than as a red that invites a wild goose chase. SKIPPED is still
    # not green.
    PINNED_JL="$(grep -m1 '^julia_version' "${PROJECT_ROOT}/Manifest.toml" \
                 | sed 's/.*"\(.*\)"/\1/')"
    HAVE_JL="$(julia --version 2>/dev/null | awk '{print $3}')"
    if ! command -v julia >/dev/null 2>&1; then
        for t in "${JL_TESTS[@]}"; do skip_suite "tests/${t}" "no julia on PATH"; done
    elif [[ "${HAVE_JL%.*}" != "${PINNED_JL%.*}" ]]; then
        for t in "${JL_TESTS[@]}"; do
            skip_suite "tests/${t}" "julia ${HAVE_JL}, repo pins ${PINNED_JL} (run on hopper)"
        done
    elif ! julia --project="${PROJECT_ROOT}" -e \
            'using Distributions' >/dev/null 2>&1; then
        for t in "${JL_TESTS[@]}"; do
            skip_suite "tests/${t}" "project not instantiated (Pkg.instantiate())"
        done
    else
        for t in "${JL_TESTS[@]}"; do
            run_suite "tests/${t}" julia --project="${PROJECT_ROOT}" "tests/${t}"
        done
    fi
fi

if [[ ${WANT_R} -eq 1 ]]; then
    echo; echo "R"
    if ! command -v Rscript >/dev/null 2>&1; then
        for t in "${R_TESTS[@]}"; do skip_suite "tests/${t}" "no Rscript on PATH"; done
    elif ! Rscript -e 'quit(status = !requireNamespace("data.table", quietly = TRUE))' \
            >/dev/null 2>&1; then
        for t in "${R_TESTS[@]}"; do
            skip_suite "tests/${t}" "data.table not installed (./scripts/bootstrap_r_libs.sh)"
        done
    else
        for t in "${R_TESTS[@]}"; do run_suite "tests/${t}" Rscript "tests/${t}"; done
    fi
fi

echo
echo "======================================================================"
printf 'passed %d   failed %d   skipped %d\n' "${PASSED}" "${FAILED}" "${SKIPPED}"
echo "======================================================================"
for n in "${FAILED_NAMES[@]:-}";  do [[ -n "$n" ]] && echo "  FAILED   $n"; done
for n in "${SKIPPED_NAMES[@]:-}"; do [[ -n "$n" ]] && echo "  SKIPPED  $n"; done

if [[ ${FAILED} -gt 0 ]]; then
    echo; echo "🔴 Some suites failed. Logs in ${LOG_DIR}"
    exit 1
fi
if [[ ${SKIPPED} -gt 0 ]]; then
    echo
    echo "🟠 Everything that ran passed, but ${SKIPPED} suite(s) could not run, so this"
    echo "   is NOT a green result — an unrun suite proves nothing. Install the missing"
    echo "   toolchain, or re-run with --python / --julia / --r to state plainly which"
    echo "   subset you are claiming."
    exit 1
fi
echo; echo "✅ All ${PASSED} suites ran and passed."
rm -rf "${LOG_DIR}"
exit 0
