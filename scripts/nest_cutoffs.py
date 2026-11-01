#!/usr/bin/env python3
"""F9: the ABM's empirical cutoffs in the rung 2 nest, against F8's predictions.

Reads an arm's consolidated_oneshot.csv (TIMING=oneshot: one row per decision, with
the private signal x and the outcome) and scripts/nest_bridge.py's predictions, and
reports per cell (mu, lambda pair) and type:

  c_hat     the empirical cutoff in x: the split that best separates withdrawers
            (x below) from stayers (x above), the midpoint of the best gap;
  CI        its 95% interval from a bootstrap over runs (keys), so draws that share a
            run's theta stay together (run-clustered);
  c_b_D     F8 (b) at the arm's Monte Carlo depth (mc_depth in its manifest.csv,
            recomputed here; the bridge CSV's c_b_D is at nest_bridge.py's --depth),
            c_b_inf the noise-free limit,
            c_a   Chapter 1's equilibrium cutoff(s);
  verdict   PASS if c_b_D lies inside the CI (the criterion fixed 2026-10-31,
            Rahmandad-Sterman 2008).

Where (b) puts the cutoff outside the signals the cell produced, there is no cutoff
to estimate; the test is then the type's withdrawal count against the count (b_D)
predicts, sum_i P(withdraw | x_i), with a run-clustered 95% interval on the observed
count (verdict PASS-COUNT / FAIL-COUNT). Types are assigned by lambda (the nest's
point-mass lambda puts every agent exactly at its type's mean).

Run:    python3 scripts/nest_cutoffs.py outputs/<arm> --y 0.5 [--bridge outputs/analysis/nest_bridge.csv]
        (--y = the arm's BANKRUN_THETA_PUBLIC_LEVEL: one arm per stale level)
"""

import argparse
import sys
from dataclasses import replace
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nest_bridge as NB  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def best_split(x, wd):
    """Cutoff c maximising #(withdrew, x < c) + #(stayed, x >= c); midpoint of the gap."""
    o = np.argsort(x, kind="stable")
    xs, ws = x[o], wd[o].astype(int)
    n = len(xs)
    # score of splitting before position i (i = 0..n): withdrawers left + stayers right
    left_wd = np.concatenate(([0], np.cumsum(ws)))
    right_stay = np.concatenate((np.cumsum((1 - ws)[::-1])[::-1], [0]))
    score = left_wd + right_stay
    i = int(np.argmax(score))
    if i == 0:
        return xs[0], score[i] / n
    if i == n:
        return xs[-1], score[i] / n
    return 0.5 * (xs[i - 1] + xs[i]), score[i] / n


def cluster_boot(groups, stat, B, rng):
    """95% percentile interval of stat over runs resampled with replacement."""
    k = len(groups)
    vals = []
    for _ in range(B):
        pick = rng.integers(0, k, k)
        vals.append(stat([groups[j] for j in pick]))
    vals = np.asarray(vals, dtype=float)
    return np.nanpercentile(vals, 2.5), np.nanpercentile(vals, 97.5)


def arm_depth(arm):
    """The arm's Monte Carlo depth: mc_depth in its manifest.csv, one value for the arm."""
    man = arm / "manifest.csv"
    if not man.exists():
        sys.exit(f"{man} not found: pass --depth")
    d = pd.read_csv(man).mc_depth.dropna().unique()
    if len(d) != 1:
        sys.exit(f"{man}: mc_depth is not one value ({list(d)}): pass --depth")
    return int(d[0])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("arm", help="arm output directory holding consolidated_oneshot.csv")
    ap.add_argument("--bridge", default=str(ROOT / "outputs" / "analysis" / "nest_bridge.csv"))
    ap.add_argument("--y", type=float, required=True, help="the arm's stale public level")
    ap.add_argument("--boot", type=int, default=500)
    ap.add_argument("--seed", type=int, default=20261031)
    ap.add_argument("-o", "--out", default=None, help="CSV of the per cell x type results")
    ap.add_argument("--depth", type=int, default=None,
                    help="override the Monte Carlo depth read from the arm's manifest.csv")
    args = ap.parse_args()
    arm = Path(args.arm)
    depth = args.depth if args.depth is not None else arm_depth(arm)
    os_ = pd.read_csv(arm / "consolidated_oneshot.csv")
    br = pd.read_csv(args.bridge)
    br = br[np.isclose(br.y, args.y)]
    if br.empty:
        sys.exit(f"no bridge rows at y = {args.y}: rerun nest_bridge.py with --y {args.y}")
    n = replace(NB.Nest(), y=args.y, depth=depth)
    print(f"Monte Carlo depth D = {depth}")
    b_D = {}
    rng = np.random.default_rng(args.seed)
    rows = []
    for (mu, lI, lC), cell in os_.groupby(["mu", "lambdaI", "lambdaC"]):
        cell = cell.assign(type=np.where(np.abs(cell.individualism - lI) <= np.abs(cell.individualism - lC),
                                         "I", "C"))
        for J, om in (("I", lI), ("C", lC)):
            d = cell[cell.type == J]
            if d.empty:
                continue
            pred = br[(np.isclose(br.mu, mu)) & np.isclose(br.lambdaI, lI) & np.isclose(br.lambdaC, lC)
                      & (br.type == J)]
            if pred.empty:
                sys.exit(f"no bridge row for mu {mu}, lambda {lI}/{lC}, type {J}: rerun nest_bridge.py")
            if om not in b_D:
                b_D[om] = NB.cutoffs_b(n, om)[3]
            c_D, c_inf = b_D[om], float(pred.c_b_inf.iloc[0])
            c_a = " ".join(f"{v:.4f}" for v in pred.c_a.dropna())
            x, wd = d.x.to_numpy(float), d.withdrew.astype(bool).to_numpy()
            groups = [(g.x.to_numpy(float), g.withdrew.astype(bool).to_numpy()) for _, g in d.groupby("key")]
            base = dict(mu=mu, lambdaI=lI, lambdaC=lC, type=J, n=len(d), n_runs=len(groups),
                        n_wd=int(wd.sum()), c_b_D=c_D, c_b_inf=c_inf, c_a=c_a)
            identified = wd.any() and (~wd).any() and x.min() < c_D < x.max()
            if identified:
                c_hat, acc = best_split(x, wd)
                lo, hi = cluster_boot(groups, lambda gs: best_split(np.concatenate([g[0] for g in gs]),
                                                                    np.concatenate([g[1] for g in gs]))[0],
                                      args.boot, rng)
                verdict = "PASS" if lo <= c_D <= hi else "FAIL"
                rows.append(base | dict(test="cutoff", c_hat=c_hat, lo=lo, hi=hi, accuracy=acc,
                                        verdict=verdict))
            else:
                # no cutoff inside the signals: observed vs predicted withdrawal count
                ests = (1.0 - om) * x + om * n.y
                cache = {}
                def pw(e):
                    k = round(e, 4)
                    if k not in cache:
                        cache[k] = NB.p_withdraw_D(n, NB.p_solvent(n, k, om))
                    return cache[k]
                expected = float(sum(pw(e) for e in ests))
                lo, hi = cluster_boot(groups, lambda gs: float(sum(g[1].sum() for g in gs)), args.boot, rng)
                verdict = "PASS-COUNT" if lo <= expected <= hi or (wd.sum() == 0 and expected < 0.5) \
                    else "FAIL-COUNT"
                rows.append(base | dict(test="count", expected=expected, lo=lo, hi=hi, verdict=verdict))
    res = pd.DataFrame(rows)
    pd.set_option("display.width", 200)
    print(res.to_string(index=False, float_format=lambda v: f"{v:.4f}"))
    print("\nverdicts:", res.verdict.value_counts().to_dict())
    if args.out:
        res.to_csv(args.out, index=False)
        print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
