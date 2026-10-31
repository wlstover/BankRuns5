#!/usr/bin/env python3
"""Summary of the CARA smoke (scripts/cara_smoke.sh; 2026-10-22).

Per CARA value: P(fail) and its type, who runs (W_I, W_C, D = W_I - W_C among
agents not hit by the shock), the deposit share withdrawn, and how much
splitting there is (partial withdrawals per run, agents left holding part of
their balance). Paired with CARA 0 run for run: how often failure changes.

Deliberately NOT reported: splitting by depositor size. That is rung-4 S1's
statistic, and the CARA value has to be chosen before S1 is looked at
(docs/rung4_prereg.md; Ch 2 evaluates, never shapes).

Usage:
    python3 scripts/cara_smoke.py [--dir outputs/cara_smoke]
"""

import argparse
from pathlib import Path

import pandas as pd

TYPES = ["key", "type", "n", "nExog", "nEndog", "depTotal", "depExog", "depEndog", "paidExog",
         "paidEndog", "depStayers", "posSumEndog", "nFirstQuarter", "nInsured", "nEndogInsured",
         "depUninsured", "depStayersUninsured", "nStayersUninsured", "lossStayers"]
BALANCE = ["key", "theta", "returnTheta", "vaultInit", "illiquidInit", "vaultFinal",
           "illiquidFinal", "assetsT", "promises", "solvent", "failType",
           "largestShare", "largestToCapacity", "largestWithdrew"]
PARTIAL = ["key", "nAnyOut", "nStillIn", "nPartialEvents", "nBigDecisions", "withdrawnShare",
           "largestFracWithdrawn"]


def read(d, stem, cols):
    return pd.read_csv(d / f"{stem}1.csv", header=None, names=cols)


def one(d):
    res = pd.read_csv(d / "bankRunResults1.csv", header=None,
                      names=["key", "failed", "nWithdrawn", "depositWithdrawn"])
    t = read(d, "bankRunTypes", TYPES)
    t["W"] = t.nEndog / (t.n - t.nExog)
    w = t.pivot(index="key", columns="type", values="W")
    bal = read(d, "bankRunBalance", BALANCE)
    par = read(d, "bankRunPartial", PARTIAL)
    m = res.merge(bal[["key", "theta", "failType"]], on="key").merge(par, on="key")
    m = m.merge(w.rename(columns=lambda c: f"W_{c}"), left_on="key", right_index=True)
    m["failed"] = m.failed.astype(str).str.lower() == "true"
    return m


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", type=Path, default=Path("outputs/cara_smoke"))
    a = ap.parse_args()
    runs = {}
    for d in sorted(a.dir.glob("g*")):
        if d.is_dir() and (d / "bankRunResults1.csv").exists():
            runs[float(d.name[1:])] = one(d)
    base = runs.get(0.0)
    rows = []
    for g, m in sorted(runs.items()):
        wi = m.get("W_I", m.filter(like="W_").iloc[:, 0])
        wc = m.get("W_C", m.filter(like="W_").iloc[:, -1])
        r = dict(cara=g, runs=len(m), P_fail=m.failed.mean(),
                 liquidity=(m.failType == "liquidity").mean(),
                 W_I=wi.mean(), W_C=wc.mean(), D=(wi - wc).mean(),
                 dep_share_out=m.withdrawnShare.mean(),
                 partial_per_run=m.nPartialEvents.mean(),
                 runs_with_partial=(m.nPartialEvents > 0).mean(),
                 still_in_per_run=m.nStillIn.mean())
        if base is not None and g != 0.0:
            p = m.merge(base[["key", "failed"]], on="key", suffixes=("", "_0"))
            r["fail_changed_vs_0"] = (p.failed != p.failed_0).mean()
        rows.append(r)
    pd.set_option("display.width", 200)
    print(pd.DataFrame(rows).round(3).to_string(index=False))


if __name__ == "__main__":
    main()
