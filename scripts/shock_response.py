#!/usr/bin/env python3
"""Does the run respond to the shock? P(run) and who runs, by shock size (2026-10-20).

The Phase 2 gate of the Ch 3 build-out: Chapter 1's mapping needs the agents'
signals to be about the fundamental, so in an arm with an informative private
signal (BANKRUN_PRIVATE_SIGNAL=shock) P(run) must rise with the realised shock.
In production (uninformative prior draws) it barely does: with no exogenous
withdrawer at all, P(run) is still 0.85 at r = 0.15 and 0.22 at r = 0.40.

For each arm directory given, by reserve ratio x bin of n_exog (the number of
exogenous withdrawers in the run):
  runs, P(run) = mean(bankRun), mean drain share, and (mixed mu only) the
  endogenous withdrawal rate of type I minus type C.
Then, per arm and reserve ratio, the OLS slope of bankRun on n_exog (per 10
agents) with its standard error, the one-number summary the gate reads.

n_exog comes from consolidated_dock.csv when present (arms written since
2026-10-20), else from consolidated_types.csv (nExog summed over types).

Usage:
    python3 scripts/shock_response.py outputs/production-v2 [outputs/<arm> ...]
        [--bins 0 1 4 8 13 21] [--out <dir>]
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

DEFAULT_BINS = [0, 1, 4, 8, 13, 21]   # lower edges: 0, 1-3, 4-7, 8-12, 13-20, 21+


def load(arm_dir):
    arm_dir = Path(arm_dir)
    res = pd.read_csv(arm_dir / "consolidated_results.csv",
                      usecols=["task_id", "key", "reserveRatio", "mu", "lambdaI", "lambdaC",
                               "bankRun", "drainShare"])
    res = res[res.bankRun.astype(str).str.lower().isin(["true", "false"])].copy()
    res["run"] = res.bankRun.astype(str).str.lower().eq("true").astype(float)
    dock = arm_dir / "consolidated_dock.csv"
    types = pd.read_csv(arm_dir / "consolidated_types.csv",
                        usecols=["task_id", "key", "type", "n", "nExog", "nEndog"])
    if dock.exists() and dock.stat().st_size > 0:
        d = pd.read_csv(dock, usecols=["task_id", "key", "nExog"])
        if len(d):
            res = res.merge(d, on=["task_id", "key"], how="inner")
            src = "consolidated_dock.csv"
        else:
            dock = None
    if not (dock and dock.exists()) or "nExog" not in res:
        ne = types.groupby(["task_id", "key"], as_index=False).nExog.sum()
        res = res.merge(ne, on=["task_id", "key"], how="inner")
        src = "consolidated_types.csv"
    # endogenous withdrawal rate per type, among the non-exogenous agents
    types["rate"] = types.nEndog / (types.n - types.nExog).where(lambda x: x > 0)
    w = types.pivot_table(index=["task_id", "key"], columns="type", values="rate").reset_index()
    if {"I", "C"} <= set(w.columns):
        w["IminusC"] = w["I"] - w["C"]
        res = res.merge(w[["task_id", "key", "IminusC"]], on=["task_id", "key"], how="left")
    else:
        res["IminusC"] = np.nan
    return res, src


def label_bins(edges):
    labs = []
    for i, lo in enumerate(edges):
        hi = edges[i + 1] - 1 if i + 1 < len(edges) else None
        labs.append(f"{lo}" if hi == lo else (f"{lo}+" if hi is None else f"{lo}-{hi}"))
    return labs


def slope(x, y):
    x = np.asarray(x, float); y = np.asarray(y, float)
    if len(x) < 3 or np.var(x) == 0:
        return np.nan, np.nan
    X = np.column_stack([np.ones_like(x), x])
    b, *_ = np.linalg.lstsq(X, y, rcond=None)
    u = y - X @ b
    # heteroskedasticity-robust (HC1) standard error of the slope
    XtX_inv = np.linalg.inv(X.T @ X)
    meat = (X * u[:, None]).T @ (X * u[:, None])
    V = XtX_inv @ meat @ XtX_inv * len(x) / (len(x) - 2)
    return b[1], np.sqrt(V[1, 1])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("arm_dirs", nargs="+")
    ap.add_argument("--bins", nargs="+", type=int, default=DEFAULT_BINS,
                    help="lower edges of the n_exog bins (default 0 1 4 8 13 21)")
    ap.add_argument("--out", default=None, help="write shock_response_{bins,slopes}.csv here")
    a = ap.parse_args(argv)
    edges = sorted(set(a.bins))
    labs = label_bins(edges)

    bin_rows, slope_rows = [], []
    for arm in a.arm_dirs:
        df, src = load(arm)
        tag = Path(arm).name
        df["bin"] = pd.cut(df.nExog, bins=edges + [np.inf], right=False, labels=labs)
        mixed = (df.mu > 0) & (df.mu < 1)
        print(f"\n== {tag}  ({len(df):,} runs; n_exog from {src})")
        for r, g in df.groupby("reserveRatio"):
            b = g.groupby("bin", observed=True).agg(runs=("run", "size"), p_run=("run", "mean"),
                                                    drain=("drainShare", "mean"))
            ic = g[mixed.loc[g.index]].groupby("bin", observed=True).IminusC.mean()
            b["IminusC_mixed"] = ic
            sl, se = slope(g.nExog / 10.0, g.run)
            print(f"  r = {r}:  slope of P(run) per 10 exogenous withdrawers = {sl:+.4f} (se {se:.4f})")
            print("    " + b.round(3).to_string().replace("\n", "\n    "))
            for lab, row in b.iterrows():
                bin_rows.append(dict(arm=tag, reserveRatio=r, bin=lab, **row.to_dict()))
            slope_rows.append(dict(arm=tag, reserveRatio=r, slope_per10=sl, se=se, runs=len(g)))

    if a.out:
        out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
        pd.DataFrame(bin_rows).to_csv(out / "shock_response_bins.csv", index=False)
        pd.DataFrame(slope_rows).to_csv(out / "shock_response_slopes.csv", index=False)
        print(f"\nwrote {out}/shock_response_{{bins,slopes}}.csv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
