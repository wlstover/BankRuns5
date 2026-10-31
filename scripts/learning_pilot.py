#!/usr/bin/env python3
"""L2 pilots: learning arms against their no-learning control (docs/learning_design.md §8; 2026-10-28).

Every arm in arms/learning_l2.tsv uses common seeding, so a learning arm and the
control see the same populations and the same episode draws (theta, shock, signals).
Rows pair on (seed1, the run's seed2, episode); differences are clustered on the
initialisation (seed1), as in episodes_null.py.

By episode (and pooled over episodes 2+, row "2+"), for each arm:
  wI, wC   the mean theta weight of each type (the weight on y in the theta blend;
           the cultural lambda without learning), and their paired differences from the
           control (10-30). Any two arms pair, so --control lrn-y50-pay against pay-q90
           gives the effect of coverage on what Rule B learns.
  mu       the share of type I (10-30; fixed unless BANKRUN_LEARN=type / payoff+type)
  sI, sC   within-type dispersion (10-30), and their paired differences. The SD of
           the learned weight w* alone (learnedSd) where the episode files carry it
           (written from late 10-30, learning arms only); else the SD of the theta
           weight used (weightSd), which is (1 - kappa) lambda + kappa w* and so mixes
           in lambda's spread. Each arm's header names the measure; the paired
           difference is printed only when arm and control use the same one.
  fail     P(fail), and its paired difference from the control
  gap      the I - C endogenous withdrawal share of deposits, and its paired difference

Exploratory: no pre-registration (the user, 2026-10-28).

Usage:
    python3 scripts/learning_pilot.py --control outputs/lrn-y50-none \\
        outputs/lrn-y50-k25 outputs/lrn-y50-k50 outputs/lrn-y50-k100 outputs/lrn-y50-k50-ins
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
from episodes_null import cmean, seeds_of  # noqa: E402

PAIR = ["seed1", "runSeed2", "episode"]


def load(arm: Path) -> pd.DataFrame:
    """One row per run x episode: failure, theta weight by type, I - C withdrawal gap."""
    ep = pd.read_csv(arm / "consolidated_episodes.csv")
    ep = ep.join(seeds_of(ep["key"]).rename(columns={"seed2": "runSeed2"}))
    ep["failed"] = ep["failed"].astype(str).str.lower() == "true"
    ep["wd"] = ep["depEndog"] / ep["depTotal"]
    learned = "learnedSd" in ep and ep["learnedSd"].notna().any()
    w = ep.pivot_table(index=PAIR + ["failed"], columns="type",
                       values=["weightMean", "weightSd", "wd", "n"]
                       + (["learnedSd"] if learned else [])).reset_index()
    w.columns = [a if not b else f"{a}_{b}" for a, b in w.columns]
    if learned:
        w["weightSd_I"], w["weightSd_C"] = w["learnedSd_I"], w["learnedSd_C"]
    w["gap"] = w["wd_I"] - w["wd_C"]
    w["mu"] = w["n_I"] / (w["n_I"] + w["n_C"])       # share of type I (moves under L3b)
    w = w.rename(columns={"weightMean_I": "wI", "weightMean_C": "wC",
                          "weightSd_I": "sI", "weightSd_C": "sC"})
    w.attrs["s"] = "SD of w*" if learned else "SD of weight"
    return w


def paired(g: pd.DataFrame, col: str) -> tuple[float, float]:
    """Mean paired difference arm - control in `col`, CR1 SE clustered on seed1."""
    d = (g[col].astype(float) - g[f"{col}_ctrl"].astype(float)).dropna()
    if not len(d):
        return (np.nan,) * 2
    return cmean(d.to_numpy(), g.loc[d.index, "seed1"].to_numpy())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--control", required=True, type=Path)
    ap.add_argument("arms", nargs="+", type=Path)
    a = ap.parse_args()

    cols = ["failed", "gap", "wI", "wC", "mu", "sI", "sC"]
    ctrl = load(a.control)
    for arm in [a.control] + a.arms:
        d = load(arm)
        m = d.merge(ctrl[PAIR + cols], on=PAIR, suffixes=("", "_ctrl"))
        print(f"\n{arm.name}: {d['runSeed2'].nunique()} runs, paired with {a.control.name} "
              f"on {len(m)} of {len(d)} run-episodes; s = {d.attrs['s']}")
        same = d.attrs["s"] == ctrl.attrs["s"]
        print(f"  {'ep':>3}  {'wI':>6} {'wC':>6}  {'d wI (se)':>15} {'d wC (se)':>15}  "
              f"{'fail':>6} {'d fail (se)':>15}  {'gap I-C':>8} {'d gap (se)':>16}  {'mu':>5} {'d mu (se)':>15}  "
              f"{'sI':>6} {'sC':>6}  {'d sI (se)':>15} {'d sC (se)':>15}")
        rows = list(m.groupby("episode")) + [("2+", m[m["episode"] >= 2])]
        for e, g in rows:
            dI, dIse = paired(g, "wI")
            dC, dCse = paired(g, "wC")
            df, dse = paired(g, "failed")
            dg, gse = paired(g, "gap")
            dm, mse = paired(g, "mu")
            dsI, sIse = paired(g, "sI") if same else (np.nan,) * 2
            dsC, sCse = paired(g, "sC") if same else (np.nan,) * 2
            print(f"  {e:>3}  {g['wI'].mean():6.3f} {g['wC'].mean():6.3f}  "
                  f"{dI:+7.3f} ({dIse:.3f}) {dC:+7.3f} ({dCse:.3f})  {g['failed'].mean():6.3f} "
                  f"{df:+7.3f} ({dse:.3f})  {g['gap'].mean():+8.3f} {dg:+8.3f} ({gse:.3f})  "
                  f"{g['mu'].mean():5.3f} {dm:+7.3f} ({mse:.3f})  "
                  f"{g['sI'].mean():6.3f} {g['sC'].mean():6.3f}  "
                  f"{dsI:+7.3f} ({sIse:.3f}) {dsC:+7.3f} ({sCse:.3f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
