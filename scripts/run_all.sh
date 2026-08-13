#!/bin/bash
# =============================================================================
# run_all.sh — SLURM orchestrator for the BankRuns5 agent-based model.
#
# Ported from celsius/scripts/run_all.sh (Chapter 1) so both chapters share one
# operational design: one argument-driven entry point, per-variant job-name
# tagging, variant switches threaded through --export, and dependent chaser jobs
# that verify and post-process every submission.
#
# Usage:
#   ./scripts/run_all.sh                                   # focused grid, production arm
#   ./scripts/run_all.sh --dry-run                         # print the sbatch calls, submit nothing
#   ./scripts/run_all.sh --grid full --tag full-grid       # the 12,960-cell design
#   ./scripts/run_all.sh --k 6 10 50 --tag p6b-density     # re-test P6b on denser networks
#   ./scripts/run_all.sh --assignment random --tag placebo # culture-vs-topology placebo
#   ./scripts/run_all.sh --tag production --restart        # top up under-filled cells
#   ./scripts/run_all.sh --consolidate --analyze --tag production   # post-processing only
#
# Axis overrides (passed straight to gen_params.sh, which validates them):
#   --reserve  --depq  --sigma  --k  --p  --alpha  --mu  --lambda-i  --lambda-c
#   --lambda-mode paired|crossed
#
# --depth N  Monte Carlo draws per agent decision (default 100).
#   Lowered from the model's original 1000 on 2026-08-13. This is a modelling
#   parameter, not only a speed knob: the decision rule compares two Bernoulli
#   means over N draws, so the MC standard error scales as 1/sqrt(N) — ~0.016 at
#   1000 against ~0.050 at 100. Marginal agents flip more often at low depth.
#   The 2026-04 production sweep ran at 1000; do not pool across depths. Depth is
#   recorded in the manifest and in the parameter dump.
#
# ── ARM ISOLATION ────────────────────────────────────────────────────────────
# Every arm writes to outputs/<tag>/task_<N>/ and tags every job name with
# <tag>. The 2,160 legacy directories at outputs/task_* (the 2026-04 production
# sweep) are NEVER written to by this script — they are read-only history that
# consolidate_results.py still picks up as the "legacy" arm.
#
# This is the ABM analogue of Chapter 1's -purpose / -withcoll tagging, and it
# exists for the same reason: a variant run that overwrites its own baseline
# destroys the attribution the variant was launched to measure.
#
# ── ⚠️ WHAT --restart ACTUALLY DOES ──────────────────────────────────────────
# It is a TOP-UP, not a resume. restart.jl is not wired in (finMain0001.jl:90
# has the include commented out), so a re-submitted task runs parameterGen.jl
# again, draws fresh seeds, and APPENDS a new 50-run block to whatever the task
# already holds. Those runs are valid draws — they are simply extra
# replications, not a continuation. This is the mechanism behind the ~6x
# replication surplus in the 2026-04 sweep (612 runs/cell against a documented
# 50). check_sweep_run.py reports the surplus rather than hiding it.
#
# Logs: /scratch/$USER/bankrun-<tag>-<stage>-%A_%a.out
# Watch: squeue -u $USER
# =============================================================================

#SBATCH --job-name=bankrun-run-all
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=0-00:10:00
#SBATCH --output=/scratch/%u/%x-%j.out
#SBATCH --error=/scratch/%u/%x-%j.err
#SBATCH --export=ALL

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
PROJECT_ROOT="${BANKRUN_PROJECT_ROOT:-/projects/tstratma/BankRuns5}"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts"

# ── Defaults ──────────────────────────────────────────────────────────────────
GRID="focused"
TAG=""
ASSIGN_RULE="warmup"
MC_DEPTH=100            # Monte Carlo draws per agent decision; see finMain0001.jl
PARAMS_FILE=""
CONCURRENCY=50
WALLTIME="0-08:00:00"
CPUS=16
MEM="32G"
SEED_OFFSET=1000
DRY_RUN=0
DO_SWEEP=1
DO_CONSOLIDATE=1
DO_ANALYZE=1
DO_CHECK=1
RESTART=0
STAGE_ONLY=0            # set when --consolidate/--analyze given without a sweep
AXIS_ARGS=()            # forwarded verbatim to gen_params.sh

VALID_ASSIGN="warmup random reverse"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --grid)         GRID="$2"; shift 2 ;;
        --tag)          TAG="$2"; shift 2 ;;
        --params-file)  PARAMS_FILE="$2"; shift 2 ;;
        --assignment)
            ASSIGN_RULE="$2"
            valid=0
            for v in $VALID_ASSIGN; do [[ "$ASSIGN_RULE" == "$v" ]] && valid=1; done
            if [[ $valid -eq 0 ]]; then
                echo "ERROR: --assignment must be one of: $VALID_ASSIGN" >&2; exit 1
            fi
            shift 2 ;;
        --depth)
            MC_DEPTH="$2"
            if ! [[ "$MC_DEPTH" =~ ^[0-9]+$ ]] || [[ "$MC_DEPTH" -lt 1 ]]; then
                echo "ERROR: --depth must be a positive integer" >&2; exit 1
            fi
            shift 2 ;;
        --concurrency)  CONCURRENCY="$2"; shift 2 ;;
        --time)         WALLTIME="$2"; shift 2 ;;
        --cpus)         CPUS="$2"; shift 2 ;;
        --mem)          MEM="$2"; shift 2 ;;
        --seed-offset)  SEED_OFFSET="$2"; shift 2 ;;
        --restart)      RESTART=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --no-sweep)     DO_SWEEP=0; shift ;;
        --no-consolidate) DO_CONSOLIDATE=0; shift ;;
        --no-analyze)   DO_ANALYZE=0; shift ;;
        --no-check)     DO_CHECK=0; shift ;;
        --consolidate)  STAGE_ONLY=1; DO_CONSOLIDATE=1; shift ;;
        --analyze)      STAGE_ONLY=1; DO_ANALYZE=1; shift ;;
        # Axis overrides — forwarded to gen_params.sh, which owns their validation.
        --reserve|--depq|--sigma|--k|--p|--alpha|--mu|--lambda-i|--lambda-c)
            AXIS_ARGS+=("$1"); shift
            # Any dash-led token ends the value list (see gen_params.sh).
            while [[ $# -gt 0 ]] && [[ "$1" != -* ]]; do
                AXIS_ARGS+=("$1"); shift
            done ;;
        --lambda-mode)  AXIS_ARGS+=("$1" "$2"); shift 2 ;;
        -h|--help)      sed -n '2,45p' "$0"; exit 0 ;;
        *)
            echo "ERROR: unknown argument '$1'" >&2
            echo "       An unrecognised flag kills this wrapper at parse time and no" >&2
            echo "       job is created, so check /scratch/\$USER for the error. See --help." >&2
            exit 1 ;;
    esac
done

# --consolidate / --analyze alone mean "post-process an existing arm".
if [[ $STAGE_ONLY -eq 1 ]]; then
    DO_SWEEP=0
    DO_CHECK=0
fi

# ── Arm naming ────────────────────────────────────────────────────────────────
# A non-default arm MUST be tagged. Without this an axis override or a placebo
# run would land in outputs/production/ beside the baseline and be
# indistinguishable from it after the fact.
if [[ -z "$TAG" ]]; then
    if [[ ${#AXIS_ARGS[@]} -gt 0 ]] || [[ "$ASSIGN_RULE" != "warmup" ]] || [[ "$GRID" != "focused" ]]; then
        echo "ERROR: --tag is required for any non-default arm." >&2
        echo "       You passed: grid=$GRID assignment=$ASSIGN_RULE axes=[${AXIS_ARGS[*]:-none}]" >&2
        echo "       Untagged output would be indistinguishable from the production baseline." >&2
        exit 1
    fi
    TAG="production"
fi

if [[ ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "ERROR: --tag must be alphanumeric with . _ - only (it becomes a directory name)" >&2
    exit 1
fi

ARM_DIR="${PROJECT_ROOT}/outputs/${TAG}"
MANIFEST="${ARM_DIR}/manifest.csv"

# The legacy sweep lives at outputs/task_*. Refuse to alias it.
if [[ "$TAG" == "task" ]] || [[ "$TAG" == task_* ]]; then
    echo "ERROR: tag '$TAG' would collide with the legacy outputs/task_* directories" >&2
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
SUBMITTED_JIDS=()

run_or_echo() {
    # Submits and returns the job id, or prints the command under --dry-run.
    if [[ $DRY_RUN -eq 1 ]]; then
        # Command goes to stderr so the caller's $(...) captures only the fake
        # job id — otherwise SWEEP_JID would swallow the whole sbatch line and
        # the dependency flags below would be silently malformed.
        {
            printf '  [dry-run] '
            printf '%q ' "$@"
            printf '\n'
        } >&2
        echo "DRYRUN${RANDOM}"
        return 0
    fi
    "$@" | awk '{print $NF}'
}

note() { echo "  $*"; }

# ── Params file ───────────────────────────────────────────────────────────────
# Generated per arm and kept beside the outputs, so the grid that produced a set
# of results is always recoverable from the results directory itself.
if [[ $DO_SWEEP -eq 1 ]]; then
    if [[ -z "$PARAMS_FILE" ]]; then
        PARAMS_FILE="${ARM_DIR}/params.txt"
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[dry-run] would generate ${PARAMS_FILE}:"
            bash "${SCRIPTS_DIR}/gen_params.sh" --grid "$GRID" "${AXIS_ARGS[@]}" --count-only \
                | sed 's/^/  cells: /'
        else
            mkdir -p "$ARM_DIR"
            bash "${SCRIPTS_DIR}/gen_params.sh" --grid "$GRID" "${AXIS_ARGS[@]}" -o "$PARAMS_FILE"
        fi
    else
        if [[ ! -f "$PARAMS_FILE" ]]; then
            echo "ERROR: --params-file '$PARAMS_FILE' not found" >&2; exit 1
        fi
        [[ ${#AXIS_ARGS[@]} -gt 0 ]] && {
            echo "ERROR: --params-file and axis overrides are mutually exclusive" >&2; exit 1; }
    fi

    if [[ $DRY_RUN -eq 1 ]] && [[ ! -f "$PARAMS_FILE" ]]; then
        NCELLS=$(bash "${SCRIPTS_DIR}/gen_params.sh" --grid "$GRID" "${AXIS_ARGS[@]}" --count-only)
    else
        NCELLS=$(wc -l < "$PARAMS_FILE")
    fi

    if [[ "$NCELLS" -lt 1 ]]; then
        echo "ERROR: params file is empty" >&2; exit 1
    fi
fi

# ── Array spec (full run, or only the deficient cells under --restart) ────────
# Expected runs per cell = seedRun x runSize = 5 x 10 = 50 (parameterGen.jl:40-42).
EXPECTED_RUNS_PER_CELL=50

compress_ranges() {
    # 1,2,3,7,9,10 -> 1-3,7,9-10 ; keeps the --array spec inside SLURM's length limit
    awk 'BEGIN{RS="[,\n ]+"} $1!=""{print $1+0}' | sort -n | uniq | awk '
        NR==1 {start=$1; prev=$1; next}
        $1==prev+1 {prev=$1; next}
        {printf "%s%s", (out++ ? "," : ""), (start==prev ? start : start "-" prev); start=$1; prev=$1}
        END {if (NR) printf "%s%s\n", (out++ ? "," : ""), (start==prev ? start : start "-" prev)}'
}

ARRAY_SPEC=""
if [[ $DO_SWEEP -eq 1 ]]; then
    if [[ $RESTART -eq 1 ]]; then
        if [[ ! -d "$ARM_DIR" ]]; then
            echo "ERROR: --restart on arm '$TAG' but ${ARM_DIR} does not exist" >&2; exit 1
        fi
        deficient=()
        for idx in $(seq 1 "$NCELLS"); do
            tdir="${ARM_DIR}/task_${idx}"
            if [[ ! -d "$tdir" ]]; then
                deficient+=("$idx"); continue
            fi
            nres=$(cat "${tdir}"/bankRunResults*.csv 2>/dev/null | wc -l || echo 0)
            if [[ "$nres" -lt "$EXPECTED_RUNS_PER_CELL" ]]; then
                deficient+=("$idx")
            fi
        done
        if [[ ${#deficient[@]} -eq 0 ]]; then
            echo "All ${NCELLS} cells in arm '${TAG}' have >= ${EXPECTED_RUNS_PER_CELL} runs. Nothing to restart."
            DO_SWEEP=0
        else
            ARRAY_SPEC=$(printf '%s\n' "${deficient[@]}" | compress_ranges)
            echo "⚠️  --restart: ${#deficient[@]} of ${NCELLS} cells under ${EXPECTED_RUNS_PER_CELL} runs."
            echo "    This APPENDS a fresh ${EXPECTED_RUNS_PER_CELL}-run block to each (restart.jl is"
            echo "    not wired in — see the header). Under-filled cells become over-filled."
        fi
    else
        ARRAY_SPEC="1-${NCELLS}"
    fi
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo "======================================================================"
echo "BankRuns5 sweep orchestrator"
echo "  arm tag:      ${TAG}"
echo "  output root:  ${ARM_DIR}"
echo "  assignment:   ${ASSIGN_RULE}"
echo "  MC depth:     ${MC_DEPTH}"
if [[ $DO_SWEEP -eq 1 ]]; then
echo "  grid:         ${GRID}  (${NCELLS} cells)"
echo "  params file:  ${PARAMS_FILE}"
echo "  array:        ${ARRAY_SPEC}%${CONCURRENCY}"
echo "  per task:     ${CPUS} CPUs, ${MEM}, ${WALLTIME}"
[[ ${#AXIS_ARGS[@]} -gt 0 ]] && echo "  overrides:    ${AXIS_ARGS[*]}"
else
echo "  sweep:        skipped (post-processing only)"
fi
[[ $DRY_RUN -eq 1 ]] && echo "  MODE:         DRY RUN — nothing will be submitted"
echo "======================================================================"

# ── Manifest ──────────────────────────────────────────────────────────────────
# One row per array index with the full parameter tuple, so consolidation joins
# on task_id instead of parsing the headerless Julia dump positionally. That
# positional parse is what mislabelled k/p/r/q in the 2026-04 sweep; keying on a
# manifest written at submission time removes the whole failure class.
if [[ $DO_SWEEP -eq 1 ]] && [[ $DRY_RUN -eq 0 ]]; then
    params_sha=$(sha256sum "$PARAMS_FILE" | cut -c1-16)
    submitted_at=$(date -Is)
    {
        echo "task_id,reserve,depq,sigma,k,p,alpha,mu,lambdaI,lambdaC,arm_tag,assign_rule,mc_depth,seed_offset,params_sha,submitted_at"
        awk -v tag="$TAG" -v rule="$ASSIGN_RULE" -v depth="$MC_DEPTH" \
            -v off="$SEED_OFFSET" -v sha="$params_sha" -v ts="$submitted_at" \
            '{printf "%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", \
              NR,$1,$2,$3,$4,$5,$6,$7,$8,$9,tag,rule,depth,off,sha,ts}' "$PARAMS_FILE"
    } > "$MANIFEST"
    note "manifest: ${MANIFEST} ($(($(wc -l < "$MANIFEST") - 1)) rows, params sha ${params_sha})"
elif [[ $DO_SWEEP -eq 1 ]]; then
    note "[dry-run] would write manifest to ${MANIFEST}"
fi

# ── Stage 1: the sweep array ──────────────────────────────────────────────────
SWEEP_JID=""
if [[ $DO_SWEEP -eq 1 ]]; then
    jobname="bankrun-${TAG}-sweep"
    SWEEP_JID=$(run_or_echo sbatch --parsable \
        --job-name="${jobname}" \
        --partition=normal \
        --array="${ARRAY_SPEC}%${CONCURRENCY}" \
        --ntasks=1 \
        --cpus-per-task="${CPUS}" \
        --mem="${MEM}" \
        --time="${WALLTIME}" \
        --output="/scratch/%u/${jobname}-%A_%a.out" \
        --error="/scratch/%u/${jobname}-%A_%a.err" \
        --export=ALL,PROJECT_ROOT="${PROJECT_ROOT}",PARAMS_FILE="${PARAMS_FILE}",ARM_DIR="${ARM_DIR}",ARM_TAG="${TAG}",BANKRUN_ASSIGN_RULE="${ASSIGN_RULE}",BANKRUN_MC_DEPTH="${MC_DEPTH}",SEED_OFFSET="${SEED_OFFSET}" \
        "${SCRIPTS_DIR}/sweep_task.slurm")
    SUBMITTED_JIDS+=("${SWEEP_JID}")
    echo ""
    echo "Submitted ${jobname}  →  job ${SWEEP_JID}  (array ${ARRAY_SPEC}%${CONCURRENCY})"
fi

# ── Stage 2: verifier chaser ──────────────────────────────────────────────────
# afterany, not afterok: the failure mode this catches is TIMEOUT, which is
# exactly when the sweep job does NOT exit clean. Gating on afterok would skip
# the check on precisely the runs that need it.
if [[ $DO_CHECK -eq 1 ]] && [[ -n "$SWEEP_JID" ]]; then
    jobname="bankrun-${TAG}-check"
    check_jid=$(run_or_echo sbatch --parsable \
        --job-name="${jobname}" \
        --partition=normal \
        --nodes=1 --cpus-per-task=1 --mem=8G --time="0-00:30:00" \
        --output="/scratch/%u/${jobname}-%j.out" \
        --error="/scratch/%u/${jobname}-%j.err" \
        --export=ALL \
        --dependency=afterany:"${SWEEP_JID}" \
        --chdir="${PROJECT_ROOT}" \
        --wrap="module load gnu10/10.3.0-ya && module load python/3.10.1-5r && \
                python3 ${SCRIPTS_DIR}/check_sweep_run.py --arm-dir '${ARM_DIR}' \
                        --manifest '${MANIFEST}' --job-id ${SWEEP_JID}")
    echo "Submitted ${jobname}      →  job ${check_jid}  (afterany:${SWEEP_JID})"
    note "goes RED only on FAIL — read it before quoting any number from this arm"
fi

# ── Stage 3: consolidate ──────────────────────────────────────────────────────
CONS_JID=""
if [[ $DO_CONSOLIDATE -eq 1 ]]; then
    jobname="bankrun-${TAG}-consolidate"
    dep_flag=()
    [[ -n "$SWEEP_JID" ]] && dep_flag=(--dependency=afterany:"${SWEEP_JID}")
    CONS_JID=$(run_or_echo sbatch --parsable \
        --job-name="${jobname}" \
        --partition=normal \
        --nodes=1 --cpus-per-task=2 --mem=16G --time="0-02:00:00" \
        --output="/scratch/%u/${jobname}-%j.out" \
        --error="/scratch/%u/${jobname}-%j.err" \
        --export=ALL \
        "${dep_flag[@]}" \
        --chdir="${PROJECT_ROOT}" \
        --wrap="module load gnu10/10.3.0-ya && module load python/3.10.1-5r && \
                python3 ${PROJECT_ROOT}/consolidate_results.py --arm-dir '${ARM_DIR}' \
                        --manifest '${MANIFEST}' \
                        --out '${ARM_DIR}/consolidated_results.csv'")
    SUBMITTED_JIDS+=("${CONS_JID}")
    echo "Submitted ${jobname} →  job ${CONS_JID}${SWEEP_JID:+  (afterany:${SWEEP_JID})}"
fi

# ── Stage 4: analysis ─────────────────────────────────────────────────────────
# afterok here (unlike the stages above): analysis on a consolidation that
# failed produces plausible-looking figures from a truncated CSV, which is worse
# than no figures at all.
if [[ $DO_ANALYZE -eq 1 ]]; then
    jobname="bankrun-${TAG}-analysis"
    dep_flag=()
    [[ -n "$CONS_JID" ]] && dep_flag=(--dependency=afterok:"${CONS_JID}")
    an_jid=$(run_or_echo sbatch --parsable \
        --job-name="${jobname}" \
        --partition=normal \
        --nodes=1 --cpus-per-task=4 --mem=16G --time="0-01:00:00" \
        --output="/scratch/%u/${jobname}-%j.out" \
        --error="/scratch/%u/${jobname}-%j.err" \
        --export=ALL,BANKRUN_PROJECT_ROOT="${PROJECT_ROOT}",BANKRUN_ARM_DIR="${ARM_DIR}" \
        "${dep_flag[@]}" \
        --chdir="${PROJECT_ROOT}" \
        "${SCRIPTS_DIR}/run_analysis.slurm")
    echo "Submitted ${jobname}    →  job ${an_jid}${CONS_JID:+  (afterok:${CONS_JID})}"
fi

echo ""
echo "======================================================================"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY RUN — nothing submitted."
else
    echo "Submitted. Monitor: squeue -u \$USER"
    echo "Arm outputs:   ${ARM_DIR}"
    echo "⚠️  SLURM State is not a completion signal for the sweep — a TIMEOUT"
    echo "    task leaves partial output. Read the check job's report."
fi
echo "======================================================================"
