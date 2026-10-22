#!/usr/bin/env python3
"""Rung 1 (relational equivalence): Chapter 1's G1-G4 signs on the fire-sale bank (2026-10-22).

The statistics and the decision rule are fixed here before the rung-1 arms run
(docs/rung1_prereg.md; decisions by the user, 2026-10-22).

Unit: one run of a mixed cell (0 < mu < 1). For each type J, W_J = nEndog_J /
(n_J - nExog_J), the share of the type's agents not hit by the shock who chose
to withdraw over the run, and D = W_I - W_C (head count, primary). D$ is the
same with deposits, W$_J = depEndog_J / (depTotal_J - depExog_J) (secondary).
gap = y1 - theta (consolidated_thetapublic.csv): > 0 means y was optimistic.
Runs are paired across arms and cells on (cell, paramSeed, seed): under
BANKRUN_SEEDING=common they share the bank, theta and the shock.

Confirmatory family (one-sided; each pooled over the 3 lambda pairs; Holm):
  G1'  mean (D_stale - D_base) | gap > +g             > 0
  G4'  mean (D_stale - D_base) | gap < -g             < 0
  G2a' slope of D on y0 within run (run fixed effect),
       the same run in the stale arms (y0 = 0.2 / 0.5 / 0.8)   > 0
  G3   mean |D_stale| - |D_agree| run for run          > 0
Inference: standard errors clustered on the initialisation (paramSeed, 25
clusters) with the CR1 factor G/(G-1); p-values from t(G-1). Each hypothesis is
reported per lambda pair as well; a pair significantly signed the wrong way
(one-sided p < 0.05, unadjusted) counts against it. G2b: the per-pair G2a'
slopes should order b(0.1,0.9) > b(0.2,0.8) > b(0.3,0.5).
Reported, not tested: D$ versions; G1' split by whether the bank fails in the
base arm; g robustness; levels G1 (mean D | gap > g, failed) and G4 (mean D |
gap < -g, survived) per arm; G2c (mean D among failed runs by y0); D by theta.

Usage:
    python3 scripts/rung1_relational.py --base outputs/r1t-none \\
        --agree outputs/r1t-tracks-g0 \\
        --stale outputs/r1t-stale-y20 outputs/r1t-stale-y50 outputs/r1t-stale-y80 \\
        [--other outputs/r1t-tracks-g20 outputs/r1t-corrects-y80-r50 ...] \\
        [--gap 0.1] [--out outputs/r1t-analysis]
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

CELL = ["reserveRatio", "sigma", "mu", "lambdaI", "lambdaC"]
PAIR = CELL + ["paramSeed", "seed"]
LAMBDA_ORDER = [(0.1, 0.9), (0.2, 0.8), (0.3, 0.5)]
SE_FLOOR = 1e-12   # below this the statistic is identically 0 up to rounding: no test


# ------------------------------------------------------------------ data

def load(arm_dir):
    arm_dir = Path(arm_dir)
    res = pd.read_csv(arm_dir / "consolidated_results.csv",
                      usecols=["task_id", "key", "paramSeed", "seed"] + CELL)
    ty = pd.read_csv(arm_dir / "consolidated_types.csv",
                     usecols=["task_id", "key", "type", "n", "nExog", "nEndog",
                              "depTotal", "depExog", "depEndog"])
    ty["W"] = ty.nEndog / (ty.n - ty.nExog).where(ty.n > ty.nExog)
    ty["Wd"] = ty.depEndog / (ty.depTotal - ty.depExog).where(ty.depTotal > ty.depExog)
    w = ty.pivot_table(index=["task_id", "key"], columns="type", values=["W", "Wd"])
    w.columns = [f"{a}_{b}" for a, b in w.columns]
    w = w.reset_index()
    if not {"W_I", "W_C"} <= set(w.columns):
        raise SystemExit(f"{arm_dir}: no mixed cells (types I and C both needed)")
    df = res.merge(w, on=["task_id", "key"], how="inner")
    bal = pd.read_csv(arm_dir / "consolidated_balance.csv",
                      usecols=["task_id", "key", "theta", "failType"])
    df = df.merge(bal, on=["task_id", "key"], how="inner")
    tp_path = arm_dir / "consolidated_thetapublic.csv"
    if tp_path.exists() and tp_path.stat().st_size > 0:
        tp = pd.read_csv(tp_path, usecols=["task_id", "key", "y1", "gap1"])
        df = df.merge(tp, on=["task_id", "key"], how="left")
    else:
        df["y1"], df["gap1"] = np.nan, np.nan
    df = df[(df.mu > 0) & (df.mu < 1)].copy()
    df["D"] = df.W_I - df.W_C
    df["Dd"] = df.Wd_I - df.Wd_C
    df["failed"] = df.failType != "none"
    df["arm"] = arm_dir.name
    return df


def paired(arm, ref, cols, suffix):
    r = ref[PAIR + cols].rename(columns={c: c + suffix for c in cols})
    return arm.merge(r, on=PAIR, how="inner")


# ------------------------------------------------------------------ inference

def _p(t, df, sign):
    """One-sided p-value for sign * estimate > 0."""
    return float(stats.t.sf(sign * t, df)) if np.isfinite(t) else np.nan


def cmean(x, g, sign):
    """Mean, CR1 cluster SE, t, one-sided p (direction `sign`), n, clusters."""
    x, g = np.asarray(x, float), np.asarray(g)
    n, G = len(x), len(np.unique(g))
    if n < 2 or G < 2:
        return dict(est=x.mean() if n else np.nan, se=np.nan, t=np.nan, p=np.nan, n=n, G=G)
    m = x.mean()
    s = pd.Series(x - m).groupby(g).sum().to_numpy()
    se = np.sqrt((s ** 2).sum() * G / (G - 1)) / n
    t = m / se if se > SE_FLOOR else np.nan
    return dict(est=m, se=se, t=t, p=_p(t, G - 1, sign), n=n, G=G)


def fe_slope(y, x, unit, g, sign):
    """Slope of y on x with a fixed effect per unit; CR1 cluster SE on g."""
    d = pd.DataFrame({"y": y, "x": x, "u": unit, "g": g}).dropna()
    d = d[d.groupby("u").x.transform("nunique") > 1]
    n, G = len(d), d.g.nunique()
    if n < 3 or G < 2:
        return dict(est=np.nan, se=np.nan, t=np.nan, p=np.nan, n=n, G=G)
    xt = d.x - d.groupby("u").x.transform("mean")
    yt = d.y - d.groupby("u").y.transform("mean")
    sxx = (xt ** 2).sum()
    b = (xt * yt).sum() / sxx
    score = (xt * (yt - b * xt)).groupby(d.g).sum().to_numpy()
    se = np.sqrt((score ** 2).sum() * G / (G - 1)) / sxx
    t = b / se if se > SE_FLOOR else np.nan
    return dict(est=b, se=se, t=t, p=_p(t, G - 1, sign), n=n, G=G)


def holm(ps, alpha=0.05):
    """Holm step-down: list of (reject, adjusted p) in input order."""
    ps = np.asarray(ps, float)
    order = np.argsort(ps)
    m = len(ps)
    adj = np.empty(m)
    running = 0.0
    for k, i in enumerate(order):
        running = max(running, min(1.0, (m - k) * ps[i]))
        adj[i] = running
    return [(a <= alpha, a) for a in adj]


# ------------------------------------------------------------------ tests

def tests(stale, base, agree, gap, col):
    """The four confirmatory statistics on outcome `col` (D or Dd), pooled and per lambda pair."""
    sb = paired(stale, base, [col, "failed"], "_base")
    sb["dD"] = sb[col] - sb[col + "_base"]
    sa = paired(stale, agree, [col], "_agree")
    sa["dAbs"] = sa[col].abs() - sa[col + "_agree"].abs()
    stale = stale.assign(run=stale[PAIR].astype(str).agg("|".join, axis=1))

    def four(f_sb, f_sa, f_st):
        o = sb[f_sb]; a = sa[f_sa]; s = stale[f_st]
        return {
            "G1'": cmean(o.dD[o.gap1 > gap], o.paramSeed[o.gap1 > gap], +1),
            "G4'": cmean(o.dD[o.gap1 < -gap], o.paramSeed[o.gap1 < -gap], -1),
            "G2a'": fe_slope(s[col], s.y1, s.run, s.paramSeed, +1),
            "G3": cmean(a.dAbs, a.paramSeed, +1),
        }

    rows = []
    for h, r in four(slice(None), slice(None), slice(None)).items():
        rows.append(dict(test=h, lambdas="pooled", **r))
    for li, lc in LAMBDA_ORDER:
        sel = lambda d: (d.lambdaI == li) & (d.lambdaC == lc)
        for h, r in four(sel(sb), sel(sa), sel(stale)).items():
            rows.append(dict(test=h, lambdas=f"({li}, {lc})", **r))
    out = pd.DataFrame(rows)
    sign = out.test.map({"G1'": 1, "G4'": -1, "G2a'": 1, "G3": 1})
    # wrong-signed: one-sided p < 0.05 in the opposite direction, unadjusted
    out["wrong_sign"] = [(_p(t, G - 1, -s) < 0.05) if np.isfinite(t) else False
                         for t, G, s in zip(out.t, out.G, sign)]
    pooled = out.lambdas == "pooled"
    hj = holm(out.loc[pooled, "p"].fillna(1.0).to_numpy())
    out["p_holm"], out["reject_holm"] = np.nan, pd.Series(pd.NA, index=out.index, dtype="boolean")
    out.loc[pooled, "p_holm"] = [a for _, a in hj]
    out.loc[pooled, "reject_holm"] = [bool(r) for r, _ in hj]
    against = out[~pooled].groupby("test").wrong_sign.any()
    out.loc[pooled, "pair_wrong_sign"] = out.loc[pooled, "test"].map(against)

    # Secondary: G1' split by failure in the base arm (pre-treatment for y).
    split = []
    for fb in (True, False):
        o = sb[(sb.gap1 > gap) & (sb.failed_base == fb)]
        split.append(dict(test="G1'", base_failed=fb, **cmean(o.dD, o.paramSeed, +1)))
    return out, pd.DataFrame(split)


def g2b(out):
    s = out[(out.test == "G2a'") & (out.lambdas != "pooled")].set_index("lambdas").est
    return bool((s.diff().dropna() < 0).all()) if s.notna().all() else None


def levels(df, gap):
    rows = []
    for (arm, li, lc), d in df.groupby(["arm", "lambdaI", "lambdaC"]):
        r = {"arm": arm, "lambdas": f"({li}, {lc})", "runs": len(d), "P_fail": d.failed.mean()}
        if d.gap1.notna().any():
            g1 = (d.gap1 > gap) & d.failed
            g4 = (d.gap1 < -gap) & ~d.failed
            r.update(G1_D=d.D[g1].mean(), G1_n=int(g1.sum()), G4_D=d.D[g4].mean(), G4_n=int(g4.sum()))
        rows.append(r)
    return pd.DataFrame(rows)


def g2c(stale):
    f = stale[stale.failed]
    return f.groupby(["y1", "lambdaI", "lambdaC"]).agg(runs=("D", "size"), D=("D", "mean")).reset_index()


def theta_bins(df):
    bins = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    d = df.assign(theta_bin=pd.cut(df.theta, bins, include_lowest=True))
    return (d.groupby(["arm", "theta_bin"], observed=True)
             .agg(runs=("D", "size"), P_fail=("failed", "mean"), W_I=("W_I", "mean"),
                  W_C=("W_C", "mean"), D=("D", "mean")).reset_index())


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", required=True, help="arm with no public signal")
    ap.add_argument("--agree", required=True, help="arm where y tracks theta")
    ap.add_argument("--stale", nargs="+", required=True, help="stale arms (one per y0, rho 1)")
    ap.add_argument("--other", nargs="*", default=[], help="exploratory arms (levels only)")
    ap.add_argument("--gap", type=float, default=0.1)
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()

    base, agree = load(a.base), load(a.agree)
    stale = pd.concat([load(p) for p in a.stale], ignore_index=True)
    other = [load(p) for p in a.other]
    pd.set_option("display.width", 220, "display.max_columns", 30)
    out = {}

    for col, label in (("D", "head count (primary)"), ("Dd", "deposit-weighted (secondary)")):
        t, split = tests(stale, base, agree, a.gap, col)
        print(f"\n=== Confirmatory family, D {label}, g = {a.gap} ===")
        print(t.round(4).to_string(index=False))
        print(f"G2b ordering b(0.1,0.9) > b(0.2,0.8) > b(0.3,0.5): {g2b(t)}")
        print("G1' by failure in the base arm:")
        print(split.round(4).to_string(index=False))
        out[f"tests_{col}"], out[f"g1split_{col}"] = t, split
    for g in (0.05, 0.2):
        t, _ = tests(stale, base, agree, g, "D")
        t = t[(t.lambdas == "pooled") & t.test.isin(["G1'", "G4'"])]
        print(f"\nRobustness g = {g}:")
        print(t[["test", "est", "se", "t", "p", "n"]].round(4).to_string(index=False))
        out[f"robust_g{g}"] = t

    allarms = pd.concat([base, agree, stale] + other, ignore_index=True)
    lv = levels(allarms, a.gap)
    print("\nLevels G1 / G4 by arm (aggregate findings; not tests)")
    print(lv.round(4).to_string(index=False))
    gc = g2c(stale)
    print("\nG2c (exploratory): mean D among failed runs by y0")
    print(gc.round(4).to_string(index=False))
    out.update(levels=lv, g2c=gc, theta_bins=theta_bins(allarms))
    if a.out:
        a.out.mkdir(parents=True, exist_ok=True)
        for k, v in out.items():
            v.to_csv(a.out / f"rung1_{k}.csv", index=False)
        print(f"\nwrote {a.out}/rung1_*.csv")


if __name__ == "__main__":
    main()
