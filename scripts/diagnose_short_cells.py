#!/usr/bin/env python3
"""
Why do some cells finish exactly one run short?

`sweep_status.sh` reports cells that exited COMPLETED holding 249 of 250 runs
(2.5% of the production arm, 3.5% of the placebo arm, 2026-08-19). Three
hypotheses were on the table:

  H1  torn result lines            (next_steps item 27) -- fifteen workers append
                                    to bankRunResults<core>.csv with no
                                    coordination; a torn line reads as a missing
                                    run. Measured at 1.69% of rows in
                                    bankRunEndogenous1.csv.
  H2  checkOff lock race           (next_steps item 18) -- checkOff() is not under
                                    rowLock though rowPull() is.
  H3  check-off-before-write race at task teardown -- functions4.jl modelCall()
                                    calls checkOff() BEFORE writing its result
                                    row, and finMain0001.jl:149 exits the master
                                    loop on sum(completed) == nrow. The worker
                                    that checks off the final row then polls at
                                    sleep(1) granularity before it writes, so the
                                    master can tear down the worker pool inside
                                    that window and the row is never written.

H2 is already refutable from source: checkOff() runs on process 1 via
@spawnat 1, master-side tasks are cooperatively scheduled on one thread, and
`jointFrame[i,:completed]=true` contains no yield point, so two checkOffs cannot
interleave. It is asymmetric, not racy.

H1 and H3 make opposite predictions about WHERE the missing run sits in the
frame, and that is what this script measures.

  H1 predicts  the missing key is uniform over the 250 rows, and torn lines are
               visible in bankRunResults*.csv as rows with a field count != 4.
  H3 predicts  the missing key is one of the last few rows to be pulled (rows are
               pulled in frame order by rowPull()'s findfirst), that it is marked
               completed=true in the master's own ledger bankRunParametersFin.csv,
               and that the run genuinely executed -- so its agent rows ARE in
               agents*.csv, because those are written at model generation, long
               before the result row.

Usage
-----
    python3 scripts/diagnose_short_cells.py --arm-dir outputs/production
    python3 scripts/diagnose_short_cells.py --arm-dir outputs/placebo --check-agents
    python3 scripts/diagnose_short_cells.py --arm-dir outputs/production \\
            --tasks 1006,1040,1071 --check-agents -v

Reads only. Writes nothing.
"""

import argparse
import csv
import os
import re
import sys
from collections import Counter

RESULT_FIELDS = 4          # key, result, nWithdrawn, depositWithdrawn (widened 2026-08-13)
FIN_FIELDS = 3             # key, started, completed
DEFAULT_RUNS = 250         # a cell is 250 runs; see functions4.jl:495 and item "a cell is 250"


# ---------------------------------------------------------------- file readers

def read_result_keys(task_dir):
    """Keys from every bankRunResults<core>.csv in the task dir.

    Returns (keys, n_lines, malformed) where `malformed` lists
    (filename, lineno, nfields, raw[:80]) for any line whose field count is not
    RESULT_FIELDS. A torn line is the H1 signature and must be counted, not
    silently dropped -- a padding reader would hide exactly what we are looking
    for (2026-08-17: the strict reader is how the 6-column exogenous file was
    found at all).
    """
    keys = []
    n_lines = 0
    malformed = []
    files = sorted(f for f in os.listdir(task_dir)
                   if re.fullmatch(r"bankRunResults\d+\.csv", f))
    for fn in files:
        path = os.path.join(task_dir, fn)
        with open(path, newline="") as fh:
            for lineno, row in enumerate(csv.reader(fh), start=1):
                n_lines += 1
                if len(row) != RESULT_FIELDS:
                    malformed.append((fn, lineno, len(row), ",".join(row)[:80]))
                    continue
                keys.append(row[0])
    return keys, n_lines, malformed, files


def read_fin_ledger(task_dir):
    """The master's own record: bankRunParametersFin.csv, in jointFrame order.

    Returns (rows, malformed) with rows a list of (key, started, completed) in
    file order, which IS frame order -- finMain0001.jl:180 writes
    jointFrame[:,[:key,:started,:completed]] unsorted.
    """
    path = os.path.join(task_dir, "bankRunParametersFin.csv")
    if not os.path.exists(path):
        return None, []
    rows = []
    malformed = []
    with open(path, newline="") as fh:
        for lineno, row in enumerate(csv.reader(fh), start=1):
            if len(row) != FIN_FIELDS:
                malformed.append((os.path.basename(path), lineno, len(row),
                                  ",".join(row)[:80]))
                continue
            rows.append((row[0], row[1].strip().lower(), row[2].strip().lower()))
    return rows, malformed


def agent_row_count(task_dir, key):
    """How many agents*.csv rows carry this key.

    A run that executed writes agtCnt rows at model generation (functions4.jl:110),
    which happens before the cascade and long before the result row. So agent rows
    present + result row absent == the run ran and its result was lost on the way
    out. That is H3. Zero agent rows would mean the run never started, which is a
    different and much worse story.
    """
    n = 0
    for fn in sorted(os.listdir(task_dir)):
        if not re.fullmatch(r"agents\d+\.csv", fn):
            continue
        with open(os.path.join(task_dir, fn), newline="") as fh:
            for line in fh:
                # substring test first: the key is the leading field, and this
                # avoids csv-parsing ~250k rows per cell for nothing
                if line.startswith(key):
                    n += 1
    return n


# ---------------------------------------------------------------- per-cell work

def diagnose_cell(task_dir, expected, check_agents):
    """Returns a dict of findings for one task directory."""
    name = os.path.basename(task_dir)
    out = {"task": name, "ok": True, "note": None}

    keys, n_result_lines, res_malformed, res_files = read_result_keys(task_dir)
    fin, fin_malformed = read_fin_ledger(task_dir)

    out["n_result_rows"] = len(keys)
    out["n_result_lines"] = n_result_lines
    out["result_malformed"] = res_malformed
    out["result_files"] = res_files
    out["dup_result_keys"] = [k for k, c in Counter(keys).items() if c > 1]

    if fin is None:
        out["ok"] = False
        out["note"] = ("no bankRunParametersFin.csv -- the master never reached "
                       "finMain0001.jl:180, so this task did not exit cleanly")
        out["n_fin_rows"] = None
        return out

    out["n_fin_rows"] = len(fin)
    out["fin_malformed"] = fin_malformed
    out["n_fin_completed"] = sum(1 for _, _, c in fin if c == "true")
    out["n_fin_started"] = sum(1 for _, s, _ in fin if s == "true")

    have = set(keys)
    missing = [(i, k, s, c) for i, (k, s, c) in enumerate(fin, start=1)
               if k not in have]
    out["missing"] = []
    for pos, k, started, completed in missing:
        rec = {
            "frame_pos": pos,
            "from_end": len(fin) - pos,          # 0 == last row of the frame
            "key": k,
            "started": started,
            "completed": completed,
            "agent_rows": None,
        }
        if check_agents:
            rec["agent_rows"] = agent_row_count(task_dir, k)
        out["missing"].append(rec)

    out["expected"] = expected
    return out


# ---------------------------------------------------------------- arm-level work

def find_task_dirs(arm_dir, tasks):
    if tasks:
        wanted = {f"task_{t.strip()}" for t in tasks.split(",") if t.strip()}
        dirs = [os.path.join(arm_dir, d) for d in sorted(wanted)]
        for d in dirs:
            if not os.path.isdir(d):
                sys.exit(f"ERROR: no such task dir: {d}")
        return dirs
    return [os.path.join(arm_dir, d) for d in sorted(
        (x for x in os.listdir(arm_dir) if re.fullmatch(r"task_\d+", x)),
        key=lambda x: int(x.split("_")[1]))]


def main():
    ap = argparse.ArgumentParser(
        description="Locate the missing run in cells that finished short.")
    ap.add_argument("--arm-dir", required=True,
                    help="e.g. outputs/production")
    ap.add_argument("--tasks", default=None,
                    help="comma-separated task ids; default is every short cell in the arm")
    ap.add_argument("--expected", type=int, default=DEFAULT_RUNS,
                    help=f"runs per cell (default {DEFAULT_RUNS})")
    ap.add_argument("--check-agents", action="store_true",
                    help="confirm the missing run executed by counting its agents*.csv rows "
                         "(slow: scans ~250k rows per cell)")
    ap.add_argument("--max-cells", type=int, default=0,
                    help="stop after this many SHORT cells (0 = no limit)")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print every short cell, not just the summary")
    args = ap.parse_args()

    if not os.path.isdir(args.arm_dir):
        sys.exit(f"ERROR: no such arm directory: {args.arm_dir}")

    task_dirs = find_task_dirs(args.arm_dir, args.tasks)
    if not task_dirs:
        sys.exit(f"ERROR: no task_* directories under {args.arm_dir} -- "
                 "a diagnostic that can see no work has diagnosed nothing")

    print("=" * 70)
    print(f"SHORT-CELL DIAGNOSIS — {args.arm_dir}")
    print(f"  {len(task_dirs)} task dir(s) to scan, expecting {args.expected} runs each")
    print("=" * 70)

    short, clean, broken = [], 0, []
    from_end_hist = Counter()
    torn_lines = 0
    not_completed = 0
    never_ran = 0
    ran_but_lost = 0
    surplus = []

    for td in task_dirs:
        rep = diagnose_cell(td, args.expected, args.check_agents)
        if not rep["ok"]:
            broken.append(rep)
            continue
        n = rep["n_result_rows"]
        if n == args.expected and not rep["result_malformed"]:
            clean += 1
            continue
        if n > args.expected:
            surplus.append(rep)
            continue
        short.append(rep)
        torn_lines += len(rep["result_malformed"])
        for m in rep["missing"]:
            from_end_hist[m["from_end"]] += 1
            if m["completed"] != "true":
                not_completed += 1
            if m["agent_rows"] is not None:
                if m["agent_rows"] == 0:
                    never_ran += 1
                else:
                    ran_but_lost += 1
        if args.verbose:
            print(f"\n-- {rep['task']}: {n}/{args.expected} result rows, "
                  f"{rep['n_fin_completed']}/{rep['n_fin_rows']} marked completed "
                  f"by the master")
            if rep["result_malformed"]:
                print(f"   TORN result lines: {len(rep['result_malformed'])}")
                for fn, ln, nf, raw in rep["result_malformed"][:3]:
                    print(f"     {fn}:{ln}  {nf} fields  |{raw}|")
            if rep["dup_result_keys"]:
                print(f"   duplicate result keys: {len(rep['dup_result_keys'])}")
            for m in rep["missing"]:
                extra = ("" if m["agent_rows"] is None
                         else f", agents*.csv rows = {m['agent_rows']}")
                print(f"   missing key at frame position {m['frame_pos']}"
                      f"/{rep['n_fin_rows']} ({m['from_end']} from the end), "
                      f"started={m['started']} completed={m['completed']}{extra}")
        if args.max_cells and len(short) >= args.max_cells:
            print(f"\n[stopped after {args.max_cells} short cells as requested — "
                  f"{len(task_dirs) - task_dirs.index(td) - 1} dirs not scanned]")
            break

    # ------------------------------------------------------------- the verdict
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"  cells at exactly {args.expected} runs : {clean}")
    print(f"  cells SHORT                    : {len(short)}")
    print(f"  cells with MORE than {args.expected}     : {len(surplus)}"
          + ("   <-- a --restart top-up appends a fresh block" if surplus else ""))
    print(f"  cells with no Fin ledger       : {len(broken)}")
    for rep in broken:
        print(f"      {rep['task']}: {rep['note']}")

    if not short:
        print("\n  Nothing short in this scan.")
        return 0

    n_missing = sum(len(r["missing"]) for r in short)
    print(f"\n  missing runs total             : {n_missing}")
    print(f"  torn lines in bankRunResults*  : {torn_lines}")
    print(f"  missing runs NOT marked completed by the master : {not_completed}")
    if args.check_agents:
        print(f"  missing runs that never executed (0 agent rows) : {never_ran}")
        print(f"  missing runs that DID execute (agent rows present): {ran_but_lost}")

    print("\n  Where the missing run sits in the frame (0 = last row pulled):")
    tail = sum(c for d, c in from_end_hist.items() if d < 20)
    for d in sorted(from_end_hist)[:15]:
        print(f"    {d:4d} from end : {from_end_hist[d]}")
    if len(from_end_hist) > 15:
        print(f"    ... {len(from_end_hist) - 15} further positions")
    print(f"\n  within the last 20 rows : {tail}/{n_missing} "
          f"({100.0 * tail / n_missing:.1f}%)")
    print(f"  uniform-position null   : {100.0 * 20 / args.expected:.1f}% expected "
          f"if the loss were positionally random (H1)")

    print("\n  VERDICT")
    if torn_lines > 0:
        print("    * bankRunResults*.csv DOES tear (H1 is live) — see the torn lines above.")
    else:
        print("    * bankRunResults*.csv shows NO torn lines. H1 (item 27) does not")
        print("      explain these cells: the endogenous file tears, the results file")
        print("      does not, because a result row is one line per run rather than")
        print("      one per decision, so the collision rate is orders of magnitude lower.")
    if n_missing and tail / n_missing > 0.8:
        print("    * The missing run is concentrated at the END of the frame. That is H3:")
        print("      modelCall() checks off before it writes, and finMain0001.jl:149 exits")
        print("      the master loop the instant the last row is checked off. The worker")
        print("      polls checkOff at sleep(1) granularity, so it can still be inside")
        print("      that poll when the pool is torn down.")
        print("      FIX: move the CSV.write above the checkOff block in modelCall()")
        print("      (functions4.jl). One reorder, no behavioural change. Schuler's file —")
        print("      check `git diff --stat -w` against `git diff --stat` before committing,")
        print("      and batch it into the item-12 message.")
    elif n_missing:
        print("    * The missing run is NOT concentrated at the end of the frame, so H3")
        print("      does not explain it either. Do not write a mechanism into the chapter")
        print("      until one of these predictions actually fits.")
    if not_completed:
        print(f"    * {not_completed} missing run(s) were never marked completed by the")
        print("      master. Those are a different failure from the teardown race — the")
        print("      master loop cannot exit while any row is incomplete, so a task that")
        print("      exited COMPLETED with an unfinished row was killed from outside.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
