#!/usr/bin/env python3
"""
consolidate_results.py
Stage 1: consolidate ABM parameter + outcome data across a sweep arm's task
directories into one row-per-simulation CSV.

⚠️ WHY THIS FILE WAS REWRITTEN (2026-08-13)
-------------------------------------------
The previous version assigned column names POSITIONALLY to the headerless
bankRunParametersInit.csv dump, and the positions were wrong. parameterGen.jl:135
writes

    seed1, iteration, graphParams1, graphParams2, reserveRatio,
    depositInsuranceQuantile, warmupAlpha, fracIndividualists,
    lambdaI, lambdaC, seed2, key

i.e. columns 2-5 are (k, p, r, q). The old header called them
(agtCnt, reserveRatio, depositInsurance, exogProb), so:

    k -> "agtCnt"      p -> "reserveRatio"
    r -> "depositInsurance"                 q -> "exogProb"

Every downstream artifact keyed on "reserveRatio" was therefore keyed on the
Watts-Strogatz rewiring probability. That is the origin of the paper's
"reserve null" (a 1.7pp p-null, not a reserve null — the true reserve axis
spans 99.5% -> 47.0% failure) and of the P6b saturation argument built on it.
The DATA were always correct; only the labels were wrong.

The durable fix is not a corrected header — that leaves the same failure one
column-order change away. It is to join on the MANIFEST that run_all.sh writes
at submission time, keyed by task_id (already encoded in the directory name).
Positional parsing survives only as a fallback for the legacy 2026-04 sweep,
which predates manifests, and it warns when it is used.

Canonical output columns
------------------------
    task_id paramSeed replication k p reserveRatio depQuantile sigma
    warmupAlpha mu lambdaI lambdaC seed key armTag assignRule
    completed bankRun nWithdrawn depositWithdrawn

`reserveRatio` now genuinely holds the reserve ratio. Note for anyone updating
downstream code: the old `depositInsurance` column is now `depQuantile`, and
`agtCnt` / `exogProb` are gone (they never held what they claimed).

`nWithdrawn` / `depositWithdrawn` are |S*| — the realised withdrawal set size —
present only for runs produced after the instrumentation fix; blank otherwise.

`mcDepth` is the Monte Carlo draws per agent decision. It is a MODELLING
parameter, not just a compute setting: the withdraw/stay rule compares two
Bernoulli means over that many draws, so decision precision scales as
1/sqrt(mcDepth). Blank means the legacy 2026-04 sweep, which ran at the
model's original hardcoded 1000. DO NOT POOL ACROSS DEPTHS.

Usage:
    python3 consolidate_results.py --arm-dir outputs/production \
            --manifest outputs/production/manifest.csv \
            --out outputs/production/consolidated_results.csv

    # the legacy 2026-04 sweep (no manifest, 12-column dumps):
    python3 consolidate_results.py --arm-dir outputs --out outputs/consolidated_results.csv
"""

import argparse
import csv
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent

# bankRunParametersInit.csv positions. Authoritative source: parameterGen.jl:135.
INIT_POS = {
    "paramSeed": 0,
    "replication": 1,
    "k": 2,
    "p": 3,
    "reserveRatio": 4,
    "depQuantile": 5,
    "warmupAlpha": 6,
    "mu": 7,
    "lambdaI": 8,
    "lambdaC": 9,
    "seed": 10,
    "key": 11,
}
LEGACY_INIT_COLS = 12          # pre-sigma-fix width
SIGMA_POS = 13                 # lognSigma, once parameterGen.jl writes it

HEADER = [
    "task_id", "paramSeed", "replication", "k", "p", "reserveRatio",
    "depQuantile", "sigma", "warmupAlpha", "mu", "lambdaI", "lambdaC",
    "seed", "key", "armTag", "assignRule", "mcDepth", "completed", "bankRun",
    "nWithdrawn", "depositWithdrawn",
]


def load_manifest(path):
    """{task_id: {param: value}} from run_all.sh's manifest, or {}."""
    if not path or not Path(path).exists():
        return {}
    out = {}
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            try:
                out[int(row["task_id"])] = row
            except (KeyError, ValueError):
                continue
    return out


def task_id_of(task_dir):
    suffix = task_dir.name.split("_", 1)[-1]
    return int(suffix) if suffix.isdigit() else None


def consolidate(arm_dir, manifest_path, out_path):
    arm_dir = Path(arm_dir)
    task_dirs = sorted(
        (d for d in arm_dir.iterdir() if d.is_dir() and d.name.startswith("task_")),
        key=lambda d: task_id_of(d) or 0,
    )
    if not task_dirs:
        print(f"ERROR: no task_*/ directories under {arm_dir}", file=sys.stderr)
        return None, 0

    manifest = load_manifest(manifest_path)
    print(f"Arm directory : {arm_dir}")
    print(f"Task dirs     : {len(task_dirs)}")
    if manifest:
        print(f"Manifest      : {manifest_path} ({len(manifest)} cells) — "
              "parameters taken from here")
    else:
        print("Manifest      : NONE — falling back to positional parsing of the")
        print("                Julia dump. This is the legacy path; parameters are")
        print("                mapped per parameterGen.jl:135, NOT per the old header.")

    total_rows = 0
    missing_fin = missing_results = 0
    unmatched_completed = unmatched_outcome = 0
    legacy_width_dirs = 0
    sigma_missing = 0

    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with open(out_path, "w", newline="") as out_f:
        writer = csv.writer(out_f)
        writer.writerow(HEADER)

        for i, task_dir in enumerate(task_dirs):
            tid = task_id_of(task_dir)
            init_file = task_dir / "bankRunParametersInit.csv"
            fin_file = task_dir / "bankRunParametersFin.csv"
            if not init_file.exists():
                continue

            man = manifest.get(tid, {})
            arm_tag = man.get("arm_tag", "")
            assign_rule = man.get("assign_rule", "")
            # Blank for the legacy sweep, which predates the flag. Legacy runs
            # were all at depth=1000 — the model's original hardcoded value.
            mc_depth = man.get("mc_depth", "")

            params = {}
            with open(init_file, newline="") as fh:
                for row in csv.reader(fh):
                    if len(row) < LEGACY_INIT_COLS:
                        continue
                    key = row[INIT_POS["key"]]

                    if man:
                        # Manifest is authoritative for the design parameters.
                        # The dump still supplies the per-run seeds and the key.
                        rec = {
                            "paramSeed": row[INIT_POS["paramSeed"]],
                            "replication": row[INIT_POS["replication"]],
                            "k": man.get("k", ""),
                            "p": man.get("p", ""),
                            "reserveRatio": man.get("reserve", ""),
                            "depQuantile": man.get("depq", ""),
                            "sigma": man.get("sigma", ""),
                            "warmupAlpha": man.get("alpha", ""),
                            "mu": man.get("mu", ""),
                            "lambdaI": man.get("lambdaI", ""),
                            "lambdaC": man.get("lambdaC", ""),
                            "seed": row[INIT_POS["seed"]],
                            "key": key,
                        }
                    else:
                        rec = {name: row[pos] for name, pos in INIT_POS.items()}
                        # sigma is absent from 12-column dumps; it is recoverable
                        # only from the params file, which the legacy sweep does
                        # not carry alongside its outputs.
                        rec["sigma"] = row[SIGMA_POS] if len(row) > SIGMA_POS else ""

                    if not rec["sigma"]:
                        sigma_missing += 1
                    params[key] = rec

            if not manifest and params:
                sample_width = None
                with open(init_file, newline="") as fh:
                    for row in csv.reader(fh):
                        if row:
                            sample_width = len(row)
                            break
                if sample_width is not None and sample_width <= LEGACY_INIT_COLS:
                    legacy_width_dirs += 1

            completed_keys = set()
            if fin_file.exists():
                with open(fin_file, newline="") as fh:
                    for row in csv.reader(fh):
                        if row:
                            completed_keys.add(row[0])
            else:
                missing_fin += 1

            # bankRunResults*.csv is (key, runState) legacy, or
            # (key, runState, nWithdrawn, depositWithdrawn) post-instrumentation.
            outcomes = {}
            results_files = list(task_dir.glob("bankRunResults*.csv"))
            if not results_files:
                missing_results += 1
            for rf in results_files:
                with open(rf, newline="") as fh:
                    for row in csv.reader(fh):
                        if len(row) >= 2:
                            outcomes[row[0]] = (
                                row[1],
                                row[2] if len(row) > 2 else "",
                                row[3] if len(row) > 3 else "",
                            )

            for key, rec in params.items():
                completed = "true" if key in completed_keys else ""
                if not completed:
                    unmatched_completed += 1
                bank_run, n_wd, dep_wd = outcomes.get(key, ("", "", ""))
                if not bank_run:
                    unmatched_outcome += 1

                writer.writerow([
                    tid, rec["paramSeed"], rec["replication"], rec["k"], rec["p"],
                    rec["reserveRatio"], rec["depQuantile"], rec["sigma"],
                    rec["warmupAlpha"], rec["mu"], rec["lambdaI"], rec["lambdaC"],
                    rec["seed"], key, arm_tag, assign_rule, mc_depth,
                    completed, bank_run, n_wd, dep_wd,
                ])
                total_rows += 1

            if (i + 1) % 200 == 0:
                print(f"  {i+1}/{len(task_dirs)} dirs, {total_rows:,} rows...")

    print(f"\nDone. {total_rows:,} rows -> {out_path}")
    print(f"  Missing fin files:                 {missing_fin}")
    print(f"  Missing bankRunResults*.csv files: {missing_results}")
    print(f"  Init keys with no completion mark: {unmatched_completed}")
    print(f"  Init keys with no outcome record:  {unmatched_outcome}")
    if legacy_width_dirs:
        print(f"  ⚠️  {legacy_width_dirs} task dirs have {LEGACY_INIT_COLS}-column "
              "(pre-sigma-fix) dumps")
    if sigma_missing:
        print(f"  ⚠️  {sigma_missing:,} rows have no sigma. Experiment 3 (deposit")
        print("      heterogeneity) is not estimable on those rows: sigma was never")
        print("      written to the dump, which is why 2,160 designed cells appear")
        print("      as 1,080 distinct recorded combinations.")
    return out_path, total_rows


def analyze(csv_path):
    """Marginal failure rates on the CORRECTED axes."""
    def rate_table(title, keyfunc, header_labels):
        groups = defaultdict(lambda: {"completed": 0, "runs": 0})
        with open(csv_path, newline="") as fh:
            for row in csv.DictReader(fh):
                # A row counts only if the sim finished AND emitted an outcome.
                if row["completed"] == "true" and row["bankRun"] in ("true", "false"):
                    g = groups[keyfunc(row)]
                    g["completed"] += 1
                    if row["bankRun"] == "true":
                        g["runs"] += 1
        print(f"\n=== {title} ===")
        widths = [max(8, len(h)) for h in header_labels]
        print(" ".join(f"{h:>{w}s}" for h, w in zip(header_labels, widths))
              + f" {'Completed':>10s} {'Runs':>9s} {'Fail%':>7s}")
        print("-" * (sum(widths) + len(widths) + 30))
        for k in sorted(groups.keys()):
            g = groups[k]
            rate = g["runs"] / g["completed"] * 100 if g["completed"] else 0.0
            kk = k if isinstance(k, tuple) else (k,)
            print(" ".join(f"{str(v):>{w}s}" for v, w in zip(kk, widths))
                  + f" {g['completed']:>10d} {g['runs']:>9d} {rate:>6.1f}%")
        return groups

    rate_table("FAILURE RATE BY MU (P6a headline)", lambda r: r["mu"], ["mu"])
    # This is the table the old code produced keyed on `p` while calling it the
    # reserve ratio. Both axes are now printed, separately and correctly.
    rate_table("FAILURE RATE BY RESERVE RATIO (true reserve axis)",
               lambda r: r["reserveRatio"], ["reserve"])
    rate_table("FAILURE RATE BY WATTS-STROGATZ p (the old 'reserve null')",
               lambda r: r["p"], ["ws_p"])
    rate_table("FAILURE RATE BY MU x RESERVE RATIO",
               lambda r: (r["mu"], r["reserveRatio"]), ["mu", "reserve"])
    rate_table("FAILURE RATE BY MU x LAMBDA GAP",
               lambda r: (r["mu"], r["lambdaI"], r["lambdaC"]),
               ["mu", "lambdaI", "lambdaC"])


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arm-dir", default=str(REPO_ROOT / "outputs"),
                    help="directory holding task_<N>/ subdirectories")
    ap.add_argument("--manifest", default=None,
                    help="manifest.csv from run_all.sh; omit for the legacy sweep")
    ap.add_argument("--out", default=None,
                    help="output CSV (default: <arm-dir>/consolidated_results.csv)")
    ap.add_argument("--no-analyze", action="store_true",
                    help="skip the summary tables")
    args = ap.parse_args()

    arm_dir = Path(args.arm_dir)
    manifest = args.manifest
    if manifest is None:
        default_manifest = arm_dir / "manifest.csv"
        manifest = str(default_manifest) if default_manifest.exists() else None
    out = args.out or str(arm_dir / "consolidated_results.csv")

    path, nrows = consolidate(arm_dir, manifest, out)
    if path is None:
        return 1
    if not args.no_analyze and nrows:
        analyze(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
