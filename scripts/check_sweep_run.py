#!/usr/bin/env python3
"""check_sweep_run.py — post-run verifier for a BankRuns5 sweep arm.

The ABM counterpart of celsius/src/audit/check_analysis_run.py, and it exists
for the same reason: the SLURM exit state is not a completion signal.

Chapter 1's version of that problem is `stata-mp -b` returning 0 on a dead
do-file. Julia does propagate a nonzero exit, so this script is not chasing
masked crashes — it is chasing the failure mode the 2026-04 sweep actually hit:

  * TIMEOUT at the walltime, leaving a task directory with some of its 50 runs.
    ~25% of runs carried no terminal outcome record and nobody noticed for
    months, because the array job's per-task states were never aggregated.
  * Silent replication surplus. restart.jl is not wired in (finMain0001.jl:90),
    so a re-submitted task appends a fresh 50-run block under new keys instead
    of resuming. The 2026-04 sweep accumulated ~612 runs/cell against a
    documented 50 — more precision than claimed, but the documented figure was
    wrong and no tool said so.
  * Legacy parameter dumps that predate the sigma fix (12 columns, no sigma),
    which cannot be distinguished from current ones except by width.

Usage:
    python3 scripts/check_sweep_run.py --arm-dir outputs/production \\
            [--manifest outputs/production/manifest.csv] [--job-id 12345]

    # the 2026-04 legacy sweep, which has no manifest:
    python3 scripts/check_sweep_run.py --arm-dir outputs

Exit status: 1 if any FAIL, else 0. WARN never fails the job — a chaser that
goes red on expected conditions gets ignored, which is the failure mode this
whole thing guards against.
"""

import argparse
import csv
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

# ⚠️ 250, not 50 — corrected 2026-08-17. parameterGen.jl:111 is
#     seed1 = repeat(sample(1:1000000, seedRun, replace=false), seedRun)
# which yields 25 seedFrame rows (5 distinct seeds, each repeated 5x),
# crossjoined with iteration 1:runSize=10 -> 250 rows per cell. `iteration`
# never reaches the model, so the structure is 5 initialisations x 50 shock
# draws, NOT the "5 x 10 = 50" described at parameterGen.jl:39-42. Confirmed
# against the legacy sweep: 2,833 of 2,835 cells hold exactly 250 rows with
# exactly 5 distinct seed1.
#
# This was 50 until 2026-08-17, and the consequence was not cosmetic. Every
# healthy cell would have been reported "surplus" (2,160 NOTE lines, drowning
# the signal), and — the real problem — a TIMEOUT'd cell holding 51-249 of its
# 250 runs would have been classified surplus, i.e. GREEN, when it is exactly
# the failure this verifier exists to catch. check_recording.sh was corrected
# on 2026-08-15; this file was missed.
EXPECTED_RUNS_PER_CELL = 250

# bankRunParametersInit.csv width. 12 = pre-sigma-fix; 14 = with lognMu/lognSigma.
LEGACY_PARAM_COLS = 12

BAD_SLURM_STATES = ("TIMEOUT", "FAILED", "OUT_OF_MEMORY", "CANCELLED", "NODE_FAIL")


def read_rows(paths):
    """Total data rows across a set of headerless CSVs."""
    n = 0
    for p in paths:
        try:
            with open(p, newline="") as fh:
                n += sum(1 for line in fh if line.strip())
        except OSError:
            pass
    return n


def first_column_values(paths):
    """Every key (column 0) across a set of headerless CSVs."""
    keys = []
    for p in paths:
        try:
            with open(p, newline="") as fh:
                for row in csv.reader(fh):
                    if row:
                        keys.append(row[0])
        except OSError:
            pass
    return keys


def param_dump_width(task_dir):
    f = task_dir / "bankRunParametersInit.csv"
    if not f.exists():
        return None
    try:
        with open(f, newline="") as fh:
            for row in csv.reader(fh):
                if row:
                    return len(row)
    except OSError:
        return None
    return None


def sacct_states(job_id):
    """{array_task_index: State} for a job id, or {} if sacct is unavailable."""
    try:
        out = subprocess.run(
            ["sacct", "-j", str(job_id), "-X", "--noheader", "-P",
             "--format=JobID,State,Elapsed"],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if out.returncode != 0:
        return {}
    states = {}
    for line in out.stdout.splitlines():
        parts = line.split("|")
        if len(parts) < 2:
            continue
        jobid, state = parts[0], parts[1].strip()
        m = re.search(r"_(\d+)$", jobid)
        if m:
            states[int(m.group(1))] = state
    return states


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arm-dir", required=True,
                    help="directory containing task_<N>/ subdirectories")
    ap.add_argument("--manifest", default=None,
                    help="manifest.csv written by run_all.sh (optional; the "
                         "legacy 2026-04 sweep has none)")
    ap.add_argument("--job-id", default=None,
                    help="SLURM array job id, to cross-check per-task states")
    ap.add_argument("--expected-runs", type=int, default=EXPECTED_RUNS_PER_CELL)
    args = ap.parse_args()

    arm_dir = Path(args.arm_dir)
    if not arm_dir.is_dir():
        print(f"FAIL  arm directory not found: {arm_dir}")
        print("RESULT: FAIL")
        return 1

    task_dirs = sorted(
        (d for d in arm_dir.iterdir() if d.is_dir() and d.name.startswith("task_")),
        key=lambda d: int(d.name.split("_", 1)[1]) if d.name.split("_", 1)[1].isdigit() else 0,
    )

    expected_ids = None
    if args.manifest and Path(args.manifest).exists():
        with open(args.manifest, newline="") as fh:
            expected_ids = {int(r["task_id"]) for r in csv.DictReader(fh)}

    states = sacct_states(args.job_id) if args.job_id else {}

    fails, warns = [], []
    n_ok = n_partial = n_surplus = 0
    ragged_tasks = []
    total_runs = 0
    total_outcomes = 0
    legacy_width_tasks = []
    dup_tasks = []

    print(f"arm directory : {arm_dir}")
    print(f"task dirs     : {len(task_dirs)}")

    # An arm with no task directories at all used to print RESULT: OK, because
    # every count was trivially zero and no check had anything to fail on. That
    # is the house failure mode — a gate reporting green on a job that
    # accomplished nothing (cf. the three PASSes on the dead 2026-08-13 smoke
    # run). A verifier that cannot see any work has not verified anything.
    if not task_dirs:
        print("-" * 70)
        print(f"FAIL  no task directories under {arm_dir}.")
        print("      Nothing was verified. This is not a pass — check that the arm tag")
        print("      is right, that the sweep actually started, and that sweep_task.slurm")
        print("      wrote where you think it did (it mkdir -p's TASK_DIR before Julia")
        print("      runs, so an empty dir is not evidence the model ever executed).")
        return 1
    if expected_ids is not None:
        print(f"manifest cells: {len(expected_ids)}")
    if args.job_id:
        print(f"sacct states  : {len(states)} array tasks for job {args.job_id}"
              + ("" if states else "  (sacct unavailable — state checks skipped)"))
    print("-" * 70)

    seen_ids = set()
    for td in task_dirs:
        suffix = td.name.split("_", 1)[1]
        if not suffix.isdigit():
            continue
        tid = int(suffix)
        seen_ids.add(tid)

        results = sorted(td.glob("bankRunResults*.csv"))
        n_res = read_rows(results)
        n_init = read_rows([td / "bankRunParametersInit.csv"])
        total_runs += n_init
        total_outcomes += n_res

        state = states.get(tid)
        if state and any(state.startswith(b) for b in BAD_SLURM_STATES):
            fails.append(f"task_{tid}: SLURM state {state} ({n_res} outcome rows)")
            continue

        if not results or n_res == 0:
            fails.append(f"task_{tid}: no outcome rows "
                         f"(bankRunResults*.csv {'absent' if not results else 'empty'})")
            continue

        if n_res < args.expected_runs:
            n_partial += 1
            warns.append(f"task_{tid}: {n_res}/{args.expected_runs} runs — under-filled")
        elif n_res > args.expected_runs:
            n_surplus += 1
            # A top-up appends a WHOLE fresh block, so a legitimately topped-up
            # cell holds an exact multiple of the block size. A ragged count is
            # a top-up that itself died partway — surplus in total while still
            # missing runs from its last block, which "surplus" alone reads as
            # healthy. Separate the two.
            if n_res % args.expected_runs != 0:
                ragged_tasks.append((tid, n_res))
        else:
            n_ok += 1

        # A key appearing twice means two runs shared a key, which breaks any
        # join on it. Distinct from surplus, where extra runs have fresh keys.
        keys = first_column_values(results)
        dups = [k for k, c in Counter(keys).items() if c > 1]
        if dups:
            dup_tasks.append((tid, len(dups)))

        w = param_dump_width(td)
        if w is not None and w <= LEGACY_PARAM_COLS:
            legacy_width_tasks.append(tid)

    if expected_ids is not None:
        missing = sorted(expected_ids - seen_ids)
        for tid in missing:
            fails.append(f"task_{tid}: in manifest but no output directory")

    # ── Summary ───────────────────────────────────────────────────────────────
    print(f"complete (=={args.expected_runs} runs) : {n_ok}")
    print(f"under-filled (<{args.expected_runs})    : {n_partial}")
    print(f"surplus (>{args.expected_runs})         : {n_surplus}")
    print(f"parameter rows written    : {total_runs}")
    print(f"outcome rows written      : {total_outcomes}")
    if total_runs:
        print(f"outcome coverage          : {100.0 * total_outcomes / total_runs:.1f}%")
    print()

    if n_surplus:
        print(f"NOTE  {n_surplus} cells hold more than {args.expected_runs} runs. "
              f"Expected if --restart was used:")
        print("      restart.jl is not wired in, so a re-submitted task appends a fresh")
        print("      block under new keys rather than resuming. The extra runs are valid")
        print("      draws — but do NOT describe the sweep as N replications per cell")
        print("      without recounting from the data.")
        print()

    if ragged_tasks:
        print(f"WARN  {len(ragged_tasks)} cells hold a run count that is NOT a multiple")
        print(f"      of {args.expected_runs}. A top-up appends a whole block, so a ragged")
        print("      total means a top-up died partway: the cell is over the base count")
        print("      while still missing runs from its final block. Counting it as")
        print("      'surplus' would read as healthy.")
        for tid, n in ragged_tasks[:10]:
            print(f"        task_{tid}: {n} runs")
        if len(ragged_tasks) > 10:
            print(f"        … and {len(ragged_tasks) - 10} more")
        print()

    if legacy_width_tasks:
        print(f"WARN  {len(legacy_width_tasks)} tasks have a "
              f"{LEGACY_PARAM_COLS}-column parameter dump (pre-sigma-fix vintage).")
        print("      sigma is unrecoverable from the dump for these; the consolidator")
        print("      must take it from the manifest or the params file.")
        print(f"      e.g. task_{legacy_width_tasks[0]}")
        print()

    if dup_tasks:
        print(f"WARN  duplicate run keys in {len(dup_tasks)} tasks "
              f"(e.g. task_{dup_tasks[0][0]}: {dup_tasks[0][1]} repeated keys).")
        print("      Two runs sharing a key breaks any join on it. Investigate before")
        print("      consolidating; do not silently de-duplicate.")
        print()

    for w in warns[:20]:
        print(f"WARN  {w}")
    if len(warns) > 20:
        print(f"WARN  … and {len(warns) - 20} more under-filled tasks")
    if warns:
        print()

    for f in fails[:40]:
        print(f"FAIL  {f}")
    if len(fails) > 40:
        print(f"FAIL  … and {len(fails) - 40} more")

    print()
    if fails:
        print(f"RESULT: FAIL — {len(fails)} tasks. Do NOT quote numbers from this arm "
              "until they are resubmitted.")
        return 1
    if warns or dup_tasks or legacy_width_tasks:
        print("RESULT: OK with warnings (informational — see above).")
    else:
        print("RESULT: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
