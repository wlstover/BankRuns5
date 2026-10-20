#!/usr/bin/env python3
"""Pooled P6b placebo contrast: the numbers next_steps.md reports for 2026-08-19.

next_steps.md (CURRENT STATE, 2026-08-19 pm) and Daily Notes/2026-08-19.md report
a pooled treatment-minus-placebo contrast, a clustered SE, a 95% CI, an MDE, a
sign test and the arm correlation. analysis_p6b.R writes only the per-point
table; those pooled numbers were computed by hand. This script recomputes them
from the R output and prints reported vs reproduced.

Input (scripts/analysis_p6b.R with BANKRUN_COMPARE_DIR set), per outcome o in
{cascade, binary}:

    <analysis>/p6b_treatment_minus_placebo__<o>__headline.csv
        one row per (lambdaGap, reserveRatio, mu) with mu interior:
        ex_t, ex_p = excess of the cell rate above the endpoint chord in the
        treatment / placebo arm; diff = ex_t - ex_p; se = sqrt(se_t^2 + se_p^2)
    <analysis>/p6b_excess_above_chord__<o>__headline.csv   (within-arm excess)

Definitions used here
---------------------
  pooled contrast   mean of the 54 stratum-mu diffs (equal weights).
  SE, clustered     CR1 cluster-robust SE of that mean, clusters = the 18
                    (lambdaGap x reserveRatio) strata. With 3 mu points in every
                    stratum this equals sd(stratum means) / sqrt(18).
                    CR0 (no G/(G-1)) is printed alongside.
  95% CI            mean +- t(0.975, G-1) * SE, G = 18 (17 df).
  MDE (80%)         (t(0.975, G-1) + t(0.80, G-1)) * SE, two-sided 5%; reported
                    as a share of the mean within-arm (treatment) excess.
  sign test         points with diff > 0 out of 54, binomial(0.5). The reported
                    p = 0.25 is the ONE-sided P(X >= k); two-sided is printed too.
  P6b bound         max(|CI_lo|, |CI_hi|) / |P6a swing|.
  P6a swing         pooled rate(mu = 1) - rate(mu = 0), per arm, from the raw
                    consolidated CSVs (completed runs with a result row, as in
                    analysis_p6b.R load_arm); falls back to the reported value
                    if the CSVs are absent.
  corr / overstatement
                    corr(ex_t, ex_p) across the 54 points; the quadrature SE
                    overstates by mean(se) / sd(diff), and the rho implied by
                    that ratio is 1 - ratio^-2 (the Daily Note's "0.978 backed
                    out of the SE ratio").

What does not reproduce (checked 2026-10-20)
--------------------------------------------
  Cascade MDE: reported 0.86 agents, reproduced 0.887 under the definitions
  above. 0.86 is what CR0 (0.290) with t(17) gives (0.862), but CR0 then gives
  a binary share of 17.4%, not the reported 18%, and an SE of 0.29, not 0.30.
  No single definition gives all of 0.30 / 0.86 / 15% / 0.16 / 18%; CR1 + t(17)
  gives every one except 0.86 (both shares round correctly: 15.3%, 17.9%).
  The 6.8x overstatement and rho = 0.9824 are CASCADE numbers; the binary
  outcome has rho = 0.991 and a 10.8x overstatement. "30/54 positive" is also
  cascade only (binary: 23/54).

Run: python3 scripts/p6b_placebo_summary.py [--analysis DIR] [--treatment DIR]
                                           [--placebo DIR] [--out CSV]
"""

import argparse
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

BASE = Path(__file__).resolve().parent.parent
STRATA = ["lambdaGap", "reserveRatio"]

# As reported in next_steps.md / Daily Notes 2026-08-19 (display units:
# cascade = agents, binary = pp).
REPORTED = {
    "cascade": dict(diff=-0.09, se=0.30, ci_lo=-0.72, ci_hi=0.54, mde=0.86, excess=5.80,
                    mde_share=15, n_pos=30, sign_p=0.25, p6a=-50.0, bound=1.4,
                    corr=0.9824, overstate=6.8, rho_implied=0.978),
    "binary": dict(diff=0.02, se=0.06, ci_lo=-0.10, ci_hi=0.14, mde=0.16, excess=0.91,
                   mde_share=18, p6a=-19.8),
}
SCALE = {"cascade": 1.0, "binary": 100.0}
COL = {"cascade": "nWithdrawn", "binary": "bankRun"}


def cluster_se(x, groups):
    """CR0 and CR1 SEs of mean(x), clustered on `groups`."""
    x = np.asarray(x, float)
    u = pd.Series(x - x.mean()).groupby(np.asarray(groups)).sum()
    g, n = len(u), len(x)
    v0 = (u ** 2).sum() / n ** 2
    return np.sqrt(v0), np.sqrt(v0 * g / (g - 1)), g


def p6a_swing(arm_dir, outcome):
    f = Path(arm_dir) / "consolidated_results.csv"
    if not f.exists():
        return np.nan
    d = pd.read_csv(f, usecols=["mu", "completed", "bankRun", "nWithdrawn"], dtype=str)
    d = d[d.completed.str.lower().eq("true") & d.bankRun.notna() & d.bankRun.str.len().gt(0)]
    y = d.bankRun.str.lower().eq("true").astype(float) if outcome == "binary" \
        else pd.to_numeric(d.nWithdrawn, errors="coerce")
    r = y.groupby(d.mu.astype(float)).mean()
    return SCALE[outcome] * (r.loc[1.0] - r.loc[0.0])


def summarise(analysis, outcome, arms):
    s = SCALE[outcome]
    d = pd.read_csv(analysis / f"p6b_treatment_minus_placebo__{outcome}__headline.csv")
    e = pd.read_csv(analysis / f"p6b_excess_above_chord__{outcome}__headline.csv")
    strata = d[STRATA].astype(str).agg("|".join, axis=1)
    mean = d["diff"].mean()
    se0, se1, g = cluster_se(d["diff"], strata)
    tc, tp = stats.t.ppf(0.975, g - 1), stats.t.ppf(0.80, g - 1)
    excess = e.loc[e.arm == "treatment", "excess"].mean()
    n_pos = int((d["diff"] > 0).sum())
    ratio = d.se.mean() / d["diff"].std(ddof=1)
    p6a = {a: p6a_swing(p, outcome) for a, p in arms.items()}
    p6a_use = p6a["treatment"] if np.isfinite(p6a["treatment"]) else REPORTED[outcome]["p6a"]
    ci = (mean - tc * se1, mean + tc * se1)
    out = dict(
        n_points=len(d), n_strata=g,
        diff=s * mean, se=s * se1, se_cr0=s * se0,
        ci_lo=s * ci[0], ci_hi=s * ci[1],
        mde=s * (tc + tp) * se1, mde_cr0=s * (tc + tp) * se0,
        mde_normal=s * (stats.norm.ppf(0.975) + stats.norm.ppf(0.80)) * se1,
        excess=s * excess, excess_placebo=s * e.loc[e.arm == "placebo", "excess"].mean(),
        mde_share=100 * (tc + tp) * se1 / excess,
        mde_share_cr0=100 * (tc + tp) * se0 / excess,
        n_pos=n_pos,
        sign_p=stats.binomtest(n_pos, len(d), alternative="greater").pvalue,
        sign_p_two=stats.binomtest(n_pos, len(d)).pvalue,
        p6a=p6a_use, p6a_placebo=p6a["placebo"],
        bound=100 * s * max(abs(ci[0]), abs(ci[1])) / abs(p6a_use),
        corr=np.corrcoef(d.ex_t, d.ex_p)[0, 1],
        sd_t=s * d.ex_t.std(ddof=1), sd_p=s * d.ex_p.std(ddof=1), sd_diff=s * d["diff"].std(ddof=1),
        overstate=ratio, rho_implied=1 - ratio ** -2,
    )
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--analysis", default=str(BASE / "outputs/production/analysis"))
    ap.add_argument("--treatment", default=str(BASE / "outputs/production"))
    ap.add_argument("--placebo", default=str(BASE / "outputs/placebo"))
    ap.add_argument("--out", default=None, help="CSV (default <analysis>/p6b_placebo_summary.csv)")
    a = ap.parse_args()
    analysis = Path(a.analysis)
    arms = {"treatment": a.treatment, "placebo": a.placebo}

    rows = []
    for o in ("cascade", "binary"):
        got = summarise(analysis, o, arms)
        for stat, val in got.items():
            rep = REPORTED[o].get(stat)
            rows.append(dict(outcome=o, stat=stat, reported=np.nan if rep is None else rep,
                             reproduced=val,
                             match="" if rep is None else ("yes" if _rounds_to(val, rep) else "NO")))
    t = pd.DataFrame(rows)
    pd.set_option("display.width", 160, "display.max_rows", 200)
    print("P6b placebo contrast, pooled over 54 stratum-mu points "
          "(cascade in agents, binary in pp; shares in %)\n")
    print(t.to_string(index=False, float_format=lambda v: f"{v:.4g}"))
    out = Path(a.out) if a.out else analysis / "p6b_placebo_summary.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    t.to_csv(out, index=False)
    print(f"\nwrote {out}")


def _rounds_to(val, rep):
    """True if `val` rounded to the reported number's decimals equals it."""
    s = f"{rep}"
    dec = len(s.split(".")[1]) if "." in s else 0
    return round(val, dec) == round(rep, dec)


if __name__ == "__main__":
    main()
