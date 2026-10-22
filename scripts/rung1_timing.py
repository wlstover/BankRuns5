#!/usr/bin/env python3
"""Rung 1, exploratory: does the "error corrects" sorting fade with the decision tick? (2026-10-22)

docs/rung1_prereg.md section 4 asks two things of corrects-y80-r50 (y starts at
0.8 and its gap to theta halves each tick):
  (a) is its sorting between the stale-y80 and tracks-g0 values, and
  (b) does it fade with the decision tick?

Sorting is channel-isolated, as in G1'/G4'/G3c: dD = D_arm - D_base run for run,
with base = the no-public arm. (a) uses whole-run D. For (b), D_t = W_I,t - W_C,t,
where W_J,t = type-J agents not hit by the shock who withdrew at tick t / type-J
agents not hit by the shock (consolidated_timing.csv; tick 10 = 10 and later).
At tick t the corrects gap is 0.5^(t-1) of the stale gap, so the corrects/stale
ratio of mean dD_t should fall with t. Caveat: D_t is a flow and only runs still
going at tick t contribute to it, and which runs are still going differs between
arms.
Runs are split by the sign of gap1 = y1 - theta (the same in both arms, since
y1 = 0.8), with |gap1| > g. Clustered SEs as in rung1_relational.py.

Usage:
    python3 scripts/rung1_timing.py --base outputs/r1t-none --stale outputs/r1t-stale-y80 \\
        --corrects outputs/r1t-corrects-y80-r50 --agree outputs/r1t-tracks-g0 \\
        [--gap 0.1] [--out outputs/r1t-analysis]
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

from rung1_relational import PAIR, LAMBDA_ORDER, cmean, load, paired

TICKS = [f"t{k}" for k in range(1, 10)] + ["t10plus"]


def load_ticks(arm_dir):
    """Per-run D_t at each tick, merged onto load()'s run table."""
    arm_dir = Path(arm_dir)
    df = load(arm_dir)
    ty = pd.read_csv(arm_dir / "consolidated_types.csv",
                     usecols=["task_id", "key", "type", "n", "nExog"])
    tm = pd.read_csv(arm_dir / "consolidated_timing.csv",
                     usecols=["task_id", "key", "type"] + TICKS)
    tm = tm.merge(ty, on=["task_id", "key", "type"], how="inner")
    elig = (tm.n - tm.nExog).where(tm.n > tm.nExog)
    for c in TICKS:
        tm[c] = tm[c] / elig
    w = tm.pivot_table(index=["task_id", "key"], columns="type", values=TICKS)
    d = pd.DataFrame({f"D_{c}": w[(c, "I")] - w[(c, "C")] for c in TICKS}).reset_index()
    return df.merge(d, on=["task_id", "key"], how="inner")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", required=True)
    ap.add_argument("--stale", required=True)
    ap.add_argument("--corrects", required=True)
    ap.add_argument("--agree", required=True)
    ap.add_argument("--gap", type=float, default=0.1)
    ap.add_argument("--out", type=Path, default=None)
    a = ap.parse_args()

    base, stale, corr = (load_ticks(p) for p in (a.base, a.stale, a.corrects))
    agree = load(a.agree)
    dcols = ["D"] + [f"D_{c}" for c in TICKS]
    pd.set_option("display.width", 220, "display.max_columns", 30)

    def iso(arm):
        m = paired(arm, base, dcols, "_base")
        for c in dcols:
            m["d" + c] = m[c] - m[c + "_base"]
        return m

    s, c = iso(stale), iso(corr)
    g = iso(agree.assign(**{k: np.nan for k in dcols[1:]}))

    # (a) whole-run |dD|: stale-y80 vs corrects vs tracks-g0, among |gap1| > g
    rows = []
    for lam in ["pooled"] + LAMBDA_ORDER:
        sel = (lambda d: d) if lam == "pooled" else \
              (lambda d, l=lam: d[(d.lambdaI == l[0]) & (d.lambdaC == l[1])])
        ss, cc, gg = sel(s), sel(c), sel(g)
        ss = ss[ss.gap1.abs() > a.gap]
        cc = cc[cc.gap1.abs() > a.gap]
        gg = gg.merge(ss[PAIR], on=PAIR)      # the same runs (theta paired)
        lab = "pooled" if lam == "pooled" else f"({lam[0]}, {lam[1]})"
        rows.append(dict(lambdas=lab, n=len(ss), absdD_stale=ss.dD.abs().mean(),
                         absdD_corrects=cc.dD.abs().mean(), absdD_agree=gg.dD.abs().mean()))
    between = pd.DataFrame(rows)
    between["between"] = ((between.absdD_corrects < between.absdD_stale)
                          & (between.absdD_corrects > between.absdD_agree))
    print(f"=== (a) whole-run |D_arm - D_base| among |gap1| > {a.gap} ===")
    print(between.round(4).to_string(index=False))

    # (b) mean dD_t by tick, by side of the gap
    rows = []
    for side, f, sign in (("optimistic (G1')", lambda d: d.gap1 > a.gap, +1),
                          ("pessimistic (G4')", lambda d: d.gap1 < -a.gap, -1)):
        for k, t in enumerate(TICKS, start=1):
            col = f"dD_{t}"
            rs = cmean(s.loc[f(s), col].dropna(), s.loc[f(s) & s[col].notna(), "paramSeed"], sign)
            rc = cmean(c.loc[f(c), col].dropna(), c.loc[f(c) & c[col].notna(), "paramSeed"], sign)
            rows.append(dict(side=side, tick=k if k < 10 else "10+",
                             gap_frac=0.5 ** (k - 1) if k < 10 else np.nan,
                             stale=rs["est"], stale_t=rs["t"],
                             corrects=rc["est"], corrects_t=rc["t"],
                             ratio=rc["est"] / rs["est"] if rs["est"] else np.nan, n=rs["n"]))
    fade = pd.DataFrame(rows)
    print("\n=== (b) mean D_t(arm) - D_t(base) by decision tick (pooled over lambda pairs) ===")
    print("gap_frac = corrects gap / stale gap at that tick; ratio = corrects / stale")
    print(fade.round(4).to_string(index=False))

    if a.out:
        a.out.mkdir(parents=True, exist_ok=True)
        between.to_csv(a.out / "rung1_corrects_between.csv", index=False)
        fade.to_csv(a.out / "rung1_corrects_fade.csv", index=False)
        print(f"\nwrote {a.out}/rung1_corrects_*.csv")


if __name__ == "__main__":
    main()
