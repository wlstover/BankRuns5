#!/usr/bin/env bash
set -euo pipefail

# Adjust these as needed
DATA_DIR="/mnt/c/Programming/papers/bank_run/BankRuns5/outputs"
JULIA_BIN="/snap/bin/julia"
PROJECT_DIR="/mnt/c/Programming/papers/bank_run/BankRuns5"

# Sweep definitions (short, overnight-friendly)
RESERVE_RATIOS=(0.2 0.4)
DEP_QUANTILES=(0.1 0.2 0.3 0.4)
DIST_NAME="LogNormal"
LOGN_MU=1.0
LOGN_SIGMAS=(2.0 3.0)
WS_KS=(6 10 50)
WS_PS=(0.05 0.15)
# Warm-up learning rate sweep: controls cultural homogenisation speed.
# Low α → slow convergence → more heterogeneous warm-up λ distribution.
# High α → fast convergence → sharper cultural cluster structure.
WARMUP_ALPHAS=(0.1 0.3 0.5)

# Two-type population parameters: {μ, λ_I, λ_C} — all swept independently.
#
# MU_VALUES (μ): fraction of agents assigned type I (individualists).
#   Tracing the bank-run probability curve across μ recovers the fixed-point
#   prediction: s*_I = θ − λ_I·f(μ·Φ(s*_I) + (1−μ)·Φ(s*_C))
#               s*_C = θ − λ_C·f(μ·Φ(s*_I) + (1−μ)·Φ(s*_C))
#
# LAMBDA_I_VALUES (λ_I): mean of individualist Beta; lower → more self-reliant.
# LAMBDA_C_VALUES (λ_C): mean of collectivist Beta;  higher → more signal-driven.
#
# Ranges are non-overlapping (max λ_I = 0.3 < min λ_C = 0.5) so λ_I < λ_C
# holds for every combination.  The non-monotonicity of bank-run probability
# in μ depends on the gap λ_C − λ_I, hence the independent sweep.
MU_VALUES=(0.0 0.25 0.5 0.75 1.0)
LAMBDA_I_VALUES=(0.1 0.2 0.3)
LAMBDA_C_VALUES=(0.5 0.7 0.9)

# Starting seed for parameter generation (incremented each job)
GEN_SEED=1001

for reserve in "${RESERVE_RATIOS[@]}"; do
  for depq in "${DEP_QUANTILES[@]}"; do
    for sigma in "${LOGN_SIGMAS[@]}"; do
      for k in "${WS_KS[@]}"; do
        for p in "${WS_PS[@]}"; do
          for alpha in "${WARMUP_ALPHAS[@]}"; do
            for mu in "${MU_VALUES[@]}"; do
              for lambdaI in "${LAMBDA_I_VALUES[@]}"; do
                for lambdaC in "${LAMBDA_C_VALUES[@]}"; do
                  echo "Running reserve=$reserve depq=$depq sigma=$sigma k=$k p=$p warmupAlpha=$alpha mu=$mu lambdaI=$lambdaI lambdaC=$lambdaC seed=$GEN_SEED"
                  "$JULIA_BIN" --project="$PROJECT_DIR" "$PROJECT_DIR/finMain0001.jl" \
                    "$DATA_DIR" \
                    "$GEN_SEED" \
                    "$reserve" \
                    "$depq" \
                    "$DIST_NAME" \
                    "$LOGN_MU" \
                    "$sigma" \
                    "$k" \
                    "$p" \
                    "$alpha" \
                    "$mu" \
                    "$lambdaI" \
                    "$lambdaC"
                  GEN_SEED=$((GEN_SEED + 1))
                done
              done
            done
          done
        done
      done
    done
  done
done
