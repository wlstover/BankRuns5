#!/usr/bin/env python3
"""Rung 4: S1-S4 on one partial-withdrawal arm (docs/rung4_prereg.md; 2026-10-22).

Unit: one run of a mixed cell (0 < mu < 1), pooled over the lambda pairs. Each
statistic is a per-run quantity; its mean has a CR1 standard error clustered on
the initialisation (paramSeed) and a one-sided p from t(G-1), as in rung 1
(rung1_relational.cmean). Runs where a statistic is undefined (no exiters in a
group, fewer than two neighbour bins) are dropped from that statistic only.

  S1   one-shot share among exiters (consolidated_exitshape.csv, I + C):
       (a) top decile - D1-D5 pooled                          < 0
       (b) largest agent - top decile, runs where it exited    < 0
       reported: the pooled curve by size group, its run-to-run 5-95% range,
       and the partial-exit share by size
  S2b  withdrawal rate, top decile - D1-D5 (consolidated_wealth.csv; n includes
       agents hit by the shock, as the file records them)     > 0
       with --ref: the same in the reference arm, paired run for run, and the
       arm - ref gap (what CARA adds)
  S2a  needs insured arms: not computed here
  S3   per run x type, the decision-weighted OLS slope of P(withdraw | decision)
       on the share of neighbours out (bin midpoints of NB_BINS, functions4.jl);
       (a) pooled over types (all decisions)                   > 0
       (b) slope_C - slope_I, runs with both types             > 0
  S4   among agents not hit by the shock (consolidated_types.csv, I + C):
       (a) head-count share W who withdraw                     < 0.5
           (reported: the share of runs with W < 0.5, all and failed runs)
       (b) W$ - W                                              > 0

The slope's x values and the per-run construction of S1/S3 were fixed when this
script was written (2026-10-22), after the arm ran but before any S statistic
was looked at; the pre-registration names the statistics, not these details.

Usage:
    python3 scripts/rung4_stats.py --arm outputs/r1c-none [--ref outputs/r1p-none] \\
        [--out outputs/r1c-analysis]
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from rung1_relational import cmean

KEYS = ["task_id", "key", "paramSeed", "seed", "mu", "lambdaI", "lambdaC"]
PAIR = ["mu", "lambdaI", "lambdaC", "paramSeed", "seed"]
GROUPS = [f"d{j}" for j in range(1, 11)] + ["top1", "top01"]
NB_MID = np.array([0.0, 0.05, 0.15, 0.275, 0.425, 0.75])   # NB_BINS: 0, (0,.1], ..., (.5,1]


def runs(arm):
    r = pd.read_csv(arm / "consolidated_results.csv", usecols=KEYS + ["bankRun"])
    return r[(r.mu > 0) & (r.mu < 1)]


def by_run(arm, stem, r):
    """The file summed over types (I + C), restricted to the runs in r."""
    d = pd.read_csv(arm / f"consolidated_{stem}.csv")
    num = d.select_dtypes("number").columns.difference(
        ["task_id", "reserveRatio", "depQuantile", "sigma", "k", "p", "mu", "lambdaI", "lambdaC"])
    return r.merge(d.groupby("key")[list(num)].sum(), left_on="key", right_index=True)


def row(name, x, g, sign, **extra):
    return dict(stat=name, **cmean(x, g, sign), **extra)


def s1(arm, r):
    e = by_run(arm, "exitshape", r)
    for g in GROUPS:
        e[f"os_{g}"] = e[f"oneshot_{g}"] / e[f"exit_{g}"].where(e[f"exit_{g}"] > 0)
        e[f"pt_{g}"] = e[f"partial_{g}"] / e[f"exit_{g}"].where(e[f"exit_{g}"] > 0)
    lo_x = e[[f"exit_d{j}" for j in range(1, 6)]].sum(axis=1)
    lo_os = e[[f"oneshot_d{j}" for j in range(1, 6)]].sum(axis=1) / lo_x.where(lo_x > 0)
    a = (e.os_d10 - lo_os).dropna()
    b = (e.os_top01 - e.os_d10).dropna()
    tests = [row("S1a one-shot: D10 - D1-5", a, e.paramSeed[a.index], -1),
             row("S1b one-shot: largest - D10", b, e.paramSeed[b.index], -1)]
    curve = pd.DataFrame([dict(
        group=g,
        n=e[f"n_{g}"].sum(), exiters=e[f"exit_{g}"].sum(),
        exit_rate=e[f"exit_{g}"].sum() / e[f"n_{g}"].sum(),
        oneshot_pooled=e[f"oneshot_{g}"].sum() / e[f"exit_{g}"].sum(),
        oneshot_p05=e[f"os_{g}"].quantile(0.05), oneshot_p95=e[f"os_{g}"].quantile(0.95),
        partial_pooled=e[f"partial_{g}"].sum() / e[f"exit_{g}"].sum(),
        runs_defined=e[f"os_{g}"].notna().sum()) for g in GROUPS])
    return tests, curve


def s2b_rate(arm, r):
    w = by_run(arm, "wealth", r)
    hi = w.endog_d10 / w.n_d10
    lo = w[[f"endog_d{j}" for j in range(1, 6)]].sum(axis=1) / w[[f"n_d{j}" for j in range(1, 6)]].sum(axis=1)
    return w[PAIR].assign(s2b=hi - lo)


def s2b(arm, ref, r):
    x = s2b_rate(arm, r)
    out = [row("S2b withdraw rate: D10 - D1-5", x.s2b, x.paramSeed, +1)]
    if ref is not None:
        y = s2b_rate(ref, runs(ref))
        j = x.merge(y, on=PAIR, suffixes=("", "_ref"))
        out += [row("S2b in --ref (paired runs)", j.s2b_ref, j.paramSeed, +1, ref=ref.name),
                row("S2b arm - ref (what the arm adds)", j.s2b - j.s2b_ref, j.paramSeed, +1, ref=ref.name)]
    return out


def slope(dec, wd):
    m = dec > 0
    if m.sum() < 2:
        return np.nan
    x, y, w = NB_MID[m], wd[m] / dec[m], dec[m]
    xb = np.average(x, weights=w)
    sxx = (w * (x - xb) ** 2).sum()
    return (w * (x - xb) * (y - np.average(y, weights=w))).sum() / sxx if sxx > 0 else np.nan


def s3(arm, r):
    d = pd.read_csv(arm / "consolidated_neighbour.csv").merge(r[["key", "paramSeed"]], on="key")
    dc, wc = [f"dec_b{j}" for j in range(6)], [f"wd_b{j}" for j in range(6)]
    d["b"] = [slope(a, b) for a, b in zip(d[dc].to_numpy(float), d[wc].to_numpy(float))]
    pooled = d.groupby(["key", "paramSeed"])[dc + wc].sum().reset_index()
    pooled["b"] = [slope(a, b) for a, b in zip(pooled[dc].to_numpy(float), pooled[wc].to_numpy(float))]
    pooled = pooled.dropna(subset=["b"])
    w = d.pivot(index=["key", "paramSeed"], columns="type", values="b").dropna().reset_index()
    rates = d.groupby("type")[dc + wc].sum()
    rates = pd.DataFrame({t: rates.loc[t, wc].to_numpy() / rates.loc[t, dc].to_numpy()
                          for t in rates.index}, index=["0", "(0,.1]", "(.1,.2]", "(.2,.35]", "(.35,.5]", "(.5,1]"])
    tests = [row("S3a slope in neighbours out (pooled)", pooled.b, pooled.paramSeed, +1)]
    for t in ("I", "C"):
        x = d[(d.type == t)].dropna(subset=["b"])
        tests.append(row(f"S3 slope, type {t} (reported)", x.b, x.paramSeed, +1))
    tests.append(row("S3b slope C - I", w.C - w.I, w.paramSeed, +1))
    return tests, rates


def s4(arm, r):
    t = by_run(arm, "types", r)
    W = t.nEndog / (t.n - t.nExog)
    Wd = t.depEndog / (t.depTotal - t.depExog)
    tests = [row("S4a head-count share W - 0.5", W - 0.5, t.paramSeed, -1,
                 share_runs_below=(W < 0.5).mean(),
                 share_failed_runs_below=(W[t.bankRun] < 0.5).mean()),
             row("S4b W$ - W", Wd - W, t.paramSeed, +1)]
    return tests


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--arm", type=Path, required=True)
    ap.add_argument("--ref", type=Path, default=None)
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()
    r = runs(a.arm)
    print(f"{a.arm}: {len(r)} mixed-cell runs, {r.paramSeed.nunique()} initialisations, "
          f"P(fail) {r.bankRun.mean():.3f}")
    t1, curve = s1(a.arm, r)
    t3, rates = s3(a.arm, r)
    tests = pd.DataFrame(t1 + s2b(a.arm, a.ref, r) + t3 + s4(a.arm, r))
    pd.set_option("display.width", 220)
    print(tests.round(4).to_string(index=False))
    print("\nS1 by size group (I + C pooled over runs):")
    print(curve.round(4).to_string(index=False))
    print("\nS3 P(withdraw | decision) by neighbours out, by type:")
    print(rates.round(4).to_string())
    if a.out:
        a.out.mkdir(parents=True, exist_ok=True)
        tests.to_csv(a.out / "rung4_tests.csv", index=False)
        curve.to_csv(a.out / "rung4_s1_curve.csv", index=False)
        rates.to_csv(a.out / "rung4_s3_rates.csv")
        print(f"\nwrote {a.out}/rung4_*.csv")


if __name__ == "__main__":
    main()
