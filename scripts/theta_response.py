#!/usr/bin/env python3
"""Does the run respond to the fundamental? P(run) by θ, per arm (2026-10-21).

The phase 2 gate redesigned for the fire-sale bank (docs/pilot_map.md F8). The
shock-size signal could only reassure, because every decision state already
contains the shock. With BANKRUN_FUNDAMENTAL=theta the bank has an unobserved
fundamental: θ ~ U[0,1] per run sets the long asset's return, and with
BANKRUN_PRIVATE_SIGNAL=theta each agent sees x_i = θ + s·Z_i. The gate passes
when P(run) falls with θ more steeply as s shrinks.

For each arm directory (consolidated_results.csv plus consolidated_balance.csv),
by bin of θ: runs, P(run), the share of failures that are liquidity failures
(the bank sold everything and still could not pay in period 1) vs insolvency
(period 2), mean withdrawers, and the share of runs in which the largest
depositor withdrew. Then per arm the OLS slope of bankRun on θ with its
standard error. With a reference arm (the first, or --ref), arms are also
compared run for run on (paramSeed, seed), which share θ by construction.

Usage:
    python3 scripts/theta_response.py outputs/p3-s25-none outputs/p3-s25-theta-s05 ...
        [--bins 0 0.1 0.2 0.3 0.4 0.5 0.7 1.0] [--ref <arm>] [--out <dir>]
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

DEFAULT_BINS = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 1.0]


def load(arm_dir):
    arm_dir = Path(arm_dir)
    res = pd.read_csv(arm_dir / "consolidated_results.csv",
                      usecols=["task_id", "key", "paramSeed", "seed", "reserveRatio", "sigma",
                               "bankRun", "nWithdrawn"])
    res = res[res.bankRun.astype(str).str.lower().isin(["true", "false"])].copy()
    res["run"] = res.bankRun.astype(str).str.lower().eq("true").astype(float)
    bal_path = arm_dir / "consolidated_balance.csv"
    if not bal_path.exists():
        sys.exit(f"ERROR: {bal_path} not found; is {arm_dir} a fire-sale arm consolidated since 2026-10-21?")
    bal = pd.read_csv(bal_path, usecols=["task_id", "key", "theta", "failType", "largestWithdrew",
                                         "largestToCapacity"])
    if bal.empty:
        sys.exit(f"ERROR: {bal_path} has no rows; the arm did not run the fire-sale bank")
    df = res.merge(bal, on=["task_id", "key"], how="inner")
    df["largestWithdrew"] = df.largestWithdrew.astype(str).str.lower().eq("true")
    return df


def slope(df):
    x, y = df.theta.to_numpy(), df.run.to_numpy()
    if len(df) < 3 or np.ptp(x) == 0:
        return np.nan, np.nan
    X = np.column_stack([np.ones_like(x), x])
    beta, *_ = np.linalg.lstsq(X, y, rcond=None)
    resid = y - X @ beta
    s2 = resid @ resid / (len(y) - 2)
    se = np.sqrt(s2 * np.linalg.inv(X.T @ X)[1, 1])
    return beta[1], se


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("arms", nargs="+")
    ap.add_argument("--bins", type=float, nargs="+", default=DEFAULT_BINS)
    ap.add_argument("--ref", default=None, help="arm for run-for-run comparisons (default: the first)")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()
    bins = sorted(set(a.bins) | {0.0, 1.0})
    data = {Path(p).name: load(p) for p in a.arms}
    ref = Path(a.ref).name if a.ref else Path(a.arms[0]).name
    if ref not in data:
        sys.exit(f"ERROR: --ref {ref} is not one of the arms")

    bin_rows, slope_rows = [], []
    for name, df in data.items():
        df = df.copy()
        df["bin"] = pd.cut(df.theta, bins, include_lowest=True)
        t = df.groupby("bin", observed=True).agg(
            runs=("run", "size"), p_run=("run", "mean"),
            liquidity=("failType", lambda s: (s == "liquidity").sum()),
            insolvency=("failType", lambda s: (s == "insolvency").sum()),
            withdrawers=("nWithdrawn", "mean"), largest_withdrew=("largestWithdrew", "mean"))
        b, se = slope(df)
        print(f"\n== {name}  ({len(df)} runs; P(run) {df.run.mean():.3f}; "
              f"slope of P(run) in θ = {b:+.3f} (se {se:.3f}))")
        print(t.round(3).to_string())
        t = t.reset_index(); t.insert(0, "arm", name); bin_rows.append(t)
        slope_rows.append({"arm": name, "runs": len(df), "p_run": df.run.mean(),
                           "slope_theta": b, "se": se,
                           "liquidity_share_of_failures":
                               (df.failType == "liquidity").sum() / max(1, (df.failType != "none").sum())})

    base = data[ref]
    for name, df in data.items():
        if name == ref:
            continue
        j = base.merge(df, on=["paramSeed", "seed"], suffixes=("_ref", ""))
        if not np.allclose(j.theta_ref, j.theta):
            print(f"\nWARNING: {name} and {ref} do not share θ run for run; not paired")
            continue
        up = int(((j.run_ref == 0) & (j.run == 1)).sum()); down = int(((j.run_ref == 1) & (j.run == 0)).sum())
        print(f"\npaired {name} vs {ref} ({len(j)} runs): no run -> run {up}, run -> no run {down}, "
              f"mean change in withdrawers {(j.nWithdrawn - j.nWithdrawn_ref).mean():+.2f}")

    if a.out:
        a.out.mkdir(parents=True, exist_ok=True)
        pd.concat(bin_rows).to_csv(a.out / "theta_response_bins.csv", index=False)
        pd.DataFrame(slope_rows).to_csv(a.out / "theta_response_slopes.csv", index=False)
        print(f"\nwrote {a.out}/theta_response_{{bins,slopes}}.csv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
