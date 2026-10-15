#!/usr/bin/env python3
"""Compare the schuler-sync pilot arms (2026-10-15).

Each arm is a scripts/who_runs_pilot.jl run (N = 200, depth 50, mu x lambda-gap x
reps) under one setting of the BANKRUN_* switches, written to
outputs/who_runs_pilot_<tag>/. Run scripts/who_runs_pilot.py on each arm first
(it writes summary.csv). This script lines the arms up on:

  P(fail)          share of runs in which the vault was exhausted;
  P6a slope        P(fail | mu = 1) - P(fail | mu = 0), by lambda gap (mixed
                   populations sit in between); P6a predicts a negative slope;
  |S*|             mean withdrawers per run (exogenous + endogenous);
  WHO / LOSS       I minus C in failed banks with mixed populations, by gap
                   (from summary.csv): share withdrawing endogenously, share of
                   deposits lost.

Run: python3 scripts/schuler_sync_compare.py tag1 tag2 ...
"""

import sys
from pathlib import Path

import pandas as pd

OUT = Path(__file__).resolve().parent.parent / "outputs"


def arm(tag):
    d = OUT / f"who_runs_pilot_{tag}"
    res = pd.read_csv(d / "results.csv")
    res["gap"] = (res.lambdaC - res.lambdaI).round(2)
    pf = res.pivot_table(index="mu", columns="gap", values="bankRun")
    row = {"arm": tag, "runs": len(res), "P_fail": res.bankRun.mean(), "mean_S": res.nWithdrawn.mean()}
    for g in pf.columns:
        row[f"slope_gap{g}"] = pf.loc[1.0, g] - pf.loc[0.0, g]
    for mu in pf.index:
        row[f"P_fail_mu{mu}"] = pf.loc[mu].mean()
    summ = d / "summary.csv"
    if summ.exists():
        s = pd.read_csv(summ)
        s = s[s.bankRun.astype(str).str.lower().isin(["true", "1"])]
        for stat, lab in (("wd_rate", "WHO"), ("loss_share", "LOSS")):
            for _, r in s[s.stat == stat].iterrows():
                row[f"{lab}_IminusC_gap{r.gap}"] = r.I_minus_C
                row[f"{lab}_ci_gap{r.gap}"] = r.ci95
    return row


def main(tags):
    t = pd.DataFrame([arm(x) for x in tags]).set_index("arm").T
    pd.set_option("display.width", 200, "display.precision", 3, "display.max_rows", 200)
    print(t)
    t.to_csv(OUT / "schuler_sync_compare.csv")
    print(f"\nwrote {OUT / 'schuler_sync_compare.csv'}")


if __name__ == "__main__":
    main(sys.argv[1:] or ["s0_base", "s1_fixdc", "s1_fresh", "s2_schuler", "s3_point", "x_tiebreak_only"])
