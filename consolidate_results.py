#!/usr/bin/env python3
"""
consolidate_results.py
Stage 1: consolidate ABM parameter + outcome data across a sweep arm's task
directories into one row-per-simulation CSV.

⚠️ WHY THIS FILE WAS REWRITTEN (2026-08-13)
-------------------------------------------
The previous version assigned column names POSITIONALLY to the headerless
bankRunParametersInit.csv dump, and the positions were wrong. parameterGen.jl (the bankRunParametersInit.csv write)
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

The no-manifest path is for those 12-column dumps only; an arm with wider dumps
(sigma, assignRule, mcDepth) has a manifest and is refused without it.

Checks (2026-10-21), all reported in the summary:
  - bankRunResults rows must be 2 (legacy) or 4 fields wide; others are torn and
    dropped. Short or unknown-key who-runs / docking rows are counted, not
    silently skipped.
  - Switch reconciliation: the per-run switch files the model writes for
    non-default settings (bankRunPublicParams, ...DecisionParams, ...PublicMode,
    ...PrivateParams, ...StayReturn) must agree with the manifest, and must be
    present exactly when the manifest implies them. Any mismatch makes the exit
    status non-zero (after the outputs are written), which blocks the afterok
    analysis job: the runs did not use the model the manifest describes.
"""

import argparse
import csv
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent

# bankRunParametersInit.csv positions. Authoritative source: parameterGen.jl (the bankRunParametersInit.csv write).
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
    # Added 2026-10-15 (bankRunVault*.csv; blank for runs written before then).
    # drainShare = 1 - max(vaultFinal, 0) / vaultInit, the share of the vault
    # paid out, in [0, 1]. The Ch 3 run-size outcome that does not depend on the
    # tie-break rule (vault <= 0 does). Not depositWithdrawn / vaultInit, which
    # exceeds 1 when withdrawn deposits outrun the vault (heavy-tailed deposits).
    "vaultInit", "vaultFinal", "drainShare",
    # Added 2026-10-20: the quantile insurance cap (4th column of bankRunVault*;
    # blank for earlier runs, NaN under the adaptive scheme).
    "insuranceCap",
]

# Who-runs summary, one row per run x type (bankRunTypes*.csv, since 2026-10-15),
# written next to the main output as consolidated_types.csv.
TYPES_FIELDS = ["n", "nExog", "nEndog", "depTotal", "depExog", "depEndog", "paidExog",
                "paidEndog", "depStayers", "posSumEndog", "nFirstQuarter",
                # Added 2026-10-20 (insured = deposit <= insuranceCap); blank for
                # runs written before then.
                "nInsured", "nEndogInsured", "depUninsured", "depStayersUninsured",
                "nStayersUninsured"]
TYPES_FIELDS_V1 = 11   # width of the 2026-10-15 rows (without the insured columns)
TYPES_HEADER = ["task_id", "key", "armTag", "reserveRatio", "depQuantile", "sigma", "k", "p",
                "mu", "lambdaI", "lambdaC", "type"] + TYPES_FIELDS

# Docking outputs (2026-10-20; functions4.jl dockRow / timingRows / wealthRows),
# each gathered into its own consolidated_<name>.csv with the cell parameters in
# front. Files absent (arms written before 2026-10-20) give header-only outputs.
#   name: (file prefix, per-type?, field names after key[, type])
CELL_COLS = ["task_id", "key", "armTag", "reserveRatio", "depQuantile", "sigma", "k", "p",
             "mu", "lambdaI", "lambdaC"]
DOCK_FILES = {
    "dock":   ("bankRunDock", False,
               ["nExog", "depExogShare", "reserveShare", "slack", "pubErr1", "pubErrMean", "nTicks"]),
    "timing": ("bankRunTiming", True,
               ["tickSumEndog"] + [f"t{k}" for k in range(1, 10)] + ["t10plus"]),
    "wealth": ("bankRunWealth", True,
               [f"n_d{j}" for j in range(1, 11)] + [f"endog_d{j}" for j in range(1, 11)]),
    # Fire-sale bank (2026-10-21, BANKRUN_BALANCE = firesale; functions4.jl
    # modelRun): theta, the balance sheet before and after, period-2 solvency,
    # failType (none / liquidity / insolvency) and the largest depositor.
    "balance": ("bankRunBalance", False,
                ["theta", "returnTheta", "vaultInit", "illiquidInit", "vaultFinal",
                 "illiquidFinal", "assetsT", "promises", "solvent", "failType",
                 "largestShare", "largestToCapacity", "largestWithdrew"]),
    # Public signal of theta (2026-10-22, BANKRUN_THETA_PUBLIC != none or
    # BANKRUN_LAMBDA_SCOPE != count): the public signal at tick 1, its gap
    # y - theta (NaN with no public signal) and the population mean lambda.
    "thetapublic": ("bankRunThetaPublic", False, ["theta", "y1", "gap1", "lambdaBar"]),
    # Decisions and withdrawals by the share of neighbours already out
    # (2026-10-22, fire-sale runs; functions4.jl neighbourRows, NB_BINS).
    "neighbour": ("bankRunNeighbour", True,
                  [f"dec_b{j}" for j in range(6)] + [f"wd_b{j}" for j in range(6)]),
    # Exit shape by size group (2026-10-22, WITHDRAW = partial; rung-4 S1;
    # functions4.jl exitShapeRows, EXIT_GROUPS).
    "exitshape": ("bankRunExitShape", True,
                  [f"{f}_{g}" for g in [f"d{j}" for j in range(1, 11)] + ["top1", "top01"]
                   for f in ("n", "exit", "oneshot", "partial")]),
    # Partial withdrawals (2026-10-22, BANKRUN_WITHDRAW = partial): agents who
    # withdrew anything, those still banked with part of their balance, partial
    # withdrawals made, decisions that valued the interior fractions by
    # re-simulating (large depositors), the share of deposits withdrawn, and the
    # share the largest depositor withdrew.
    "partial": ("bankRunPartial", False,
                ["nAnyOut", "nStillIn", "nPartialEvents", "nBigDecisions", "withdrawnShare",
                 "largestFracWithdrawn"]),
}


# Per-run switch files (functions4.jl, written only for non-default settings):
# file prefix -> the manifest columns of its fields, in order after the key.
# bankRunPrivateParams carries nExog after these, which is not a switch.
SWITCH_FILES = {
    "bankRunPublicParams":   ["public_alpha", "public_bias", "public_rho", "weight_phi",
                              "fix_double_count", "fresh_clone"],
    "bankRunDecisionParams": ["tiebreak", "belief", "belief_p0"],
    "bankRunPublicMode":     ["public_mode", "public_refresh"],
    "bankRunPrivateParams":  ["private_signal", "private_noise"],
    "bankRunStayReturn":     ["stay_return"],
    "bankRunBalanceParams":  ["payoff", "balance", "fire_discount", "equity", "fundamental",
                              "return_lo", "return_hi", "theta_noise"],
    "bankRunThetaPublicParams": ["theta_public", "theta_public_level", "theta_public_gap",
                                 "theta_public_rho", "theta_public_noise", "lambda_scope"],
    "bankRunWithdrawParams": ["withdraw", "partial_min_share"],
    "bankRunRiskParams":     ["cara"],
}
# An empty manifest field means "the default at submission time". The
# FIX_DOUBLE_COUNT default changed on 2026-10-20 (false -> true), so an empty
# value there is ambiguous; manifests written since record it resolved.
AMBIGUOUS_EMPTY = {"fix_double_count"}
TRUE_WORDS = {"true", "1", "yes", "on"}


def switch_defaults(settings_path=REPO_ROOT / "settings.jl"):
    """{manifest column: (default, kind)} from settings.jl's SWITCH_DEFAULTS, read
    the way scripts/switch_names.sh reads it. kind is bool, float or str."""
    out = {}
    in_block = False
    for line in Path(settings_path).read_text().splitlines():
        if line.startswith("const SWITCH_DEFAULTS = ("):
            in_block = True
            continue
        if in_block and line.startswith(")"):
            break
        m = in_block and re.match(r'\s+([A-Z][A-Z0-9_]*)\s*=\s*("[^"]*"|[^,#\s]+)', line)
        if not m:
            continue
        name, val = m.group(1).lower(), m.group(2)
        if val in ("true", "false"):
            out[name] = (val == "true", bool)
        elif val.startswith('"'):
            out[name] = (val.strip('"'), str)
        else:
            out[name] = (float(val), float)
    return out


def _parse_switch(raw, kind):
    raw = raw.strip()
    if kind is bool:
        return raw.lower() in TRUE_WORDS
    if kind is float:
        return float(raw)
    return raw.lower()


def expected_switches(man, defaults):
    """{column: value or None (unknown)} for the switches in SWITCH_FILES."""
    exp = {}
    for cols in SWITCH_FILES.values():
        for c in cols:
            default, kind = defaults[c]
            if c not in man:                  # manifest predates the column
                exp[c] = None
            elif man[c].strip():
                exp[c] = _parse_switch(man[c], kind)
            elif c in AMBIGUOUS_EMPTY:
                exp[c] = None
            else:
                exp[c] = default.lower() if kind is str else default
    return exp


def switch_file_required(prefix, e, defaults):
    """Whether the model writes this file under settings e (functions4.jl), or
    None when a setting it depends on is unknown."""
    d = {c: v for c, (v, _) in defaults.items()}
    need = {
        "bankRunPublicParams":   ["public_alpha", "public_bias", "weight_phi", "public_mode",
                                  "fix_double_count"],
        "bankRunDecisionParams": ["tiebreak", "belief"],
        "bankRunPublicMode":     ["public_mode"],
        "bankRunPrivateParams":  ["private_signal"],
        "bankRunStayReturn":     ["stay_return"],
        "bankRunBalanceParams":  ["payoff", "balance", "fundamental"],
        "bankRunThetaPublicParams": ["theta_public", "lambda_scope"],
        "bankRunWithdrawParams": ["withdraw"],
        "bankRunRiskParams":     ["cara"],
    }[prefix]
    if any(e[c] is None for c in need):
        return None
    if prefix == "bankRunPublicParams":
        return (e["public_alpha"] > 0 or e["public_bias"] > 0 or e["weight_phi"] < 1
                or e["public_mode"] == "stale" or e["fix_double_count"])
    if prefix == "bankRunDecisionParams":
        return e["tiebreak"] != d["tiebreak"] or e["belief"] != d["belief"]
    if prefix == "bankRunPublicMode":
        return e["public_mode"] == "stale"
    if prefix == "bankRunPrivateParams":
        return e["private_signal"] != d["private_signal"]
    if prefix == "bankRunBalanceParams":
        return (e["payoff"] != d["payoff"] or e["balance"] != d["balance"]
                or e["fundamental"] != d["fundamental"])
    if prefix == "bankRunThetaPublicParams":
        return e["theta_public"] != d["theta_public"] or e["lambda_scope"] != d["lambda_scope"]
    if prefix == "bankRunWithdrawParams":
        return e["withdraw"] == "partial"
    if prefix == "bankRunRiskParams":
        return e["cara"] > 0
    return e["stay_return"] != d["stay_return"]


def check_switch_files(task_dir, tid, exp, defaults):
    """Mismatches between a task's switch files and the manifest, as strings."""
    problems = []
    for prefix, cols in SWITCH_FILES.items():
        files = list(task_dir.glob(f"{prefix}*.csv"))
        req = switch_file_required(prefix, exp, defaults)
        if req is True and not files:
            problems.append(f"task {tid}: no {prefix}*.csv, but the manifest implies one")
        elif req is False and files:
            problems.append(f"task {tid}: {prefix}*.csv present, but the manifest implies "
                            "default settings for it")
        seen = set()
        for f in files:
            with open(f, newline="") as fh:
                for row in csv.reader(fh):
                    if not row:
                        continue
                    if len(row) < 1 + len(cols):
                        problems.append(f"task {tid}: {f.name}: row of {len(row)} fields")
                        continue
                    for c, raw in zip(cols, row[1:1 + len(cols)]):
                        want = exp[c]
                        if want is None or (c, raw) in seen:
                            continue
                        seen.add((c, raw))
                        got = _parse_switch(raw, defaults[c][1])
                        same = abs(got - want) < 1e-9 if isinstance(want, float) else got == want
                        if not same:
                            problems.append(f"task {tid}: {f.name}: {c} = {raw!r}, "
                                            f"manifest implies {want!r}")
    return problems


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
        return None, 0, 0

    manifest = load_manifest(manifest_path)
    if not manifest:
        # The positional path knows only the legacy 12-column dump; a wider one
        # (sigma, assignRule, mcDepth) comes from a manifest-era arm.
        for d in task_dirs:
            f = d / "bankRunParametersInit.csv"
            if not f.exists():
                continue
            with open(f, newline="") as fh:
                first = next((r for r in csv.reader(fh) if r), None)
            if first is not None and len(first) > LEGACY_INIT_COLS:
                print(f"ERROR: {f} has {len(first)} columns but there is no manifest. "
                      "Only the legacy 12-column dumps are consolidated positionally; "
                      "pass --manifest <arm>/manifest.csv.", file=sys.stderr)
                return None, 0, 0
    defaults = switch_defaults() if manifest else {}
    switch_problems = []
    print(f"Arm directory : {arm_dir}")
    print(f"Task dirs     : {len(task_dirs)}")
    if manifest:
        print(f"Manifest      : {manifest_path} ({len(manifest)} cells) — "
              "parameters taken from here")
    else:
        print("Manifest      : NONE — falling back to positional parsing of the")
        print("                Julia dump. This is the legacy path; parameters are")
        print("                mapped per parameterGen.jl (the bankRunParametersInit.csv write), NOT per the old header.")

    total_rows = 0
    missing_fin = missing_results = 0
    unmatched_completed = unmatched_outcome = 0
    legacy_width_dirs = 0
    sigma_missing = 0
    torn_results = 0
    types_dropped = {"width": 0, "key": 0}
    dock_dropped = {n: {"width": 0, "key": 0} for n in DOCK_FILES}

    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    types_path = out_path.with_name("consolidated_types.csv")
    types_rows = 0
    dock_paths = {n: out_path.with_name(f"consolidated_{n}.csv") for n in DOCK_FILES}
    dock_rows = {n: 0 for n in DOCK_FILES}
    dock_fhs = {n: open(dock_paths[n], "w", newline="") for n in DOCK_FILES}
    dock_writers = {n: csv.writer(fh) for n, fh in dock_fhs.items()}
    for n, (_, per_type, fields) in DOCK_FILES.items():
        dock_writers[n].writerow(CELL_COLS + (["type"] if per_type else []) + fields)
    with open(out_path, "w", newline="") as out_f, open(types_path, "w", newline="") as types_f:
        writer = csv.writer(out_f)
        writer.writerow(HEADER)
        types_writer = csv.writer(types_f)
        types_writer.writerow(TYPES_HEADER)

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
            # Any other width is a torn write: dropped and counted, so the run
            # shows up as having no outcome rather than as one with a blank |S*|.
            outcomes = {}
            results_files = list(task_dir.glob("bankRunResults*.csv"))
            if not results_files:
                missing_results += 1
            for rf in results_files:
                with open(rf, newline="") as fh:
                    for row in csv.reader(fh):
                        if not row:
                            continue
                        if len(row) not in (2, 4):
                            torn_results += 1
                            continue
                        outcomes[row[0]] = (
                            row[1],
                            row[2] if len(row) > 2 else "",
                            row[3] if len(row) > 3 else "",
                        )

            if man and results_files:
                switch_problems += check_switch_files(
                    task_dir, tid, expected_switches(man, defaults), defaults)

            # bankRunVault*.csv is (key, vaultInit, vaultFinal), since 2026-10-15,
            # plus insuranceCap since 2026-10-20.
            vaults = {}
            for vf in task_dir.glob("bankRunVault*.csv"):
                with open(vf, newline="") as fh:
                    for row in csv.reader(fh):
                        if len(row) >= 3:
                            vaults[row[0]] = (row[1], row[2], row[3] if len(row) > 3 else "")

            for tf in task_dir.glob("bankRunTypes*.csv"):
                with open(tf, newline="") as fh:
                    for row in csv.reader(fh):
                        if not row:
                            continue
                        if len(row) not in (2 + TYPES_FIELDS_V1, 2 + len(TYPES_FIELDS)):
                            types_dropped["width"] += 1
                            continue
                        if row[0] not in params:
                            types_dropped["key"] += 1
                            continue
                        row = row + [""] * (2 + len(TYPES_FIELDS) - len(row))
                        rec = params[row[0]]
                        types_writer.writerow([
                            tid, row[0], arm_tag, rec["reserveRatio"], rec["depQuantile"],
                            rec["sigma"], rec["k"], rec["p"], rec["mu"], rec["lambdaI"],
                            rec["lambdaC"], row[1]] + row[2:])
                        types_rows += 1

            for n, (prefix, per_type, fields) in DOCK_FILES.items():
                width = 1 + int(per_type) + len(fields)
                for df in task_dir.glob(f"{prefix}[0-9]*.csv"):   # not bankRunBalanceParams for bankRunBalance
                    with open(df, newline="") as fh:
                        for row in csv.reader(fh):
                            if not row:
                                continue
                            if len(row) != width:
                                dock_dropped[n]["width"] += 1
                                continue
                            if row[0] not in params:
                                dock_dropped[n]["key"] += 1
                                continue
                            rec = params[row[0]]
                            dock_writers[n].writerow([
                                tid, row[0], arm_tag, rec["reserveRatio"], rec["depQuantile"],
                                rec["sigma"], rec["k"], rec["p"], rec["mu"], rec["lambdaI"],
                                rec["lambdaC"]] + row[1:])
                            dock_rows[n] += 1

            for key, rec in params.items():
                completed = "true" if key in completed_keys else ""
                if not completed:
                    unmatched_completed += 1
                bank_run, n_wd, dep_wd = outcomes.get(key, ("", "", ""))
                if not bank_run:
                    unmatched_outcome += 1
                v_init, v_final, cap = vaults.get(key, ("", "", ""))
                drain = ""
                try:
                    if float(v_init) > 0 and v_final != "":
                        drain = repr(1.0 - max(float(v_final), 0.0) / float(v_init))
                except ValueError:
                    pass

                writer.writerow([
                    tid, rec["paramSeed"], rec["replication"], rec["k"], rec["p"],
                    rec["reserveRatio"], rec["depQuantile"], rec["sigma"],
                    rec["warmupAlpha"], rec["mu"], rec["lambdaI"], rec["lambdaC"],
                    rec["seed"], key, arm_tag, assign_rule, mc_depth,
                    completed, bank_run, n_wd, dep_wd, v_init, v_final, drain, cap,
                ])
                total_rows += 1

            if (i + 1) % 200 == 0:
                print(f"  {i+1}/{len(task_dirs)} dirs, {total_rows:,} rows...")

    for fh in dock_fhs.values():
        fh.close()
    print(f"\nDone. {total_rows:,} rows -> {out_path}")
    print(f"  who-runs rows (run x type):        {types_rows:,} -> {types_path}")
    for n in DOCK_FILES:
        print(f"  {n + ' rows:':<34s} {dock_rows[n]:,} -> {dock_paths[n]}")
    print(f"  Missing fin files:                 {missing_fin}")
    print(f"  Missing bankRunResults*.csv files: {missing_results}")
    print(f"  Init keys with no completion mark: {unmatched_completed}")
    print(f"  Init keys with no outcome record:  {unmatched_outcome}")
    print(f"  Torn bankRunResults rows dropped:  {torn_results}")
    print(f"  who-runs rows dropped (width/key): {types_dropped['width']} / {types_dropped['key']}")
    for n in DOCK_FILES:
        print(f"  {n + ' rows dropped (width/key):':<34s} "
              f"{dock_dropped[n]['width']} / {dock_dropped[n]['key']}")
    if manifest:
        print(f"  Switch-file mismatches:            {len(switch_problems)}")
        for p in switch_problems[:50]:
            print(f"    ⚠️  {p}")
        if len(switch_problems) > 50:
            print(f"    ... and {len(switch_problems) - 50} more")
        if switch_problems:
            print("  ⚠️  These runs did not use the settings the manifest records. "
                  "Exiting non-zero.")
    if legacy_width_dirs:
        print(f"  ⚠️  {legacy_width_dirs} task dirs have {LEGACY_INIT_COLS}-column "
              "(pre-sigma-fix) dumps")
    if sigma_missing:
        print(f"  ⚠️  {sigma_missing:,} rows have no sigma. Experiment 3 (deposit")
        print("      heterogeneity) is not estimable on those rows: sigma was never")
        print("      written to the dump, which is why 2,160 designed cells appear")
        print("      as 1,080 distinct recorded combinations.")
    return out_path, total_rows, len(switch_problems)


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

    path, nrows, n_switch_problems = consolidate(arm_dir, manifest, out)
    if path is None:
        return 1
    if not args.no_analyze and nrows:
        analyze(path)
    return 1 if n_switch_problems else 0


if __name__ == "__main__":
    sys.exit(main())
