#!/usr/bin/env python3
"""L1 null check: repeated episodes with no learning (docs/learning_design.md §3; 2026-10-28).

With BANKRUN_EPISODES = E and no learning, a run is E independent draws (theta, shock,
private signals) on one population, so nothing may trend across episodes. Reads an
arm's consolidated_episodes.csv (consolidate_results.py) and reports, by episode:

  P(fail), with a CR1 standard error clustered on the initialisation (seed1, the
      population; as in rung1_relational.cmean), and the slope of P(fail) on the
      episode number (clustered; should be ~0);
  the endogenous withdrawal share of deposits by type, and the I - C gap;
  lambda by type, which must not move at all without learning (max change printed).

With --ref <arm dir> (the single-episode arm with the same switches and common
seeding, e.g. outputs/r1k-none): episode 1 must equal the reference run for run
(the same model and seeds), and P(fail) pooled over episodes 2..E is compared with
the reference's P(fail) on the same cells.

Usage:
    python3 scripts/episodes_null.py --arm outputs/lrn-null [--ref outputs/r1k-none]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

CELL = ["mu", "lambdaI", "lambdaC"]


def seeds_of(key: pd.Series) -> pd.DataFrame:
    """seed1, seed2 from keys `<timestamp>-<seed1>-<seed2>` (timestamps differ by arm)."""
    parts = key.str.rsplit("-", n=2, expand=True)
    return pd.DataFrame({"seed1": parts[1].astype(int), "seed2": parts[2].astype(int)},
                        index=key.index)


def cr1(y: np.ndarray, x: np.ndarray, g: np.ndarray) -> tuple[float, float]:
    """OLS slope of y on x (with intercept) and its CR1 standard error clustered on g."""
    X = np.column_stack([np.ones_like(x, dtype=float), x.astype(float)])
    XtX_inv = np.linalg.inv(X.T @ X)
    beta = XtX_inv @ X.T @ y
    u = y - X @ beta
    groups = pd.unique(g)
    meat = np.zeros((2, 2))
    for k in groups:
        s = (X[g == k] * u[g == k, None]).sum(axis=0)
        meat += np.outer(s, s)
    G, n = len(groups), len(y)
    if G < 2:                      # one initialisation: no clustered s.e.
        return beta[1], float("nan")
    V = XtX_inv @ meat @ XtX_inv * (G / (G - 1)) * ((n - 1) / (n - 2))
    return beta[1], float(np.sqrt(V[1, 1]))


def cmean(y: np.ndarray, g: np.ndarray) -> tuple[float, float]:
    """Mean of y and its CR1 standard error clustered on g."""
    m = y.mean()
    s = pd.Series(y - m).groupby(g).sum().to_numpy()
    G, n = len(s), len(y)
    if G < 2:
        return m, float("nan")
    return m, float(np.sqrt((s ** 2).sum() * G / (G - 1)) / n)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True, type=Path)
    ap.add_argument("--ref", type=Path)
    a = ap.parse_args()

    ep = pd.read_csv(a.arm / "consolidated_episodes.csv")
    ep = ep.join(seeds_of(ep["key"]).rename(columns={"seed2": "runSeed2"}))
    ep["failed"] = ep["failed"].astype(str).str.lower() == "true"
    ep["wdShare"] = ep["depEndog"] / ep["depTotal"]
    E = int(ep["episode"].max())
    runs = ep.drop_duplicates(["key", "episode"])
    print(f"arm {a.arm}: {runs['key'].nunique()} runs x {E} episodes, "
          f"{runs.groupby(CELL).ngroups} cell(s), {runs['seed1'].nunique()} initialisations")

    print("\nP(fail) by episode (CR1 s.e., clustered on the initialisation)")
    for e, d in runs.groupby("episode"):
        m, se = cmean(d["failed"].to_numpy(float), d["seed1"].to_numpy())
        print(f"  {e:>3}  {m:.3f}  ({se:.3f})")
    b, se = cr1(runs["failed"].to_numpy(float), runs["episode"].to_numpy(), runs["seed1"].to_numpy())
    print(f"  slope on episode: {b:+.4f} per episode (s.e. {se:.4f}, t {b / se if se else float('nan'):+.2f})")

    print("\nEndogenous withdrawal share of deposits by type, and I - C")
    w = ep.pivot_table(index=["key", "episode", "seed1"], columns="type", values="wdShare").reset_index()
    w["gap"] = w.get("I", np.nan) - w.get("C", np.nan)
    for e, d in w.groupby("episode"):
        print(f"  {e:>3}  I {d['I'].mean():.3f}  C {d['C'].mean():.3f}  I - C {d['gap'].mean():+.3f}")
    gd = w.dropna(subset=["gap"])
    b, se = cr1(gd["gap"].to_numpy(), gd["episode"].to_numpy(), gd["seed1"].to_numpy())
    print(f"  I - C slope on episode: {b:+.4f} (s.e. {se:.4f})")

    drift = ep.groupby(["key", "type"])["lambdaMean"].agg(lambda s: s.max() - s.min()).max()
    print(f"\nlambda by type: largest change within a run {drift:.2e} (must be 0 without learning)")
    ok = drift == 0

    if a.ref:
        ref = pd.read_csv(a.ref / "consolidated_results.csv")
        ref = ref[ref["completed"].astype(str).str.lower() == "true"]
        ref = ref.join(seeds_of(ref["key"]))
        ref["failed"] = ref["bankRun"].astype(str).str.lower() == "true"
        cells = runs[CELL].drop_duplicates()
        ref = ref.merge(cells, on=CELL)
        e1 = runs[runs["episode"] == 1].merge(
            ref[CELL + ["seed1", "seed2", "failed"]].rename(columns={"seed2": "runSeed2",
                                                                     "failed": "refFailed"}),
            on=CELL + ["seed1", "runSeed2"], how="left")
        matched = e1["refFailed"].notna()
        agree = (e1.loc[matched, "failed"] == e1.loc[matched, "refFailed"].astype(bool)).mean()
        print(f"\nvs {a.ref}: episode 1 matched {matched.sum()} of {len(e1)} runs; "
              f"failure agrees in {agree:.1%} (must be 100%)")
        ok &= bool(matched.all()) and agree == 1.0
        later = runs[runs["episode"] >= 2]
        m, se = cmean(later["failed"].to_numpy(float), later["seed1"].to_numpy())
        mr, ser = cmean(ref["failed"].to_numpy(float), ref["seed1"].to_numpy())
        print(f"  P(fail), episodes 2..{E} pooled: {m:.3f} ({se:.3f});  reference: {mr:.3f} ({ser:.3f});  "
              f"difference {m - mr:+.3f} (z {(m - mr) / np.hypot(se, ser):+.2f})")

    print("\nnull check:", "lambda constant" + (" and episode 1 = reference" if a.ref else ""),
          "PASS" if ok else "FAIL", "(the P(fail) and I - C slopes are for reading, not a gate)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
