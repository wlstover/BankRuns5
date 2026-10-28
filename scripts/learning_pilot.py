#!/usr/bin/env python3
"""L2 pilots: learning arms against their no-learning control (docs/learning_design.md §8; 2026-10-28).

Every arm in arms/learning_l2.tsv uses common seeding, so a learning arm and the
control see the same populations and the same episode draws (theta, shock, signals).
Rows pair on (seed1, the run's seed2, episode); differences are clustered on the
initialisation (seed1), as in episodes_null.py.

By episode, for each arm:
  wI, wC   the mean theta weight of each type (the weight on y in the theta blend;
           the cultural lambda without learning)
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
    w = ep.pivot_table(index=PAIR + ["failed"], columns="type",
                       values=["weightMean", "wd"]).reset_index()
    w.columns = [a if not b else f"{a}_{b}" for a, b in w.columns]
    w["gap"] = w["wd_I"] - w["wd_C"]
    return w.rename(columns={"weightMean_I": "wI", "weightMean_C": "wC"})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--control", required=True, type=Path)
    ap.add_argument("arms", nargs="+", type=Path)
    a = ap.parse_args()

    ctrl = load(a.control)
    for arm in [a.control] + a.arms:
        d = load(arm)
        m = d.merge(ctrl[PAIR + ["failed", "gap"]], on=PAIR, suffixes=("", "_ctrl"))
        print(f"\n{arm.name}: {d['runSeed2'].nunique()} runs, paired with {a.control.name} "
              f"on {len(m)} of {len(d)} run-episodes")
        print(f"  {'ep':>3}  {'wI':>6} {'wC':>6}  {'fail':>6} {'d fail (se)':>15}  "
              f"{'gap I-C':>8} {'d gap (se)':>16}")
        for e, g in m.groupby("episode"):
            df, dse = cmean((g["failed"].astype(float) - g["failed_ctrl"].astype(float)).to_numpy(),
                            g["seed1"].to_numpy())
            dg = (g["gap"] - g["gap_ctrl"]).dropna()
            gg, gse = cmean(dg.to_numpy(), g.loc[dg.index, "seed1"].to_numpy()) if len(dg) else (np.nan,) * 2
            print(f"  {e:>3}  {g['wI'].mean():6.3f} {g['wC'].mean():6.3f}  {g['failed'].mean():6.3f} "
                  f"{df:+7.3f} ({dse:.3f})  {g['gap'].mean():+8.3f} {gg:+8.3f} ({gse:.3f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
