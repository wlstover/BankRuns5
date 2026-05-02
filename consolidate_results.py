"""
consolidate_results.py
Stage 1: Consolidate ABM parameter + outcome data across all task directories.

Reads bankRunParametersInit.csv and bankRunParametersFin.csv from each task_*/
directory, joins on the simulation key, and produces a single consolidated CSV
with one row per simulation run.

Output:
    outputs/consolidated_results.csv

Columns:
    paramSeed, replication, agtCnt, reserveRatio, depositInsurance, exogProb,
    warmupAlpha, mu, lambdaI, lambdaC, seed, key, completed, bankRun

Usage:
    python consolidate_results.py
"""

import csv
import sys
from pathlib import Path
from collections import defaultdict

OUTPUTS = Path(__file__).resolve().parent / 'outputs'


def consolidate():
    # Column mapping for bankRunParametersInit (no header, 12 cols):
    # 0: paramSeed, 1: replication, 2: agtCnt, 3: reserveRatio,
    # 4: depositInsurance, 5: exogProb, 6: warmupAlpha,
    # 7: mu (fracIndividualists), 8: lambdaI, 9: lambdaC, 10: seed, 11: key

    # bankRunParametersFin (no header, 3 cols): key, started, completed.
    # Both started and completed are the literal string "true" once the sim
    # has run; this file is a completion-marker only, not an outcome record.

    # bankRunResults*.csv (no header, 2 cols, one file per worker core):
    # 0: key, 1: runState (true if vault depleted, false if survived).
    # The actual bank-run outcome lives here, NOT in bankRunParametersFin.

    header = [
        'paramSeed', 'replication', 'agtCnt', 'reserveRatio',
        'depositInsurance', 'exogProb', 'warmupAlpha',
        'mu', 'lambdaI', 'lambdaC', 'seed', 'key',
        'completed', 'bankRun'
    ]

    out_path = OUTPUTS / 'consolidated_results.csv'
    task_dirs = sorted(OUTPUTS.glob('task_*'))
    print(f"Found {len(task_dirs)} task directories")

    total_rows = 0
    missing_fin = 0
    missing_results = 0
    unmatched_completed = 0
    unmatched_outcome = 0

    with open(out_path, 'w', newline='') as out_f:
        writer = csv.writer(out_f)
        writer.writerow(header)

        for i, task_dir in enumerate(task_dirs):
            init_file = task_dir / 'bankRunParametersInit.csv'
            fin_file = task_dir / 'bankRunParametersFin.csv'

            if not init_file.exists():
                continue

            # Read init parameters, keyed by simulation key (col 11)
            params = {}
            with open(init_file) as f:
                for row in csv.reader(f):
                    if len(row) >= 12:
                        key = row[11]
                        params[key] = row[:12]

            # Read fin file as a completion-marker set (key in fin => completed)
            completed_keys = set()
            if fin_file.exists():
                with open(fin_file) as f:
                    for row in csv.reader(f):
                        if len(row) >= 1:
                            completed_keys.add(row[0])
            else:
                missing_fin += 1

            # Read all per-worker bankRunResults*.csv files for the actual
            # bankRun outcome. Each file is (key, runState).
            outcomes = {}
            results_files = list(task_dir.glob('bankRunResults*.csv'))
            if not results_files:
                missing_results += 1
            for rf in results_files:
                with open(rf) as f:
                    for row in csv.reader(f):
                        if len(row) >= 2:
                            outcomes[row[0]] = row[1]

            # Join init params with completion marker and bankRun outcome
            for key, p in params.items():
                completed = 'true' if key in completed_keys else ''
                if not completed:
                    unmatched_completed += 1

                bank_run = outcomes.get(key, '')
                if not bank_run:
                    unmatched_outcome += 1

                writer.writerow(p + [completed, bank_run])
                total_rows += 1

            if (i + 1) % 200 == 0:
                print(f"  Processed {i+1}/{len(task_dirs)} dirs, {total_rows:,} rows...")

    print(f"\nDone. {total_rows:,} rows written to {out_path}")
    print(f"  Missing fin files:                 {missing_fin}")
    print(f"  Missing bankRunResults*.csv files: {missing_results}")
    print(f"  Init keys with no completion mark: {unmatched_completed}")
    print(f"  Init keys with no outcome record:  {unmatched_outcome}")

    return out_path


def analyze(csv_path):
    """Quick analysis: failure rate by mu, lambdaI, lambdaC."""
    from collections import defaultdict

    # Group by (mu, lambdaI, lambdaC) -> list of bankRun outcomes
    groups = defaultdict(lambda: {'total': 0, 'runs': 0, 'completed': 0})

    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            key = (row['mu'], row['lambdaI'], row['lambdaC'])
            groups[key]['total'] += 1
            # A row counts toward the denominator only if the sim both
            # finished (completed marker present) AND emitted an outcome.
            if row['completed'] == 'true' and row['bankRun'] in ('true', 'false'):
                groups[key]['completed'] += 1
                if row['bankRun'] == 'true':
                    groups[key]['runs'] += 1

    print(f"\n{'mu':>6s} {'lI':>6s} {'lC':>6s} {'N':>8s} {'Compl':>8s} {'Runs':>8s} {'Fail%':>8s}")
    print('-' * 55)

    for (mu, li, lc) in sorted(groups.keys()):
        g = groups[(mu, li, lc)]
        n = g['total']
        completed = g['completed']
        runs = g['runs']
        fail_rate = runs / completed * 100 if completed > 0 else 0
        print(f"{mu:>6s} {li:>6s} {lc:>6s} {n:>8d} {completed:>8d} {runs:>8d} {fail_rate:>7.1f}%")

    # Non-monotonicity check: group by mu only
    print(f"\n=== FAILURE RATE BY MU (averaged across lambdaI/lambdaC) ===")
    mu_groups = defaultdict(lambda: {'completed': 0, 'runs': 0})
    for (mu, li, lc), g in groups.items():
        mu_groups[mu]['completed'] += g['completed']
        mu_groups[mu]['runs'] += g['runs']

    print(f"{'mu':>6s} {'Completed':>10s} {'Runs':>8s} {'Fail%':>8s}")
    print('-' * 35)
    for mu in sorted(mu_groups.keys()):
        g = mu_groups[mu]
        fail_rate = g['runs'] / g['completed'] * 100 if g['completed'] > 0 else 0
        print(f"{mu:>6s} {g['completed']:>10d} {g['runs']:>8d} {fail_rate:>7.1f}%")

    # Also break down by mu x reserveRatio
    print(f"\n=== FAILURE RATE BY MU x RESERVE RATIO ===")
    mr_groups = defaultdict(lambda: {'completed': 0, 'runs': 0})
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            key = (row['mu'], row['reserveRatio'])
            if row['completed'] == 'true' and row['bankRun'] in ('true', 'false'):
                mr_groups[key]['completed'] += 1
                if row['bankRun'] == 'true':
                    mr_groups[key]['runs'] += 1

    print(f"{'mu':>6s} {'reserve':>8s} {'Completed':>10s} {'Runs':>8s} {'Fail%':>8s}")
    print('-' * 45)
    for (mu, rr) in sorted(mr_groups.keys()):
        g = mr_groups[(mu, rr)]
        fail_rate = g['runs'] / g['completed'] * 100 if g['completed'] > 0 else 0
        print(f"{mu:>6s} {rr:>8s} {g['completed']:>10d} {g['runs']:>8d} {fail_rate:>7.1f}%")


if __name__ == '__main__':
    csv_path = consolidate()
    analyze(csv_path)
