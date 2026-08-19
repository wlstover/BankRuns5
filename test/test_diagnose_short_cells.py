#!/usr/bin/env python3
"""Ground-truth fixtures for scripts/diagnose_short_cells.py.

The diagnostic has to tell three stories apart on real data, so it is tested the
way scripts/viz_cascade.py's view 3 was: TWO-SIDED. A detector permanently stuck
on one verdict passes a one-sided test and is worthless.

Fixtures, and what each one is:

  task_1  clean 250-run cell                    -> not short
  task_2  H3, missing run is the LAST frame row -> teardown race
  task_3  H3, missing run one from the end      -> teardown race
  task_4  H1, torn line mid-frame               -> tearing (item 27)
  task_5  missing row never marked completed    -> killed from outside
  task_6  missing row has no agent rows         -> the run never executed
  task_7  253 rows                              -> a --restart top-up
  task_8  no bankRunParametersFin.csv           -> master never exited cleanly

Run:  python3 test/test_diagnose_short_cells.py
"""

import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, os.pardir, "scripts", "diagnose_short_cells.py")

N = 250
NWORKERS = 15

_passed = 0
_failed = 0


def check(name, cond, detail=""):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f"  PASS  {name}")
    else:
        _failed += 1
        print(f"  FAIL  {name}   {detail}")


def keys():
    return [f"2026-08-17T00:00:00.0-{i}-{1000 + i}" for i in range(N)]


def build(arm, task, missing_pos=None, torn=False, completed_true=True,
          agents=True, surplus=0, fin=True):
    d = os.path.join(arm, f"task_{task}")
    os.makedirs(d, exist_ok=True)
    ks = keys()

    if fin:
        with open(os.path.join(d, "bankRunParametersFin.csv"), "w") as f:
            for i, k in enumerate(ks, 1):
                c = "false" if (missing_pos == i and not completed_true) else "true"
                f.write(f"{k},true,{c}\n")

    files = {c: open(os.path.join(d, f"bankRunResults{c}.csv"), "w")
             for c in range(2, 2 + NWORKERS)}
    for i, k in enumerate(ks, 1):
        if missing_pos == i:
            if torn:                      # the bytes are there, the row is not
                files[2 + (i % NWORKERS)].write(f"{k}\n")
            continue
        files[2 + (i % NWORKERS)].write(
            f"{k},true,{random.randint(0, 640)},{random.random() * 1e6:.2f}\n")
    for s in range(surplus):
        files[3].write(f"EXTRA-{s},true,1,1.0\n")
    for f in files.values():
        f.close()

    with open(os.path.join(d, "agents2.csv"), "w") as f:
        for i, k in enumerate(ks, 1):
            if not agents and missing_pos == i:
                continue
            for j in range(1, 21):
                f.write(f"{k},{j},100.0,0.5,0.5,I\n")


def run(arm, tasks=None, check_agents=True):
    cmd = [sys.executable, SCRIPT, "--arm-dir", arm]
    if tasks:
        cmd += ["--tasks", tasks]
    if check_agents:
        cmd += ["--check-agents"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        raise SystemExit(f"diagnostic exited {r.returncode}")
    return r.stdout


def main():
    random.seed(11)
    tmp = tempfile.mkdtemp(prefix="short_cells_")
    arm = os.path.join(tmp, "arm")
    os.makedirs(arm)

    build(arm, 1)
    build(arm, 2, missing_pos=250)
    build(arm, 3, missing_pos=249)
    build(arm, 4, missing_pos=61, torn=True)
    build(arm, 5, missing_pos=250, completed_true=False)
    build(arm, 6, missing_pos=250, agents=False)
    build(arm, 7, surplus=3)
    build(arm, 8, missing_pos=None, fin=False)

    print("test_diagnose_short_cells")

    # --- the positive control: a pure teardown-race arm must say H3 ------------
    out = run(arm, tasks="2,3")
    check("pure H3 arm -> concentrated at END", "concentrated at the END" in out)
    check("pure H3 arm -> exonerates tearing", "shows NO torn lines" in out)
    check("pure H3 arm -> names the fix", "move the CSV.write above the checkOff" in out)
    check("pure H3 arm -> 2 missing runs", "missing runs total             : 2" in out)
    check("pure H3 arm -> both ran", "DID execute (agent rows present): 2" in out)

    # --- the negative control: a pure tearing arm must NOT say H3 -------------
    out = run(arm, tasks="4")
    check("pure H1 arm -> tearing detected", "DOES tear" in out)
    check("pure H1 arm -> refuses H3", "NOT concentrated at the end" in out)

    # --- a clean cell is not short -------------------------------------------
    out = run(arm, tasks="1")
    check("clean cell -> nothing short", "Nothing short in this scan" in out)

    # --- the two look-alikes that are NOT either hypothesis -------------------
    out = run(arm, tasks="5")
    check("uncompleted row flagged separately",
          "never marked completed by the" in out)
    out = run(arm, tasks="6")
    check("run that never executed is flagged",
          "never executed (0 agent rows) : 1" in out)

    # --- surplus and missing-ledger cells are classified, not crashed on ------
    out = run(arm, tasks="7")
    check("surplus cell -> restart top-up", "cells with MORE than 250     : 1" in out)
    out = run(arm, tasks="8")
    check("no Fin ledger -> did not exit cleanly", "did not exit cleanly" in out)

    # --- an empty arm must not read as a pass (08-17 monitoring bug 3) --------
    empty = os.path.join(tmp, "empty")
    os.makedirs(empty)
    r = subprocess.run([sys.executable, SCRIPT, "--arm-dir", empty],
                       capture_output=True, text=True)
    check("empty arm refuses to pass", r.returncode != 0,
          f"exited {r.returncode}")

    print(f"\n{_passed} PASS / {_failed} FAIL")
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
