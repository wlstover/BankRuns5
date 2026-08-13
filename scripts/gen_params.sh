#!/usr/bin/env bash
# =============================================================================
# gen_params.sh — parameter-file generator for the BankRuns5 sweep.
#
# Merges the two hand-maintained generators that preceded it (the repo-root
# gen_params.sh "full" grid and gen_params_focused.sh "focused" grid) into one
# entry point that takes axis overrides as arguments. run_all.sh calls this to
# materialise a params file per arm; it is also usable standalone.
#
# Each output line is one parameter combination, consumed positionally by
# sweep_task.slurm → finMain0001.jl:
#
#     reserve  depq  sigma  k  p  warmupAlpha  mu  lambdaI  lambdaC
#
# Usage:
#   bash scripts/gen_params.sh                                  # focused grid (2,160)
#   bash scripts/gen_params.sh --grid full                      # full grid (12,960)
#   bash scripts/gen_params.sh --k 6 10 50 -o params_density.txt # override one axis
#   bash scripts/gen_params.sh --reserve 0.25 0.30 --count-only  # just the cell count
#
# Axis flags (each takes one or more values, terminated by the next --flag):
#   --reserve  --depq  --sigma  --k  --p  --alpha  --mu  --lambda-i  --lambda-c
#
# --lambda-mode paired|crossed
#   paired  (focused default) zips lambda-i with lambda-c: (0.1,0.9) (0.2,0.8)
#           (0.3,0.5) — three signal-weighting GAPS, wide/medium/narrow. This is
#           what makes the focused grid 2,160 rather than 6,480.
#   crossed (full default) takes the full 3x3 product.
#   In paired mode the two lambda arrays must be the same length.
#
# ⚠️ The loop nesting order is load-bearing: it fixes the mapping from SLURM
# array index to parameter combination. Existing outputs/task_<N>/ directories
# are keyed by that index, so changing the nesting silently re-labels every
# result already on disk. Do not reorder these loops.
# =============================================================================

set -euo pipefail

GRID="focused"
OUTPUT=""
COUNT_ONLY=0
LAMBDA_MODE=""

# Axis overrides start empty; unset axes fall back to the grid defaults below.
declare -a RESERVE_RATIOS=() DEP_QUANTILES=() LOGN_SIGMAS=() WS_KS=() WS_PS=()
declare -a WARMUP_ALPHAS=() MU_VALUES=() LAMBDA_I_VALUES=() LAMBDA_C_VALUES=()

ARGS=("$@")
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    arg="${ARGS[$i]}"
    case "$arg" in
        --grid)        GRID="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
        -o|--out)      OUTPUT="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
        --lambda-mode) LAMBDA_MODE="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
        --count-only)  COUNT_ONLY=1; i=$((i+1)) ;;
        --reserve|--depq|--sigma|--k|--p|--alpha|--mu|--lambda-i|--lambda-c)
            case "$arg" in
                --reserve)  name=RESERVE_RATIOS ;;
                --depq)     name=DEP_QUANTILES ;;
                --sigma)    name=LOGN_SIGMAS ;;
                --k)        name=WS_KS ;;
                --p)        name=WS_PS ;;
                --alpha)    name=WARMUP_ALPHAS ;;
                --mu)       name=MU_VALUES ;;
                --lambda-i) name=LAMBDA_I_VALUES ;;
                --lambda-c) name=LAMBDA_C_VALUES ;;
            esac
            # Stop at ANY dash-led token, not just --long ones: a bare `-o`
            # after an axis list would otherwise be swallowed as a value and the
            # grid would come out silently wrong.
            j=$((i+1)); vals=()
            while [[ $j -lt ${#ARGS[@]} ]] && [[ "${ARGS[$j]}" != -* ]]; do
                vals+=("${ARGS[$j]}"); j=$((j+1))
            done
            if [[ ${#vals[@]} -eq 0 ]]; then
                echo "ERROR: $arg needs at least one value" >&2; exit 1
            fi
            eval "$name=(\"\${vals[@]}\")"
            i=$j ;;
        -h|--help)
            sed -n '2,40p' "$0"; exit 0 ;;
        *)
            echo "ERROR: unknown argument '$arg'" >&2
            echo "       (an unknown flag here would otherwise produce a silently wrong grid)" >&2
            exit 1 ;;
    esac
done

# ── Grid defaults ─────────────────────────────────────────────────────────────
# Applied only to axes the caller did not override.
case "$GRID" in
    focused)
        # Focused grid. Motivation (from gen_params_focused.sh): reserve ratios
        # 0.05/0.15 gave ~100% failure with no variation, so the grid brackets
        # the critical transition region 0.15-0.40 instead.
        def_reserve=(0.15 0.20 0.25 0.30 0.35 0.40)
        def_depq=(0.0 0.2 0.5)
        def_sigma=(2.0 3.0)
        def_k=(6)
        def_p=(0.05 0.15)
        def_alpha=(0.1 0.5)
        def_mu=(0.0 0.25 0.5 0.75 1.0)
        def_lambda_i=(0.1 0.2 0.3)
        def_lambda_c=(0.9 0.8 0.5)
        def_lambda_mode="paired"
        ;;
    full)
        # Original full factorial: 2x4x2x3x2x3x5x3x3 = 12,960.
        def_reserve=(0.2 0.4)
        def_depq=(0.1 0.2 0.3 0.4)
        def_sigma=(2.0 3.0)
        def_k=(6 10 50)
        def_p=(0.05 0.15)
        def_alpha=(0.1 0.3 0.5)
        def_mu=(0.0 0.25 0.5 0.75 1.0)
        def_lambda_i=(0.1 0.2 0.3)
        def_lambda_c=(0.5 0.7 0.9)
        def_lambda_mode="crossed"
        ;;
    *)
        echo "ERROR: --grid must be 'focused' or 'full' (got '$GRID')" >&2; exit 1 ;;
esac

[[ ${#RESERVE_RATIOS[@]}  -eq 0 ]] && RESERVE_RATIOS=("${def_reserve[@]}")
[[ ${#DEP_QUANTILES[@]}   -eq 0 ]] && DEP_QUANTILES=("${def_depq[@]}")
[[ ${#LOGN_SIGMAS[@]}     -eq 0 ]] && LOGN_SIGMAS=("${def_sigma[@]}")
[[ ${#WS_KS[@]}           -eq 0 ]] && WS_KS=("${def_k[@]}")
[[ ${#WS_PS[@]}           -eq 0 ]] && WS_PS=("${def_p[@]}")
[[ ${#WARMUP_ALPHAS[@]}   -eq 0 ]] && WARMUP_ALPHAS=("${def_alpha[@]}")
[[ ${#MU_VALUES[@]}       -eq 0 ]] && MU_VALUES=("${def_mu[@]}")
[[ ${#LAMBDA_I_VALUES[@]} -eq 0 ]] && LAMBDA_I_VALUES=("${def_lambda_i[@]}")
[[ ${#LAMBDA_C_VALUES[@]} -eq 0 ]] && LAMBDA_C_VALUES=("${def_lambda_c[@]}")
[[ -z "$LAMBDA_MODE" ]] && LAMBDA_MODE="$def_lambda_mode"

case "$LAMBDA_MODE" in
    paired)
        if [[ ${#LAMBDA_I_VALUES[@]} -ne ${#LAMBDA_C_VALUES[@]} ]]; then
            echo "ERROR: --lambda-mode paired needs equal-length --lambda-i and --lambda-c" >&2
            echo "       got ${#LAMBDA_I_VALUES[@]} and ${#LAMBDA_C_VALUES[@]}" >&2
            exit 1
        fi ;;
    crossed) ;;
    *) echo "ERROR: --lambda-mode must be 'paired' or 'crossed'" >&2; exit 1 ;;
esac

# λ_I < λ_C must hold for every combination the model runs — the whole two-type
# framework assumes individualists weight the social signal LESS. Check it here
# rather than discovering it in a sweep that already burned CPU-days.
if [[ "$LAMBDA_MODE" == "paired" ]]; then
    for idx in "${!LAMBDA_I_VALUES[@]}"; do
        li="${LAMBDA_I_VALUES[$idx]}"; lc="${LAMBDA_C_VALUES[$idx]}"
        awk -v a="$li" -v b="$lc" 'BEGIN{exit !(a<b)}' || {
            echo "ERROR: lambda pair ($li, $lc) violates lambda_I < lambda_C" >&2; exit 1; }
    done
else
    max_i=$(printf '%s\n' "${LAMBDA_I_VALUES[@]}" | sort -g | tail -1)
    min_c=$(printf '%s\n' "${LAMBDA_C_VALUES[@]}" | sort -g | head -1)
    awk -v a="$max_i" -v b="$min_c" 'BEGIN{exit !(a<b)}' || {
        echo "ERROR: max lambda_I ($max_i) >= min lambda_C ($min_c); ranges must not overlap" >&2
        exit 1; }
fi

# ── Emit ──────────────────────────────────────────────────────────────────────
emit() {
for reserve in "${RESERVE_RATIOS[@]}"; do
  for depq in "${DEP_QUANTILES[@]}"; do
    for sigma in "${LOGN_SIGMAS[@]}"; do
      for k in "${WS_KS[@]}"; do
        for p in "${WS_PS[@]}"; do
          for alpha in "${WARMUP_ALPHAS[@]}"; do
            for mu in "${MU_VALUES[@]}"; do
              if [[ "$LAMBDA_MODE" == "paired" ]]; then
                for idx in "${!LAMBDA_I_VALUES[@]}"; do
                  echo "$reserve $depq $sigma $k $p $alpha $mu ${LAMBDA_I_VALUES[$idx]} ${LAMBDA_C_VALUES[$idx]}"
                done
              else
                for lambdaI in "${LAMBDA_I_VALUES[@]}"; do
                  for lambdaC in "${LAMBDA_C_VALUES[@]}"; do
                    echo "$reserve $depq $sigma $k $p $alpha $mu $lambdaI $lambdaC"
                  done
                done
              fi
            done
          done
        done
      done
    done
  done
done
}

if [[ $COUNT_ONLY -eq 1 ]]; then
    emit | wc -l
    exit 0
fi

if [[ -z "$OUTPUT" ]]; then
    OUTPUT="params_${GRID}.txt"
fi

emit > "$OUTPUT"

TOTAL=$(wc -l < "$OUTPUT")
echo "Wrote $TOTAL parameter combinations to $OUTPUT"
echo "  grid=$GRID  lambda-mode=$LAMBDA_MODE"
echo "  reserve=[${RESERVE_RATIOS[*]}]  depq=[${DEP_QUANTILES[*]}]  sigma=[${LOGN_SIGMAS[*]}]"
echo "  k=[${WS_KS[*]}]  p=[${WS_PS[*]}]  alpha=[${WARMUP_ALPHAS[*]}]  mu=[${MU_VALUES[*]}]"
echo "  lambdaI=[${LAMBDA_I_VALUES[*]}]  lambdaC=[${LAMBDA_C_VALUES[*]}]"
