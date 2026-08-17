#!/usr/bin/env bash
# =============================================================================
# sweep_status.sh — at-a-glance progress and failure readout for running arms.
#
# Distinct from the other two checkers:
#   check_sweep_run.py   post-hoc verifier: did the tasks finish and land data?
#   check_recording.sh   acceptance gate for a single-cell smoke arm
#   sweep_status.sh      THIS — a mid-flight progress and failure monitor
#
# Usage:
#   ./scripts/sweep_status.sh                          # auto-discover arms in outputs/
#   ./scripts/sweep_status.sh production placebo       # named tags
#   ./scripts/sweep_status.sh --job-id 9392726 --job-id 9392770
#
# ⚠️ READ Elapsed, NOT State. A task that dies in 9 seconds and one that runs
# 52 minutes can both look plausible in the state column. This pipeline has
# produced both directions inside one week: three PASSes on a job that did
# nothing (2026-08-14), and a FAILED job with all 13 outputs on disk
# (2026-08-16). Anything far under the observed ~50-70 min did not do the work,
# whatever it says.
# =============================================================================
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Below this = suspiciously fast. Deliberately LOW (5 min), not "well under the
# smoke run's 51:48". Cell runtime varies a lot across the grid: low reserve
# means the bank fails early and the run ends, so a legitimate fast cell can
# finish in ~22 min (observed 2026-08-17, task_150 of the production arm, which
# produced a full complement of runs). Setting this near the smoke time would
# flag healthy cells and train the reader to ignore it. What it is really for
# is the unambiguous corpse: the 9-second and 59-second exits this pipeline has
# produced twice. Raise it with --short if you want a stricter sweep.
SHORT_RUN_SECS=${SHORT_RUN_SECS:-300}

TAGS=(); JOB_IDS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --job-id) JOB_IDS+=("$2"); shift 2 ;;
        --short)  SHORT_RUN_SECS="$2"; shift 2 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        -*) echo "unknown flag: $1" >&2; exit 2 ;;
        *)  TAGS+=("$1"); shift ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
if ! have squeue && ! have sacct; then
    echo "ERROR: neither squeue nor sacct found — run this on hopper, not locally." >&2
    exit 2
fi

# Auto-discover arms: any outputs/<tag>/ holding a manifest.
if [[ ${#TAGS[@]} -eq 0 && ${#JOB_IDS[@]} -eq 0 ]]; then
    while IFS= read -r m; do
        TAGS+=("$(basename "$(dirname "$m")")")
    done < <(find "${PROJECT_ROOT}/outputs" -mindepth 2 -maxdepth 2 \
                  -name manifest.csv 2>/dev/null | sort)
    [[ ${#TAGS[@]} -eq 0 ]] && { echo "No arms found under outputs/. Pass tags explicitly." >&2; exit 2; }
fi

# hhmmss / d-hh:mm:ss -> seconds
to_secs() {
    local t="$1" d=0
    [[ "$t" == *-* ]] && { d="${t%%-*}"; t="${t#*-}"; }
    local IFS=:; read -r a b c <<< "$t"
    if [[ -n "${c:-}" ]]; then echo $(( d*86400 + 10#$a*3600 + 10#$b*60 + 10#$c ))
    elif [[ -n "${b:-}" ]]; then echo $(( d*86400 + 10#$a*60 + 10#$b ))
    else echo $(( d*86400 + 10#${a:-0} )); fi
}

# Resolve tag -> array job id via the deterministic job name from run_all.sh.
jid_for_tag() {
    local tag="$1" j=""
    have squeue && j=$(squeue -u "$USER" -h -n "bankrun-${tag}-sweep" -o "%F" 2>/dev/null | head -1)
    if [[ -z "$j" ]] && have sacct; then
        j=$(sacct -u "$USER" -X -n --name="bankrun-${tag}-sweep" \
                  --starttime now-14days --format=JobID%20 2>/dev/null \
            | tr -d ' ' | sed 's/_.*//' | grep -E '^[0-9]+$' | tail -1)
    fi
    echo "$j"
}

report_arm() {
    local tag="$1" jid="$2"
    local arm_dir="${PROJECT_ROOT}/outputs/${tag}"

    echo "======================================================================"
    echo "ARM: ${tag}${jid:+   (array job ${jid})}"
    echo "======================================================================"

    # ── Expected cell count, from the manifest this arm was submitted with ────
    local expected=0
    if [[ -f "${arm_dir}/manifest.csv" ]]; then
        expected=$(( $(wc -l < "${arm_dir}/manifest.csv") - 1 ))
    fi

    # ── Queue state histogram ────────────────────────────────────────────────
    if [[ -n "$jid" ]] && have squeue; then
        echo "-- queue --"
        squeue -j "$jid" -h -t all -o "%T" 2>/dev/null | sort | uniq -c \
            | awk '{printf "   %-12s %s\n", $2, $1}'
        local pend
        pend=$(squeue -j "$jid" -h -t PENDING -o "%K" 2>/dev/null | head -1)
        [[ -n "$pend" ]] && echo "   pending range: ${pend}"
    fi

    # ── Terminal states from the accounting DB ───────────────────────────────
    local done_ct=0
    if [[ -n "$jid" ]] && have sacct; then
        echo "-- finished (sacct) --"
        sacct -X -j "$jid" -n --format=State%20 2>/dev/null \
            | awk '{print $1}' | sort | uniq -c \
            | awk '{printf "   %-14s %s\n", $2, $1}'
        done_ct=$(sacct -X -j "$jid" -n --state=COMPLETED --format=JobID 2>/dev/null | wc -l)

        # Failures, with Elapsed — the column that actually means something.
        local bad
        bad=$(sacct -X -j "$jid" -n \
                --state=FAILED,TIMEOUT,OUT_OF_MEMORY,NODE_FAIL,CANCELLED \
                --format=JobID%20,State%14,Elapsed%12,ExitCode%8 2>/dev/null)
        if [[ -n "$bad" ]]; then
            echo "-- FAILURES --"
            echo "$bad" | head -25 | sed 's/^/   /'
            local n; n=$(echo "$bad" | wc -l)
            [[ $n -gt 25 ]] && echo "   … and $((n - 25)) more"
        else
            echo "-- FAILURES --"
            echo "   none"
        fi

        # ⚠️ COMPLETED but implausibly fast. This is the check the State column
        # cannot give you, and the one this pipeline keeps needing.
        local fast=0
        while read -r id el; do
            [[ -z "${el:-}" ]] && continue
            [[ $(to_secs "$el") -lt $SHORT_RUN_SECS ]] && { fast=$((fast+1)); \
                [[ $fast -le 8 ]] && echo "   ⚠️  ${id} COMPLETED in ${el} — too fast to have done the work"; }
        done < <(sacct -X -j "$jid" -n --state=COMPLETED \
                       --format=JobID%20,Elapsed%12 2>/dev/null | awk '{print $1, $2}')
        if [[ $fast -gt 0 ]]; then
            echo "   ⚠️  ${fast} COMPLETED task(s) ran under $((SHORT_RUN_SECS/60)) min."
            echo "       A green state on a task that did nothing is this repo's"
            echo "       signature failure. Check its .err before trusting the arm."
        fi
    fi

    # ── What actually landed on disk ─────────────────────────────────────────
    echo "-- on disk --"
    local dirs=0 withdata=0
    if [[ -d "$arm_dir" ]]; then
        dirs=$(find "$arm_dir" -mindepth 1 -maxdepth 1 -type d -name 'task_*' 2>/dev/null | wc -l)
        withdata=$(find "$arm_dir" -mindepth 2 -maxdepth 2 -name 'bankRunResults*.csv' 2>/dev/null | wc -l)
    fi
    echo "   task dirs created      : ${dirs}"
    echo "   with an outcome file   : ${withdata}${expected:+  of ${expected} cells}"
    # ⚠️ sweep_task.slurm mkdir -p's TASK_DIR before Julia is invoked, so a task
    # directory existing proves only that SLURM started the task.
    if [[ $dirs -gt $withdata ]]; then
        echo "   NOTE $((dirs - withdata)) dirs have no outcome file yet — running, or died"
        echo "        before writing. An empty task dir is NOT evidence the model ran."
    fi

    if [[ $expected -gt 0 && $withdata -gt 0 ]]; then
        echo "   progress               : $(( 100 * withdata / expected ))%"
    fi
    echo
}

for i in "${!TAGS[@]}"; do
    tag="${TAGS[$i]}"
    jid="${JOB_IDS[$i]:-}"
    [[ -z "$jid" ]] && jid="$(jid_for_tag "$tag")"
    report_arm "$tag" "$jid"
done
# Job ids given without tags: report them without a disk view.
if [[ ${#TAGS[@]} -eq 0 ]]; then
    for jid in "${JOB_IDS[@]}"; do report_arm "(unknown tag)" "$jid"; done
fi

# ── The pairing check — the one that can invalidate the contrast ─────────────
# Everything above is about losing cells. This is about the cells not
# corresponding: analysis_p6b.R differences treatment against placebo cell by
# cell, so the two arms must have been generated from the identical grid.
if [[ ${#TAGS[@]} -ge 2 ]]; then
    echo "======================================================================"
    echo "PAIRING CHECK — must match for the P6b contrast to mean anything"
    echo "======================================================================"
    # Resolve params_sha by HEADER NAME, from a DATA row. An earlier version
    # grepped for the string 'params_sha' and took the next comma-field, which
    # matched the header line and returned the literal 'submitted_at' for every
    # arm — then declared them identical. A false green on the one check that
    # can invalidate the whole contrast. Parse properly, and refuse to compare
    # anything that does not look like a sha (run_all.sh writes 16 hex chars).
    sha_of() {
        local m="$1"
        awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="params_sha") c=i; next}
                 NR==2{if(c) print $c; exit}' "$m" 2>/dev/null
    }
    prev_sha=""; mismatch=0; unreadable=0; n_seen=0
    for tag in "${TAGS[@]}"; do
        m="${PROJECT_ROOT}/outputs/${tag}/manifest.csv"
        if [[ ! -f "$m" ]]; then
            echo "   ${tag}: no manifest yet — arm not submitted, or submitted --dry-run"
            unreadable=1; continue
        fi
        sha=$(sha_of "$m")
        if [[ ! "$sha" =~ ^[0-9a-f]{8,}$ ]]; then
            echo "   ${tag}: params_sha unreadable (got '${sha:-<empty>}')"
            unreadable=1; continue
        fi
        echo "   ${tag}: params_sha=${sha}"
        n_seen=$((n_seen + 1))
        [[ -n "$prev_sha" && "$sha" != "$prev_sha" ]] && mismatch=1
        prev_sha="$sha"
    done
    echo
    if [[ $mismatch -eq 1 ]]; then
        echo "   ❌ MISMATCH. The arms were generated from different grids, so cell N"
        echo "      in one is not cell N in the other. excess(treatment) - excess(placebo)"
        echo "      would difference unlike cells. Do not run the contrast."
    elif [[ $unreadable -eq 1 || $n_seen -lt 2 ]]; then
        echo "   ⚠️  NOT VERIFIED — fewer than two readable manifests. This is not a"
        echo "      pass. The contrast is only meaningful if both arms came from the"
        echo "      same grid, and that has not been established here."
    else
        echo "   ✅ identical across ${n_seen} arms — cells correspond, contrast is well-defined"
    fi
    echo
fi

echo "Next: python3 scripts/check_sweep_run.py --arm-dir outputs/<tag> \\"
echo "              --manifest outputs/<tag>/manifest.csv --job-id <arrayjobid>"
