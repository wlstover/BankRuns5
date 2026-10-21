#!/bin/bash
# run_arms.sh — submit a set of arms from one file (2026-10-20).
#
# Each arm is one run_all.sh call with its own tag, BANKRUN_* switches and
# run_all.sh flags. Writing the set down in a file (arms/<name>.tsv, tracked)
# means the design of a crossed experiment lives in the repo rather than in a
# shell history, and every arm is fully specified by its row: the wrapper
# refuses to start if the calling shell already exports a model switch, and
# each arm runs in a subshell so one row's switches cannot leak into the next.
#
# File format: tab-separated, '#' comments and blank lines ignored.
#   tag <TAB> switches <TAB> run_all.sh flags
#   switches: space-separated NAME=value, NAME a BANKRUN_* variable, or '-' for none
#   flags:    passed to run_all.sh after --tag (grid, axes, --time, ...), or '-'
# Example row:
#   r1-shock-stale	BANKRUN_PRIVATE_SIGNAL=shock BANKRUN_PUBLIC_MODE=stale	--grid reference-r3 --time 0-02:00:00
#
# Usage:
#   scripts/run_arms.sh arms/rung1_relational.tsv --dry-run      # ALWAYS first
#   scripts/run_arms.sh arms/rung1_relational.tsv                # submit every arm
#   scripts/run_arms.sh arms/rung1_relational.tsv --only r1-shock-stale [--dry-run]
#   scripts/run_arms.sh arms/rung1_relational.tsv --list
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARMS_FILE="${1:?usage: run_arms.sh ARMS.tsv [--dry-run] [--only TAG ...] [--list]}"; shift
[[ -f "$ARMS_FILE" ]] || { echo "ERROR: $ARMS_FILE not found" >&2; exit 1; }

DRY=(); ONLY=(); LIST=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=(--dry-run); shift ;;
        --only)    ONLY+=("$2"); shift 2 ;;
        --list)    LIST=1; shift ;;
        *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

# The calling shell must not carry model switches: they would reach every arm
# through run_all.sh's --export=ALL without appearing in the arms file.
for n in $(bash "$HERE/switch_names.sh" --model); do
    v="BANKRUN_${n}"
    if [[ -n "${!v:-}" ]]; then
        echo "ERROR: ${v}=${!v} is set in this shell; unset it, or put it in the arms file." >&2; exit 1
    fi
done
# Output-only switches (BANKRUN_LOG) do not change the model, so they are not
# refused, but they too reach every arm without appearing in the arms file.
MODEL_SW=" $(bash "$HERE/switch_names.sh" --model | tr '\n' ' ') "
for n in $(bash "$HERE/switch_names.sh"); do
    [[ "$MODEL_SW" == *" $n "* ]] && continue
    v="BANKRUN_${n}"
    if [[ -n "${!v:-}" ]]; then
        echo "WARNING: ${v}=${!v} is set in this shell and applies to every arm unless an arm sets it." >&2
    fi
done
KNOWN=" $(bash "$HERE/switch_names.sh" | sed 's/^/BANKRUN_/' | tr '\n' ' ') "

declare -a TAGS=() SWITCHES=() FLAGS=()
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    IFS=$'\t' read -r tag sw fl <<< "$line"
    [[ -n "${tag:-}" ]] || { echo "ERROR: $ARMS_FILE:$lineno has no tag" >&2; exit 1; }
    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: $ARMS_FILE:$lineno: bad tag '$tag'" >&2; exit 1; }
    for t in "${TAGS[@]:-}"; do
        [[ "$t" == "$tag" ]] && { echo "ERROR: $ARMS_FILE:$lineno: duplicate tag '$tag'" >&2; exit 1; }
    done
    sw="${sw:--}"; fl="${fl:--}"
    if [[ "$sw" != "-" ]]; then
        for kv in $sw; do
            name="${kv%%=*}"
            [[ "$kv" == *=* ]] || { echo "ERROR: $ARMS_FILE:$lineno: '$kv' is not NAME=value" >&2; exit 1; }
            [[ "$KNOWN" == *" $name "* ]] || {
                echo "ERROR: $ARMS_FILE:$lineno: '$name' is not a switch in settings.jl" >&2; exit 1; }
        done
    fi
    [[ " $fl " == *" --tag "* ]] && { echo "ERROR: $ARMS_FILE:$lineno: the tag column sets --tag" >&2; exit 1; }
    TAGS+=("$tag"); SWITCHES+=("$sw"); FLAGS+=("$fl")
done < "$ARMS_FILE"

[[ ${#TAGS[@]} -gt 0 ]] || { echo "ERROR: no arms in $ARMS_FILE" >&2; exit 1; }
for o in "${ONLY[@]:-}"; do
    [[ -z "$o" ]] && continue
    found=0; for t in "${TAGS[@]}"; do [[ "$t" == "$o" ]] && found=1; done
    [[ $found -eq 1 ]] || { echo "ERROR: --only '$o' is not a tag in $ARMS_FILE" >&2; exit 1; }
done

for i in "${!TAGS[@]}"; do
    tag="${TAGS[$i]}"; sw="${SWITCHES[$i]}"; fl="${FLAGS[$i]}"
    if [[ ${#ONLY[@]} -gt 0 ]]; then
        keep=0; for o in "${ONLY[@]}"; do [[ "$o" == "$tag" ]] && keep=1; done
        [[ $keep -eq 1 ]] || continue
    fi
    if [[ $LIST -eq 1 ]]; then
        printf '%-28s %-60s %s\n' "$tag" "$sw" "$fl"; continue
    fi
    echo "======================================================================"
    echo "arm ${tag}:  switches [${sw}]  flags [${fl}]"
    (
        if [[ "$sw" != "-" ]]; then for kv in $sw; do export "$kv"; done; fi
        # shellcheck disable=SC2086
        if [[ "$fl" == "-" ]]; then
            bash "$HERE/run_all.sh" --tag "$tag" "${DRY[@]}"
        else
            bash "$HERE/run_all.sh" --tag "$tag" $fl "${DRY[@]}"
        fi
    )
done
