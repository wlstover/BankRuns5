#!/usr/bin/env bash
# gen_params.sh — Generate params.txt for the Hopper Slurm array sweep.
#
# Each line is one parameter combination passed to finMain0001.jl:
#   reserve  depq  sigma  k  p  warmupAlpha  mu  lambdaI  lambdaC
#
# Total lines: 2×4×2×3×2×3×5×3×3 = 12,960
#
# Run once before submitting the array job:
#   bash gen_params.sh          # writes params.txt to current directory

set -euo pipefail

OUTPUT="${1:-params.txt}"

RESERVE_RATIOS=(0.2 0.4)
DEP_QUANTILES=(0.1 0.2 0.3 0.4)
LOGN_SIGMAS=(2.0 3.0)
WS_KS=(6 10 50)
WS_PS=(0.05 0.15)
WARMUP_ALPHAS=(0.1 0.3 0.5)
MU_VALUES=(0.0 0.25 0.5 0.75 1.0)
LAMBDA_I_VALUES=(0.1 0.2 0.3)
LAMBDA_C_VALUES=(0.5 0.7 0.9)

> "$OUTPUT"   # truncate/create

for reserve in "${RESERVE_RATIOS[@]}"; do
  for depq in "${DEP_QUANTILES[@]}"; do
    for sigma in "${LOGN_SIGMAS[@]}"; do
      for k in "${WS_KS[@]}"; do
        for p in "${WS_PS[@]}"; do
          for alpha in "${WARMUP_ALPHAS[@]}"; do
            for mu in "${MU_VALUES[@]}"; do
              for lambdaI in "${LAMBDA_I_VALUES[@]}"; do
                for lambdaC in "${LAMBDA_C_VALUES[@]}"; do
                  echo "$reserve $depq $sigma $k $p $alpha $mu $lambdaI $lambdaC"
                done
              done
            done
          done
        done
      done
    done
  done
done >> "$OUTPUT"

echo "Wrote $(wc -l < "$OUTPUT") parameter combinations to $OUTPUT"
