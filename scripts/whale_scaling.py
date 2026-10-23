#!/usr/bin/env python3
"""The whale problem at N = 1,000 (2026-10-23; pilot_map F12e).

Two tables, by simulation of the bank's deposit draw (log-normal(1, sigma), as
modelGenTyped draws it; no model run):

  by_n:  at sigma 2.5, the largest depositor's share of deposits against N, and
         how often it exceeds 10% of the reference bank's period-1 capacity
         (r 0.05, d 0.6, e 0.06: 0.05 + 0.4 x 1.01 = 0.454 of deposits). Celsius
         (~541K users) had 0.94% (bank_runs_celsius deposit_concentration).
  banks: at N = 1,000, what lowering sigma or capping deposits (functions4.jl
         capDeposits) leaves of concentration: largest, top 1% and top 10% shares.

The run cost of one tick grows about as N^2 x depth (every banked agent decides,
each by `depth` sub-simulations over the deposit vector), so N cannot reach the
platform's size; an agent that stands for a cohort (super-individuals) can.

Usage:
    python3 scripts/whale_scaling.py [--out outputs/whale_scaling] [--reps 400]
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

CAPACITY = 0.05 + (1 - 0.6) * (1 - 0.05 + 0.06)


def cap_deposits(d, c):
    """functions4.jl capDeposits."""
    s = np.sort(d)[::-1]
    rest = s.sum()
    for k in range(1, len(s)):
        rest -= s[k - 1]
        level = c * rest / (1 - k * c)
        if s[k] <= level:
            return d if s[0] <= level else np.minimum(d, level)
    raise ValueError("infeasible cap")


def shares(d):
    s = np.sort(d)[::-1]
    t = s.sum()
    n = len(s)
    return s[0] / t, s[: max(1, n // 100)].sum() / t, s[: n // 10].sum() / t


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", type=Path, default=Path("outputs/whale_scaling"))
    ap.add_argument("--reps", type=int, default=400)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20261023)

    rows = []
    for n in (1_000, 3_000, 10_000, 30_000, 100_000, 541_000):
        reps = a.reps if n <= 30_000 else max(60, a.reps // 7)
        big = np.array([shares(rng.lognormal(1, 2.5, n))[0] for _ in range(reps)])
        rows.append(dict(N=n, reps=reps, largest_median=np.median(big),
                         largest_p90=np.quantile(big, 0.9),
                         p_largest_over_10pct_capacity=np.mean(big > 0.1 * CAPACITY),
                         relative_tick_cost=(n / 1_000) ** 2))
    by_n = pd.DataFrame(rows)

    rows = []
    for label, sigma, c in [("sigma 2.5", 2.5, 0), ("sigma 2.0", 2.0, 0), ("sigma 1.5", 1.5, 0),
                            ("sigma 1.25", 1.25, 0), ("sigma 1", 1.0, 0),
                            ("sigma 2.5, cap 1%", 2.5, 0.01), ("sigma 2.5, cap 2%", 2.5, 0.02)]:
        st = []
        for _ in range(a.reps):
            d = rng.lognormal(1, sigma, 1_000)
            d = cap_deposits(d, c) if c else d
            st.append(shares(d) + (np.sum(d >= d.max() * (1 - 1e-12)),))
        st = np.array(st)
        rows.append(dict(bank=label, largest=np.median(st[:, 0]), top1=np.median(st[:, 1]),
                         top10=np.median(st[:, 2]),
                         p_largest_over_10pct_capacity=np.mean(st[:, 0] > 0.1 * CAPACITY),
                         agents_at_max=np.median(st[:, 3])))
    banks = pd.DataFrame(rows)

    by_n.to_csv(a.out / "whale_by_n.csv", index=False)
    banks.to_csv(a.out / "whale_banks.csv", index=False)
    with pd.option_context("display.float_format", "{:.3f}".format, "display.width", 120):
        print(by_n.to_string(index=False)); print(); print(banks.to_string(index=False))
    print(f"\nwrote {a.out}/whale_by_n.csv, whale_banks.csv")


if __name__ == "__main__":
    main()
