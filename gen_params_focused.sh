#!/usr/bin/env bash
# gen_params_focused.sh — Focused parameter sweep for the critical region.
#
# Motivated by initial results:
#   - Reserve ratios 0.05/0.15 → 100% failure (no variation)
#   - Test run (higher reserve) → failure rates 40-85%, monotonically
#     decreasing in mu (individualist share)
#   - Non-monotonicity may emerge at intermediate reserve ratios where
#     dispersed individualist exit is survivable but coordinated
#     collectivist waves are not
#
# Design:
#   - Reserve ratios bracket the critical region (0.15-0.40)
#   - Deposit insurance varied to test the policy question
#   - Network structure: one focal value + one comparison
#   - Warm-up alpha: one focal + one comparison
#   - Cultural parameters: full mu sweep × lambda pairs
#   - 50 replications per combo (in finMain0001.jl via seedRun × runSize)
#
# Total: 6 × 3 × 2 × 2 × 2 × 5 × 3 = 2,160 parameter combinations
#
# Each line: reserve depq sigma k p warmupAlpha mu lambdaI lambdaC
#
# Run:
#   bash gen_params_focused.sh              # writes params_focused.txt
#   # Then update sweep.slurm to point to params_focused.txt
#   # and set --array=1-2160

set -euo pipefail

OUTPUT="${1:-params_focused.txt}"

# Reserve ratio: fine grid around the critical transition region
# 0.15 = known ~100% failure; 0.40 = likely low failure; 0.20-0.35 = critical region
RESERVE_RATIOS=(0.15 0.20 0.25 0.30 0.35 0.40)

# Deposit insurance quantile: tests the policy question
# 0.0 = no insurance; 0.2 = moderate; 0.5 = generous
DEP_QUANTILES=(0.0 0.2 0.5)

# Log-normal deposit heterogeneity: moderate and high skew
LOGN_SIGMAS=(2.0 3.0)

# Watts-Strogatz network: moderate connectivity with two rewiring levels
# k=6 = sparse local network; p=0.05 vs 0.15 = regular vs small-world
WS_KS=(6)
WS_PS=(0.05 0.15)

# Warm-up learning rate: affects cultural distribution endogeneity
# 0.1 = slow convergence (more heterogeneity); 0.5 = fast (more homogeneous)
WARMUP_ALPHAS=(0.1 0.5)

# Cultural composition: full sweep for non-monotonicity detection
MU_VALUES=(0.0 0.25 0.5 0.75 1.0)

# Lambda pairs: (lambdaI, lambdaC) controlling signal weighting
# Wide gap (0.1, 0.9): strong cultural differentiation
# Medium gap (0.2, 0.8): moderate
# Narrow gap (0.3, 0.5): weak differentiation
LAMBDA_I_VALUES=(0.1 0.2 0.3)
LAMBDA_C_VALUES=(0.9 0.8 0.5)

> "$OUTPUT"

for reserve in "${RESERVE_RATIOS[@]}"; do
  for depq in "${DEP_QUANTILES[@]}"; do
    for sigma in "${LOGN_SIGMAS[@]}"; do
      for k in "${WS_KS[@]}"; do
        for p in "${WS_PS[@]}"; do
          for alpha in "${WARMUP_ALPHAS[@]}"; do
            for mu in "${MU_VALUES[@]}"; do
              # Paired lambda values (not crossed — each pair is a
              # meaningful configuration, not an arbitrary combo)
              for i in $(seq 0 $((${#LAMBDA_I_VALUES[@]}-1))); do
                lambdaI="${LAMBDA_I_VALUES[$i]}"
                lambdaC="${LAMBDA_C_VALUES[$i]}"
                echo "$reserve $depq $sigma $k $p $alpha $mu $lambdaI $lambdaC"
              done
            done
          done
        done
      done
    done
  done
done >> "$OUTPUT"

TOTAL=$(wc -l < "$OUTPUT")
echo "Wrote $TOTAL parameter combinations to $OUTPUT"
echo ""
echo "Estimated compute:"
echo "  Each task runs seedRun=5 × runSize=10 = 50 replications"
echo "  Total simulations: $TOTAL × 50 = $((TOTAL * 50))"
echo ""
echo "To submit:"
echo "  1. Copy params_focused.txt to HPC"
echo "  2. Update sweep.slurm: PARAMS_FILE=...params_focused.txt"
echo "  3. Update sweep.slurm: --array=1-$TOTAL"
echo "  4. sbatch sweep.slurm"
