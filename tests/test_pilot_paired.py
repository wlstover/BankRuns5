#!/usr/bin/env python3
"""Ground-truth fixture for scripts/pilot_paired.py (the §4-§6 pilot reader).

A control and three arms in the consolidate_results.py schemas, keyed
`<timestamp>-<seed1>-<seed2>` with DIFFERENT timestamps per arm, so a pairing on
the key would pair nothing. Cells mu 0 / 0.5 / 1 at lambda 0.3/0.7 (gap 0.4); seed1
1 and 2 (the clusters), seed2 10 and 20 within each: four runs per cell.

  A  "move" arm, mu 0.5: control fails [0 0 1 0] -> 0.25, arm [1 1 1 0] -> 0.75;
     paired d [1 1 0 0], mean +0.5; cluster residual sums +1 and -1, so
     CR1 SE = sqrt(2 * 2 / 1) / 4 = 0.5. I - C gap: control 0.1, arm 0.3 -> +0.2.
  B  slope: at mu 1 the control fails [1 1 0 0], the arm [1 1 1 1]; at mu 0 the
     control never fails, the arm [1 0 0 0]. Per seed1, d(mu 1) - d(mu 0) = 0 - 0.5 and
     1 - 0 -> d slope +0.25, SE = sd(-0.5, 1) / sqrt(2) = 0.75.
  C  loss_exact in the arm only (lossStayers written from 10-31): I's at mu 0.5,
     run 1-10 = (40 - 30 + 20) / (100 - 10) = 1/3; no paired loss column.
  D  verdicts: "move" arm informative (one saturated cell of three); a copy of the
     control flat; an arm that fails everywhere saturated.
  E  the moved axis does not break the pairing (the arm's reserveRatio differs).

Run:  python3 tests/test_pilot_paired.py
"""

import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parent.parent
_passed = _failed = 0


def check(name, cond, detail=""):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f"  PASS  {name}")
    else:
        _failed += 1
        print(f"  FAIL  {name}  {detail}")


def close(a, b, tol=1e-9):
    return a is not None and not (isinstance(a, float) and math.isnan(a)) and abs(a - b) < tol


RUNS = [(1, 10), (1, 20), (2, 10), (2, 20)]


def write_arm(d, stamp, fails, gaps, reserve=0.05, loss=False):
    """fails[mu] = list over RUNS; gaps[mu] = (I depEndog, C depEndog) for mixed cells."""
    res, typ = [], []
    for mu, fl in fails.items():
        for (s1, s2), f in zip(RUNS, fl):
            key = f"task_{int(mu * 100)}-{stamp}-{s1}-{s2}"   # same seeds in every cell (common seeding)
            res.append(dict(task_id=1, paramSeed=s1, replication=1, k=6, p=0.05, reserveRatio=reserve,
                            depQuantile=0.0, sigma=2.5, warmupAlpha=0.1, mu=mu, lambdaI=0.3,
                            lambdaC=0.7, seed=s1, key=key, armTag=stamp, assignRule="warmup",
                            mcDepth=1000, completed="true", bankRun="true" if f else "false"))
            for J in ("I", "C"):
                present = (J == "I" and mu > 0) or (J == "C" and mu < 1)
                dep = (gaps.get(mu, (30.0, 20.0))[0 if J == "I" else 1]) if present else 0.0
                row = dict(task_id=1, key=key, armTag=stamp, reserveRatio=reserve, depQuantile=0.0,
                           sigma=2.5, k=6, p=0.05, mu=mu, lambdaI=0.3, lambdaC=0.7, type=J,
                           n=10 if present else 0, nExog=1 if present else 0, nEndog=3 if present else 0,
                           depTotal=100.0, depExog=10.0, depEndog=dep, paidExog=10.0,
                           paidEndog=dep - 10.0 if present else 0.0, depStayers=50.0,
                           posSumEndog=1.0, nFirstQuarter=0)
                if loss:
                    row["lossStayers"] = 20.0
                typ.append(row)
    os.makedirs(d, exist_ok=True)
    pd.DataFrame(res).to_csv(os.path.join(d, "consolidated_results.csv"), index=False)
    pd.DataFrame(typ).to_csv(os.path.join(d, "consolidated_types.csv"), index=False)


def main():
    with tempfile.TemporaryDirectory() as td:
        ctrl_f = {0.0: [0, 0, 0, 0], 0.5: [0, 0, 1, 0], 1.0: [1, 1, 0, 0]}
        write_arm(os.path.join(td, "ctrl"), "tc", ctrl_f, {0.5: (30.0, 20.0)})
        write_arm(os.path.join(td, "move"), "ta", {0.0: [1, 0, 0, 0], 0.5: [1, 1, 1, 0], 1.0: [1, 1, 1, 1]},
                  {0.5: (40.0, 10.0)}, reserve=0.10, loss=True)
        write_arm(os.path.join(td, "same"), "tb", ctrl_f, {0.5: (30.0, 20.0)})
        write_arm(os.path.join(td, "sat"), "td", {mu: [1, 1, 1, 1] for mu in ctrl_f}, {0.5: (30.0, 20.0)})
        out = os.path.join(td, "res.csv")
        p = subprocess.run([sys.executable, str(ROOT / "scripts" / "pilot_paired.py"), "--control",
                            os.path.join(td, "ctrl"), os.path.join(td, "move"), os.path.join(td, "same"),
                            os.path.join(td, "sat"), "-o", out], capture_output=True, text=True)
        check("runs", p.returncode == 0, p.stderr[-800:])
        if p.returncode:
            print(f"\n{_passed} PASS / {_failed} FAIL")
            return 1
        r = pd.read_csv(out)
        mv = r[(r.arm == "move") & (r.mu == 0.5)].iloc[0]
        print("=== A. paired P(fail) and gap, mu 0.5 ===")
        check("E: all four runs paired despite different keys and reserve", mv.runs == 4, mv.runs)
        check("P ctrl 0.25, arm 0.75", close(mv.fail_ctrl, 0.25) and close(mv.fail, 0.75))
        check("d P +0.5, CR1 SE 0.5", close(mv.d_fail, 0.5) and close(mv.se_fail, 0.5), (mv.d_fail, mv.se_fail))
        check("gap ctrl 0.1, arm 0.3, d +0.2", close(mv.gap_ctrl, 0.1) and close(mv.gap_arm, 0.3)
              and close(mv.d_gap, 0.2))
        check("no gap at the endpoints", r[(r.arm == "move") & (r.mu == 0.0)].d_gap.isna().all())
        print("=== B. slope in mu ===")
        line = [l for l in p.stdout.splitlines() if "d slope" in l]
        check("move arm: d slope +0.250 (0.750)", bool(line) and "+0.250 (0.750)" in line[0], line[:1])
        print("=== C. loss_exact, arm only ===")
        check("loss I = 1/3 at mu 0.5", close(mv.loss_I, 1 / 3))
        check("no paired loss when the control lacks lossStayers", "d_loss_I" not in r.columns)
        print("=== D. reading rule ===")
        summ = p.stdout.split("\nsummary\n")[1]
        verdict = {ln.split()[0]: ln.split()[1] for ln in summ.splitlines()[1:] if ln.strip()
                   and not ln.startswith("wrote")}
        check("move -> informative", verdict.get("move") == "informative", verdict)
        check("copy of the control -> flat", verdict.get("same") == "flat", verdict)
        check("fails everywhere -> saturated", verdict.get("sat") == "saturated", verdict)
    print(f"\n{_passed} PASS / {_failed} FAIL")
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
