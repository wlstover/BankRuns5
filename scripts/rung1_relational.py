#!/usr/bin/env python3
"""Rung 1 (relational equivalence): Chapter 1's G1-G4 signs on the fire-sale bank (2026-10-22).

The statistics are fixed here before the rung-1 arms run (docs/rung1_prereg.md).
Unit: one run of a mixed cell (0 < mu < 1). For each type J, the endogenous
withdrawal rate W_J = nEndog_J / (n_J - nExog_J), the share of the type's agents
not hit by the shock who chose to withdraw; the sorting statistic is
D = W_I - W_C. The public signal's gap at tick 1, gap = y1 - theta
(consolidated_thetapublic.csv), says whether y was optimistic (gap > 0) or
pessimistic (gap < 0); failure is failType != none (consolidated_balance.csv).

  G1  optimistic y, bank fails:      mean D | gap > +g, failed        > 0
  G4  pessimistic y, bank survives:  mean D | gap < -g, survived      < 0
  G2  slope of D on gap (all runs)                                    > 0,
      and larger for a wider lambda-odds gap: b(0.1,0.9) > b(0.2,0.8) > b(0.3,0.5)
  G3  signals agree: run for run against an arm where y tracks theta
      (--agree), mean |D_arm| - |D_agree|                             > 0
  G1'/G4' channel-isolated: run for run against the arm with no public signal
      (--base), dD = D_arm - D_base, by the sign of the gap:
      mean dD | gap > +g  > 0,   mean dD | gap < -g  < 0.
      Chapter 1 has no head-count channel; in the ABM collectivists herd on
      withdrawn neighbours whatever y says (D < 0 at every theta with the private
      signal alone, phase 3 arms), which biases the level tests against G1. The
      paired difference removes that channel's contribution at the same bank,
      theta and shock.

Standard errors cluster on the initialisation (paramSeed): under
BANKRUN_SEEDING=common every cell and arm shares the same 25 banks. Arms
without a public signal (no thetapublic file) report only mean D by theta bin.

Usage:
    python3 scripts/rung1_relational.py outputs/r1t-* [--agree outputs/r1t-tracks-g0]
        [--gap 0.1] [--out outputs/r1t-analysis]
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

CELL = ["reserveRatio", "sigma", "mu", "lambdaI", "lambdaC"]


def load(arm_dir):
    arm_dir = Path(arm_dir)
    res = pd.read_csv(arm_dir / "consolidated_results.csv",
                      usecols=["task_id", "key", "paramSeed", "seed", "armTag"] + CELL)
    ty = pd.read_csv(arm_dir / "consolidated_types.csv",
                     usecols=["task_id", "key", "type", "n", "nExog", "nEndog"])
    ty["W"] = ty.nEndog / (ty.n - ty.nExog).where(ty.n > ty.nExog)
    w = ty.pivot_table(index=["task_id", "key"], columns="type", values="W").reset_index()
    if not {"I", "C"} <= set(w.columns):
        raise SystemExit(f"{arm_dir}: no mixed cells (types I and C both needed)")
    df = res.merge(w[["task_id", "key", "I", "C"]], on=["task_id", "key"], how="inner")
    df = df.rename(columns={"I": "W_I", "C": "W_C"})
    bal = pd.read_csv(arm_dir / "consolidated_balance.csv", usecols=["task_id", "key", "theta", "failType"])
    df = df.merge(bal, on=["task_id", "key"], how="inner")
    tp_path = arm_dir / "consolidated_thetapublic.csv"
    if tp_path.exists() and tp_path.stat().st_size > 0:
        tp = pd.read_csv(tp_path, usecols=["task_id", "key", "y1", "gap1"])
        df = df.merge(tp, on=["task_id", "key"], how="left")
    else:
        df["y1"], df["gap1"] = np.nan, np.nan
    df = df[(df.mu > 0) & (df.mu < 1)].copy()
    df["D"] = df.W_I - df.W_C
    df["failed"] = df.failType != "none"
    df["arm"] = arm_dir.name
    return df


def cluster_mean(x, g):
    """Mean of x and its standard error clustered on g."""
    x, g = np.asarray(x, float), np.asarray(g)
    n = len(x)
    if n < 2:
        return (x.mean() if n else np.nan), np.nan, n
    m = x.mean()
    s = pd.Series(x - m).groupby(g).sum().to_numpy()
    return m, np.sqrt((s ** 2).sum()) / n, n


def cluster_slope(y, x, g):
    """OLS slope of y on x with a cluster-robust (CR0) standard error."""
    y, x, g = np.asarray(y, float), np.asarray(x, float), np.asarray(g)
    if len(y) < 3 or np.var(x) == 0:
        return np.nan, np.nan
    X = np.column_stack([np.ones_like(x), x])
    XtX_inv = np.linalg.inv(X.T @ X)
    beta = XtX_inv @ X.T @ y
    u = y - X @ beta
    meat = np.zeros((2, 2))
    for _, idx in pd.Series(range(len(y))).groupby(g):
        sc = X[idx.to_numpy()].T @ u[idx.to_numpy()]
        meat += np.outer(sc, sc)
    V = XtX_inv @ meat @ XtX_inv
    return beta[1], np.sqrt(V[1, 1])


def g_stats(df, gap):
    rows = []
    for (arm, li, lc), d in df.groupby(["arm", "lambdaI", "lambdaC"]):
        r = {"arm": arm, "lambdaI": li, "lambdaC": lc, "runs": len(d),
             "P_fail": d.failed.mean()}
        if d.gap1.notna().any():
            for name, sel, sign in (("G1", (d.gap1 > gap) & d.failed, +1),
                                    ("G4", (d.gap1 < -gap) & ~d.failed, -1)):
                m, se, n = cluster_mean(d.D[sel], d.paramSeed[sel])
                r.update({f"{name}_D": m, f"{name}_se": se, f"{name}_n": n,
                          f"{name}_z": sign * m / se if se and se > 0 else np.nan})
            ok = d.gap1.notna()
            b, se = cluster_slope(d.D[ok], d.gap1[ok], d.paramSeed[ok])
            r.update({"G2_slope": b, "G2_se": se, "G2_z": b / se if se and se > 0 else np.nan})
        rows.append(r)
    return pd.DataFrame(rows)


def g3(df, agree):
    """Run for run against the agreeing arm: same cell, same (paramSeed, seed)."""
    keys = CELL + ["paramSeed", "seed"]
    a = agree[keys + ["D"]].rename(columns={"D": "D_agree"})
    rows = []
    for arm, d in df.groupby("arm"):
        if arm == agree.arm.iloc[0]:
            continue
        m = d.merge(a, on=keys, how="inner")
        diff = m.D.abs() - m.D_agree.abs()
        mean, se, n = cluster_mean(diff, m.paramSeed)
        rows.append({"arm": arm, "G3_absD_minus_agree": mean, "G3_se": se, "G3_pairs": n,
                     "G3_z": mean / se if se and se > 0 else np.nan})
    return pd.DataFrame(rows)


def base_diff(df, base, gap):
    """G1'/G4': run for run against the arm with no public signal, by gap sign."""
    keys = CELL + ["paramSeed", "seed"]
    b = base[keys + ["D"]].rename(columns={"D": "D_base"})
    rows = []
    for (arm, li, lc), d in df.groupby(["arm", "lambdaI", "lambdaC"]):
        if arm == base.arm.iloc[0] or not d.gap1.notna().any():
            continue
        m = d.merge(b, on=keys, how="inner")
        dd = m.D - m.D_base
        r = {"arm": arm, "lambdaI": li, "lambdaC": lc, "pairs": len(m)}
        for name, sel, sign in (("G1p", m.gap1 > gap, +1), ("G4p", m.gap1 < -gap, -1)):
            mean, se, n = cluster_mean(dd[sel], m.paramSeed[sel])
            r.update({f"{name}_dD": mean, f"{name}_se": se, f"{name}_n": n,
                      f"{name}_z": sign * mean / se if se and se > 0 else np.nan})
        rows.append(r)
    return pd.DataFrame(rows)


def theta_bins(df):
    bins = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    d = df.assign(theta_bin=pd.cut(df.theta, bins, include_lowest=True))
    return (d.groupby(["arm", "theta_bin"], observed=True)
             .agg(runs=("D", "size"), P_fail=("failed", "mean"), W_I=("W_I", "mean"),
                  W_C=("W_C", "mean"), D=("D", "mean")).reset_index())


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("arms", nargs="+")
    ap.add_argument("--agree", default=None, help="arm where y tracks theta (G3 reference)")
    ap.add_argument("--base", default=None, help="arm with no public signal (G1'/G4' reference)")
    ap.add_argument("--gap", type=float, default=0.1, help="|y1 - theta| above which y disagrees")
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()
    dfs = [load(p) for p in a.arms]
    df = pd.concat(dfs, ignore_index=True)
    pd.set_option("display.width", 200, "display.max_columns", 30)
    gs = g_stats(df, a.gap)
    print("G1 / G4 / G2 by arm and lambda pair (z signed so that > 0 supports the prediction)")
    print(gs.round(4).to_string(index=False))
    tb = theta_bins(df)
    print("\nMean withdrawal rates and D = W_I - W_C by theta bin")
    print(tb.round(3).to_string(index=False))
    out = {"g_stats": gs, "theta_bins": tb}
    if a.agree:
        ag = load(a.agree)
        g = g3(pd.concat([df, ag], ignore_index=True), ag)
        print("\nG3: mean |D| - |D_agree|, run for run")
        print(g.round(4).to_string(index=False))
        out["g3"] = g
    if a.base:
        bs = load(a.base)
        g = base_diff(pd.concat([df, bs], ignore_index=True), bs, a.gap)
        print("\nG1'/G4': dD = D_arm - D_base, run for run (z signed so that > 0 supports)")
        print(g.round(4).to_string(index=False))
        out["base_diff"] = g
    if a.out:
        a.out.mkdir(parents=True, exist_ok=True)
        for k, v in out.items():
            v.to_csv(a.out / f"rung1_{k}.csv", index=False)
        print(f"\nwrote {a.out}/rung1_*.csv")


if __name__ == "__main__":
    main()
