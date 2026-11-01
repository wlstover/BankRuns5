#!/usr/bin/env python3
"""The §4-§6 pilot round (arms/pilot_s4_s6.tsv) read against its control, run for run.

Every pilot arm is the reference bank of r1k-stale-y50 with one setting moved, on the
same 15-cell reference grid (mu x lambda pair) with common seeding, so each run pairs
with the control's run on (mu, lambda gap, seed1, seed2). The pairing ignores the
moved axis (r, q, k and p arms change those cell columns). SEs are CR1, clustered on
the initialisation (seed1), as in learning_pilot.py.

Per arm and cell:
  fail      P(fail) in the arm and the control, and the paired difference
  gap       the I - C endogenous withdrawal share of deposits (depEndog / depTotal by
            type; mixed cells only), and its paired difference
  loss      loss_exact by type in the arm (who_runs_production.py); paired only if the
            control has it (lossStayers is written from 2026-10-31, after the control ran)
Per arm, the slope in mu (§6: does the axis move P(fail)'s slope, not only its level):
  d slope   [P_arm(mu 1) - P_arm(mu 0)] - [P_ctrl(mu 1) - P_ctrl(mu 0)], per lambda pair,
            from per-seed1 means (clustered on seed1).
And the arm file's reading rule (the header of arms/pilot_s4_s6.tsv):
  flat       |d P(fail)| < 0.02 in every cell and no I - C gap change (|d| <= 2 se in
             every mixed cell): a stratifier at the reference level only, or dropped;
  saturated  P(fail) > 0.95 or < 0.05 in more than half the cells: move the sweep's
             levels inward;
  otherwise  the sweep spans the reference and both pilot levels.

Exploratory: pilots place the sweep's levels; they are not hypothesis tests.

Usage:
    python3 scripts/pilot_paired.py --control outputs/r1k-stale-y50 outputs/p4-* outputs/p5-* outputs/p6-*
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from episodes_null import cmean, seeds_of  # noqa: E402
import who_runs_production as W  # noqa: E402

CELL = ["mu", "gap"]
PAIR = CELL + ["seed1", "seed2"]
FLAT_FAIL, SAT_HI, SAT_LO = 0.02, 0.95, 0.05


def load(arm: Path) -> pd.DataFrame:
    """One row per run: failed, the I - C withdrawal gap, loss_exact by type."""
    res, typ = W.load(arm)
    typ = W.add_stats(typ)
    typ["wd"] = typ.depEndog / typ.depTotal
    vals = ["wd"] + (["loss_exact"] if "loss_exact" in typ else [])
    w = typ.pivot_table(index=["key"], columns="type", values=vals, aggfunc="first")
    w.columns = [f"{a}_{b}" for a, b in w.columns]
    run = res[["key", "mu", "gap", "bankRun"]].drop_duplicates("key").set_index("key").join(w)
    run = run.reset_index()
    run = run.join(seeds_of(run["key"]))
    run["failed"] = run.bankRun.astype(float)
    run["ic_gap"] = run.get("wd_I") - run.get("wd_C") if {"wd_I", "wd_C"} <= set(run) else np.nan
    return run


def paired(m: pd.DataFrame, col: str) -> tuple[float, float]:
    d = (m[col].astype(float) - m[f"{col}_ctrl"].astype(float))
    ok = d.notna()
    if not ok.any():
        return (np.nan,) * 2
    return cmean(d[ok].to_numpy(), m.loc[ok, "seed1"].to_numpy())


def slope_d(m: pd.DataFrame, gap: float) -> tuple[float, float]:
    """Paired change in P(fail)'s mu 0 -> 1 slope, at one lambda gap."""
    s = m[np.isclose(m.gap, gap)].assign(d=lambda x: x.failed - x.failed_ctrl)
    per = s.groupby(["seed1", "mu"]).d.mean().unstack("mu")
    if not {0.0, 1.0} <= set(per.columns):
        return (np.nan,) * 2
    v = (per[1.0] - per[0.0]).dropna()
    if len(v) < 2:
        return (float(v.mean()) if len(v) else np.nan), np.nan
    return float(v.mean()), float(v.std(ddof=1) / np.sqrt(len(v)))


def classify(t: pd.DataFrame) -> str:
    sat = ((t.fail > SAT_HI) | (t.fail < SAT_LO)).mean() > 0.5
    if sat:
        return "saturated"
    mixed = t[(t.mu > 0) & (t.mu < 1)]
    gap_moves = (mixed.d_gap.abs() > 2 * mixed.se_gap.fillna(0.0)).any()
    if (t.d_fail.abs() < FLAT_FAIL).all() and not gap_moves:
        return "flat"
    return "informative"


def fmt(v, se=None, w=7):
    if pd.isna(v):
        return f"{'':>{w}}" if se is None else f"{'':>{w + 9}}"
    return f"{v:+{w}.3f}" if se is None else f"{v:+{w}.3f} ({se:.3f})"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--control", required=True, type=Path)
    ap.add_argument("arms", nargs="+", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=None, help="CSV of the per arm x cell table")
    a = ap.parse_args(argv)
    ctrl = load(a.control)
    ccols = ["failed", "ic_gap"] + [c for c in ("loss_exact_I", "loss_exact_C") if c in ctrl]
    rows, summary = [], []
    for arm in a.arms:
        d = load(arm)
        m = d.merge(ctrl[PAIR + ccols], on=PAIR, suffixes=("", "_ctrl"))
        print(f"\n{arm.name}: {len(d)} runs, {len(m)} paired with {a.control.name}")
        print(f"  {'mu':>4} {'gap':>4}  {'P ctrl':>6} {'P arm':>6} {'d P (se)':>16}   "
              f"{'gap ctrl':>8} {'gap arm':>8} {'d gap (se)':>16}   {'loss I':>7} {'loss C':>7}")
        for (mu, gap), g in m.groupby(CELL):
            dP, seP = paired(g, "failed")
            dg, seg = paired(g, "ic_gap") if 0 < mu < 1 else (np.nan, np.nan)
            r = dict(arm=arm.name, mu=mu, gap=gap, runs=len(g), fail_ctrl=g.failed_ctrl.mean(),
                     fail=g.failed.mean(), d_fail=dP, se_fail=seP,
                     gap_ctrl=g.ic_gap_ctrl.mean() if 0 < mu < 1 else np.nan,
                     gap_arm=g.ic_gap.mean() if 0 < mu < 1 else np.nan, d_gap=dg, se_gap=seg,
                     loss_I=g["loss_exact_I"].mean() if "loss_exact_I" in g else np.nan,
                     loss_C=g["loss_exact_C"].mean() if "loss_exact_C" in g else np.nan)
            for J in ("I", "C"):
                if f"loss_exact_{J}_ctrl" in g:
                    r[f"d_loss_{J}"], r[f"se_loss_{J}"] = paired(g, f"loss_exact_{J}")
            rows.append(r)
            print(f"  {mu:4.2f} {gap:4.1f}  {r['fail_ctrl']:6.3f} {r['fail']:6.3f} {fmt(dP, seP)}   "
                  f"{fmt(r['gap_ctrl'], w=8)} {fmt(r['gap_arm'], w=8)} {fmt(dg, seg)}   "
                  f"{fmt(r['loss_I'])} {fmt(r['loss_C'])}")
        t = pd.DataFrame([r for r in rows if r["arm"] == arm.name]).rename(columns={"fail": "fail"})
        slopes = {gap: slope_d(m, gap) for gap in sorted(m.gap.unique())}
        verdict = classify(t)
        summary.append(dict(arm=arm.name, verdict=verdict, max_abs_dP=t.d_fail.abs().max(),
                            **{f"d_slope_gap{gap}": s[0] for gap, s in slopes.items()},
                            **{f"se_slope_gap{gap}": s[1] for gap, s in slopes.items()}))
        print("  d slope in mu (mu 0 -> 1), by gap: "
              + "  ".join(f"{gap:.1f}: {fmt(s[0], s[1])}" for gap, s in slopes.items()))
        print(f"  reading rule: {verdict}")
    print("\nsummary")
    print(pd.DataFrame(summary).to_string(index=False, float_format=lambda v: f"{v:+.3f}"))
    if a.out:
        pd.DataFrame(rows).to_csv(a.out, index=False)
        print(f"wrote {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
