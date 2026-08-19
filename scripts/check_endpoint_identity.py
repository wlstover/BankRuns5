#!/usr/bin/env python3
"""
The two arms must be IDENTICAL at mu = 0 and mu = 1, and MUST DIFFER in between.

Why this is worth a script
--------------------------
`GEN_SEED = SEED_OFFSET + SLURM_ARRAY_TASK_ID` with the same offset in both arms,
so production cell N and placebo cell N share the network, the deposit vector,
the warm-up, the seed1 vector and the seed2 vector. Only ASSIGN_RULE differs.
And functions4.jl re-seeds at every stage -- seed1+2 for the placebo's randperm,
seed1+1 for the lambda draws, seed1 for deposits, mod.seed2 at line 358 for the
run itself -- so the placebo's extra RNG consumption perturbs nothing downstream.

At the chord endpoints the assignment rule therefore cannot bite:

    mu = 0.0  ->  nI = 0        ->  `nI > 0 &&` short-circuits, nobody is type I
    mu = 1.0  ->  nI = agtCnt   ->  isI[sortIdx[1:nI]] flags EVERYONE, whatever
                                    order sortIdx is in

so the paired cells are bit-identical run for run. In between, nI < agtCnt and
only the first nI entries of sortIdx are flagged, so the two arms select a
different SET of agents (the same NUMBER -- composition fixed, type-position
correlation destroyed). That is the whole intervention.

Three things fall out of one comparison:

  1. THE PAIRING IS REAL.  If the endpoints match run for run, cells correspond
     and `excess(treatment) - excess(placebo)` differences like against like.
  2. THE PIPELINE IS DETERMINISTIC.  Identity across two independently scheduled
     2,160-cell array jobs on different nodes is a stronger reproducibility
     statement than any single-cell rerun.
  3. THE CHORD CANCELS.  excess_J(mu) = rate_J(mu) - chord_J(mu), and if the
     endpoints agree then chord_t == chord_p identically, so

         excess_t(mu) - excess_p(mu)  ==  rate_t(mu) - rate_p(mu)

     exactly. The headline P6b statistic is then just the arm difference in
     cascade size at interior mu, and the P6a-curvature confound is
     algebraically absent from the contrast rather than argued away.

  ⚠️ AND THE POSITIVE CONTROL, which is why this is a test and not a formality:
     interior mu MUST differ. A run of this script that compared nothing, or an
     ASSIGN_RULE that never reached the workers, would report "identical
     endpoints" and look like a pass. This repo's signature failure is a green
     status decoupled from the work, so the interior check is mandatory and its
     failure is fatal, not advisory.

Usage
-----
    python3 scripts/check_endpoint_identity.py \\
        --arm-a outputs/production --arm-b outputs/placebo

    # deeper: also compare per-agent deposits, lambdas and types at the endpoints
    python3 scripts/check_endpoint_identity.py \\
        --arm-a outputs/production --arm-b outputs/placebo \\
        --check-agents --agent-cells 5

Reads only. Writes nothing.
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict

ENDPOINT_MU = ("0.0", "1.0")
RESULT_FIELDS = 4          # key, result, nWithdrawn, depositWithdrawn
# Parameter columns that MUST agree between paired cells. assign_rule and
# arm_tag are excluded on purpose -- those are the intervention.
PAIRED_PARAM_COLS = ("reserve", "depq", "sigma", "k", "p", "alpha",
                     "mu", "lambdaI", "lambdaC", "mc_depth", "seed_offset")


# ------------------------------------------------------------------- helpers

def norm_num(s):
    """Compare manifest numbers by value, so 0.20 and 0.2 are the same level."""
    s = (s or "").strip()
    try:
        return f"{float(s):.10g}"
    except ValueError:
        return s


def read_manifest(path):
    if not os.path.exists(path):
        sys.exit(f"ERROR: no manifest at {path}\n"
                 "       Without it there is no record of which cell is which mu, "
                 "and this check cannot be done.")
    rows = {}
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            tid = (row.get("task_id") or "").strip()
            if tid:
                rows[tid] = row
    if not rows:
        sys.exit(f"ERROR: {path} has no data rows.")
    return rows


def parse_key(key):
    """key = string(Dates.now()) * '-' * seed1 * '-' * seed2 (parameterGen.jl:130).

    The timestamp itself contains hyphens, so split from the RIGHT. Returns
    (seed1, seed2) as strings, or None if the key is not the expected shape.
    """
    parts = key.rsplit("-", 2)
    if len(parts) != 3 or not parts[1].isdigit() or not parts[2].isdigit():
        return None
    return (parts[1], parts[2])


def read_runs(task_dir):
    """(seed1, seed2) -> (result, nWithdrawn, depositWithdrawn), as raw strings.

    Raw strings, not floats: the claim under test is bit-identity, and parsing
    to float would silently forgive a formatting difference that indicates a
    genuinely different code path.
    """
    runs = {}
    dups = 0
    unparsed = 0
    if not os.path.isdir(task_dir):
        return None, 0, 0
    for fn in sorted(os.listdir(task_dir)):
        if not re.fullmatch(r"bankRunResults\d+\.csv", fn):
            continue
        with open(os.path.join(task_dir, fn), newline="") as fh:
            for row in csv.reader(fh):
                if len(row) != RESULT_FIELDS:
                    continue                       # torn line; item 27
                sk = parse_key(row[0])
                if sk is None:
                    unparsed += 1
                    continue
                if sk in runs:
                    dups += 1
                    continue
                runs[sk] = (row[1].strip(), row[2].strip(), row[3].strip())
    return runs, dups, unparsed


def read_agents(task_dir):
    """(seed1, seed2, idx) -> (deposit, individualism, warmupLambda, agentType)."""
    out = {}
    for fn in sorted(os.listdir(task_dir)):
        if not re.fullmatch(r"agents\d+\.csv", fn):
            continue
        with open(os.path.join(task_dir, fn), newline="") as fh:
            for row in csv.reader(fh):
                if len(row) != 6:
                    continue
                sk = parse_key(row[0])
                if sk is None:
                    continue
                out[(sk[0], sk[1], row[1].strip())] = tuple(c.strip() for c in row[2:6])
    return out


def compare_cell(dir_a, dir_b):
    """Compare one paired cell. Returns a dict of counts and up to 3 examples."""
    ra, dup_a, unp_a = read_runs(dir_a)
    rb, dup_b, unp_b = read_runs(dir_b)
    if ra is None or rb is None:
        return {"missing_dir": True}
    ka, kb = set(ra), set(rb)
    both = ka & kb
    res = {
        "missing_dir": False, "n_a": len(ra), "n_b": len(rb),
        "matched_seeds": len(both), "only_a": len(ka - kb), "only_b": len(kb - ka),
        "dups": dup_a + dup_b, "unparsed": unp_a + unp_b,
        "identical": 0, "differing": 0, "examples": [],
        "diff_fields": defaultdict(int),
    }
    for sk in both:
        va, vb = ra[sk], rb[sk]
        if va == vb:
            res["identical"] += 1
        else:
            res["differing"] += 1
            for name, x, y in zip(("result", "nWithdrawn", "depositWithdrawn"), va, vb):
                if x != y:
                    res["diff_fields"][name] += 1
            if len(res["examples"]) < 3:
                res["examples"].append((sk, va, vb))
    return res


# ---------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(
        description="Verify the arms are identical at the chord endpoints and "
                    "differ in the interior.")
    ap.add_argument("--arm-a", required=True, help="e.g. outputs/production")
    ap.add_argument("--arm-b", required=True, help="e.g. outputs/placebo")
    ap.add_argument("--manifest-a", default=None)
    ap.add_argument("--manifest-b", default=None)
    ap.add_argument("--interior-cells", type=int, default=40,
                    help="how many interior-mu cells to sample for the positive "
                         "control (0 disables — NOT recommended)")
    ap.add_argument("--max-endpoint-cells", type=int, default=0,
                    help="cap endpoint cells scanned (0 = all)")
    ap.add_argument("--check-agents", action="store_true",
                    help="also compare per-agent deposit/lambda/type at endpoints")
    ap.add_argument("--agent-cells", type=int, default=5,
                    help="how many endpoint cells to compare agent-wise (slow)")
    args = ap.parse_args()

    if os.path.abspath(args.arm_a) == os.path.abspath(args.arm_b):
        sys.exit("ERROR: --arm-a and --arm-b are the same directory. A self-compare "
                 "returns exact identity everywhere and would read as a clean pass.")
    for d in (args.arm_a, args.arm_b):
        if not os.path.isdir(d):
            sys.exit(f"ERROR: no such arm directory: {d}")

    man_a = read_manifest(args.manifest_a or os.path.join(args.arm_a, "manifest.csv"))
    man_b = read_manifest(args.manifest_b or os.path.join(args.arm_b, "manifest.csv"))

    print("=" * 74)
    print("ENDPOINT IDENTITY CHECK")
    print(f"  arm A: {args.arm_a}   ({len(man_a)} manifest rows)")
    print(f"  arm B: {args.arm_b}   ({len(man_b)} manifest rows)")
    print("=" * 74)

    # ---- precondition 1: the arms must be the same grid, differently assigned
    sha_a = {r.get("params_sha", "") for r in man_a.values()}
    sha_b = {r.get("params_sha", "") for r in man_b.values()}
    print(f"\n  params_sha  A: {sorted(sha_a)}\n              B: {sorted(sha_b)}")
    if sha_a != sha_b:
        sys.exit("\nFATAL: params_sha differs between arms. The cells do not correspond "
                 "and no contrast between them is well-defined.")
    rule_a = {r.get("assign_rule", "") for r in man_a.values()}
    rule_b = {r.get("assign_rule", "") for r in man_b.values()}
    print(f"  assign_rule A: {sorted(rule_a)}   B: {sorted(rule_b)}")
    if rule_a == rule_b:
        sys.exit("\nFATAL: both arms carry the same assign_rule. There is no intervention "
                 "here, so 'the endpoints match' would be trivially true everywhere.")

    # ---- precondition 2: paired cells must agree on every non-intervention param
    shared = sorted(set(man_a) & set(man_b), key=lambda t: int(t) if t.isdigit() else t)
    mismatched = []
    for tid in shared:
        for col in PAIRED_PARAM_COLS:
            if col in man_a[tid] and col in man_b[tid]:
                if norm_num(man_a[tid][col]) != norm_num(man_b[tid][col]):
                    mismatched.append((tid, col, man_a[tid][col], man_b[tid][col]))
                    break
    print(f"  paired task_ids: {len(shared)}   parameter mismatches: {len(mismatched)}")
    if mismatched:
        for m in mismatched[:5]:
            print(f"     task_{m[0]}: {m[1]}  A={m[2]}  B={m[3]}")
        sys.exit("\nFATAL: paired cells disagree on a non-intervention parameter.")

    endpoint = [t for t in shared if norm_num(man_a[t].get("mu", "")) in
                {norm_num(x) for x in ENDPOINT_MU}]
    interior = [t for t in shared if t not in set(endpoint)]
    if args.max_endpoint_cells:
        endpoint = endpoint[:args.max_endpoint_cells]
    print(f"  endpoint cells (mu in {ENDPOINT_MU}): {len(endpoint)}")
    print(f"  interior cells:                      {len(interior)}")

    if not endpoint:
        sys.exit("\nFATAL: no endpoint cells found. Nothing was compared, and a check "
                 "that compares nothing has verified nothing.")

    # ---- the endpoint claim: bit-identical, run for run -----------------------
    print("\n" + "-" * 74)
    print("ENDPOINTS — these must be IDENTICAL run for run")
    print("-" * 74)
    tot = defaultdict(int)
    bad_cells, examples = [], []
    for tid in endpoint:
        r = compare_cell(os.path.join(args.arm_a, f"task_{tid}"),
                         os.path.join(args.arm_b, f"task_{tid}"))
        if r.get("missing_dir"):
            tot["missing_dir"] += 1
            continue
        for k in ("matched_seeds", "only_a", "only_b", "identical",
                  "differing", "dups", "unparsed"):
            tot[k] += r[k]
        if r["differing"] or r["only_a"] or r["only_b"]:
            bad_cells.append((tid, r))
            for e in r["examples"]:
                if len(examples) < 6:
                    examples.append((tid, e))

    print(f"  cells compared          : {len(endpoint) - tot['missing_dir']}")
    print(f"  runs matched by seed    : {tot['matched_seeds']:,}")
    print(f"  IDENTICAL               : {tot['identical']:,}")
    print(f"  DIFFERING               : {tot['differing']:,}")
    print(f"  seed pair only in A / B : {tot['only_a']} / {tot['only_b']}")
    if tot["dups"] or tot["unparsed"]:
        print(f"  duplicate / unparsable keys: {tot['dups']} / {tot['unparsed']}")
    if examples:
        print("\n  first differences:")
        for tid, (sk, va, vb) in examples:
            print(f"    task_{tid} seed1={sk[0]} seed2={sk[1]}")
            print(f"      A: {va}\n      B: {vb}")

    endpoints_ok = (tot["differing"] == 0 and tot["only_a"] == 0
                    and tot["only_b"] == 0 and tot["matched_seeds"] > 0)

    # ---- optional: the same claim one level deeper ---------------------------
    agents_ok = None
    if args.check_agents:
        print("\n" + "-" * 74)
        print(f"ENDPOINTS, per-agent (first {args.agent_cells} cells)")
        print("-" * 74)
        a_same = a_diff = 0
        for tid in endpoint[:args.agent_cells]:
            ga = read_agents(os.path.join(args.arm_a, f"task_{tid}"))
            gb = read_agents(os.path.join(args.arm_b, f"task_{tid}"))
            for k in set(ga) & set(gb):
                if ga[k] == gb[k]:
                    a_same += 1
                else:
                    a_diff += 1
        print(f"  agent rows identical : {a_same:,}")
        print(f"  agent rows differing : {a_diff:,}")
        agents_ok = (a_diff == 0 and a_same > 0)

    # ---- the positive control: the interior MUST differ ---------------------
    interior_ok = None
    if args.interior_cells and interior:
        step = max(1, len(interior) // args.interior_cells)
        sample = interior[::step][:args.interior_cells]
        print("\n" + "-" * 74)
        print(f"POSITIVE CONTROL — interior mu MUST differ ({len(sample)} cells sampled)")
        print("-" * 74)
        cells_diff = cells_same = 0
        i_ident = i_diff = 0
        for tid in sample:
            r = compare_cell(os.path.join(args.arm_a, f"task_{tid}"),
                             os.path.join(args.arm_b, f"task_{tid}"))
            if r.get("missing_dir"):
                continue
            i_ident += r["identical"]
            i_diff += r["differing"]
            if r["differing"] > 0:
                cells_diff += 1
            else:
                cells_same += 1
        n = i_ident + i_diff
        print(f"  cells that differ somewhere : {cells_diff}/{cells_diff + cells_same}")
        print(f"  runs identical / differing  : {i_ident:,} / {i_diff:,}"
              + (f"   ({100.0 * i_diff / n:.1f}% differ)" if n else ""))
        interior_ok = cells_same == 0 and i_diff > 0
        if not interior_ok:
            print("\n  ⚠️ Interior cells that are identical mean the assignment rule never")
            print("     reached the model. Endpoint identity would then be trivial and the")
            print("     placebo arm is a copy of the treatment arm, not a control.")

    # ------------------------------------------------------------- the verdict
    print("\n" + "=" * 74)
    print("VERDICT")
    print("=" * 74)
    ok = True
    print(f"  endpoints identical      : {'YES' if endpoints_ok else 'NO'}")
    ok &= endpoints_ok
    if agents_ok is not None:
        print(f"  endpoint agents identical: {'YES' if agents_ok else 'NO'}")
        ok &= agents_ok
    if interior_ok is not None:
        print(f"  interior differs         : {'YES' if interior_ok else 'NO'}")
        ok &= interior_ok
    else:
        print("  interior differs         : NOT CHECKED  <-- no positive control was run,")
        print("                             so 'endpoints identical' is not yet meaningful")
        ok = False

    if ok:
        print("\n  ✅ The pairing is exact and the intervention fires only where it should.")
        print("     Three consequences, all now earned rather than assumed:")
        print("       1. Cells correspond — the treatment-minus-placebo contrast is")
        print("          well-defined at the level of the individual run.")
        print("       2. The pipeline is deterministic across two independently")
        print("          scheduled array jobs on different nodes.")
        print("       3. chord_t == chord_p, so")
        print("            excess_t(mu) - excess_p(mu) == rate_t(mu) - rate_p(mu)")
        print("          exactly. The headline P6b statistic is the arm difference in")
        print("          cascade size at interior mu, and the P6a-curvature confound is")
        print("          absent from the contrast by algebra, not by argument.")
        print("     ⚠️ Then analysis_p6b.R's 'Independent arms, so the difference's SE")
        print("        adds in quadrature' is wrong: the arms are PAIRED, Cov > 0, and")
        print("        the reported SE is conservative. Fix by resampling each")
        print("        initialisation once and taking BOTH arms' outcomes for it.")
    else:
        print("\n  🔴 Do not run the contrast until this passes. Something the whole")
        print("     P6b design assumes is not true of the data on disk.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
