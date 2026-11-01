#!/usr/bin/env python3
"""Rung 2 diagnostic: where does the ABM's decision part from F8 (b)?

nest_cutoffs.py compares cutoffs only. The one-shot rows also record each agent's
blended estimate (est), its Monte Carlo stay value (stayProb = K/D) and its
withdrawal value (wdProb), so the two halves of (b) can be checked one at a time:

  rule      withdrew == (wdProb > R_s * stayProb) (TIEBREAK = strict), and wdProb == 1
            (LIQUIDITY = unlimited: a withdrawal is always paid);
  belief    stayProb against the bridge's exact p_solvent(est, lambda), near each
            type's cutoff (|est - t_D| < --band): the mean residual, and the shift in
            est it amounts to (residual / slope of p_solvent there). A shift that is
            the same in every cell points to one input to the solvency calculation, not
            to the blend.

Run:    python3 scripts/nest_diag.py outputs/<arm> --y 0.5
"""

import argparse
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nest_bridge as NB  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("arm")
    ap.add_argument("--y", type=float, required=True)
    ap.add_argument("--band", type=float, default=0.01, help="half-width in est around t_D")
    a = ap.parse_args()
    n = replace(NB.Nest(), y=a.y)
    os_ = pd.read_csv(Path(a.arm) / "consolidated_oneshot.csv",
                      usecols=["individualism", "est", "withdrew", "wdProb", "stayProb"])
    wd = os_.withdrew.astype(bool)
    rule = wd == (os_.wdProb > n.R_s * os_.stayProb)
    print(f"rows {len(os_)}: rule holds in {rule.mean():.6f}, wdProb == 1 in {(os_.wdProb == 1.0).mean():.6f}")
    rows = []
    for om, d in os_.groupby(os_.individualism.round(6)):
        t_D = NB.cutoffs_b(n, om)[2]
        near = d[(d.est - t_D).abs() < a.band]
        if near.empty:
            rows.append(dict(lam=om, t_D=t_D, n_near=0))
            continue
        cache = {}
        def ps(e):
            k = round(e, 5)
            if k not in cache:
                cache[k] = NB.p_solvent(n, k, om)
            return cache[k]
        p = near.est.map(ps).to_numpy()
        res = near.stayProb.to_numpy() - p
        h = 1e-4
        slope = (NB.p_solvent(n, t_D + h, om) - NB.p_solvent(n, t_D - h, om)) / (2 * h)
        se = res.std(ddof=1) / np.sqrt(len(res)) if len(res) > 1 else np.nan
        rows.append(dict(lam=om, t_D=t_D, n_near=len(near), stay_abm=near.stayProb.mean(),
                         p_bridge=p.mean(), resid=res.mean(), se=se, slope=slope,
                         est_shift=-res.mean() / slope))
    pd.set_option("display.width", 200)
    print(pd.DataFrame(rows).to_string(index=False, float_format=lambda v: f"{v:.5f}"))
    print("est_shift < 0: the ABM's agents are more optimistic than (b) (they withdraw at lower est)")


if __name__ == "__main__":
    main()
