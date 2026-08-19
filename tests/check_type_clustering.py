#!/usr/bin/env python3
"""Is cultural type spatially clustered on the network? Moran's I, per arm.

WHY THIS EXISTS
---------------
The P6b contrast came back null (2026-08-19: −0.09 ± 0.30 agents, bounded below
1.4% of P6a). Two readings were on the table — P6b is genuinely absent, or the
model's contagion is mean-field so position cannot matter — and the propagation
survey seemed to settle it for the first: rho = +0.500 over 132 runs, decisively
spatial.

But a third reading survives both, and it is the one that would hurt.

P6b is a POSITION effect. The placebo destroys the type↔position correlation, so
it only tests anything if the warm-up produced one. If cultural type is
spatially unstructured to begin with, the treatment and placebo arms are
statistically identical in every way that matters, the placebo was never a
structural intervention, and **P6b is untested rather than refuted**.

Two pieces of evidence already point that way:

  * The arms match in the SECOND moment as well as the first. Over 36 interior
    (mu, r, p) cells, sd(treatment)/sd(placebo) = 0.9975 ± 0.0017. If warm-up
    assignment clustered individualists, some shocks would land in I-rich
    regions and fizzle while others landed in C-rich regions and burned, so the
    treatment arm would be MORE dispersed at the same mean. It is not.

  * Open item 13 predicts exactly this failure mode, and predicted it before any
    of this ran: under warmup.jl's dot product, moderate agents have w ≈ 0, and
    the tie (w > 0 ⇒ adopt, else resist) sends w = 0 to resist. So type may be
    tracking OPINION STRENGTH rather than BOUNDARY POSITION — a property of the
    agent, not of where it sits.

THE NULL IS FREE, WHICH IS THE NICE PART
----------------------------------------
Moran's I normally needs a permutation null. Here it does not: the placebo arm
IS the randomisation distribution. Same network, same warm-up, same count of
each type, types assigned at random. So `I(treatment) − I(placebo)` is the
statistic, and the analytic E[I] = −1/(N−1) is only a cross-check.

⚠️ INTERNAL CHECK: `warmupLambda` is produced by the warm-up, which ASSIGN_RULE
does not touch, so its Moran's I must be IDENTICAL across arms. Only `agentType`
may differ. If warmupLambda differs, the arms are not the paired comparison the
whole design assumes and nothing else in the output means anything.

Usage
-----
    python3 tests/check_type_clustering.py \\
        --arm-a outputs/production/task_1147 \\
        --arm-b outputs/placebo/task_1147 \\
        --network outputs/production/task_1147/network_edges.csv

    # fewer runs while poking at it
    python3 tests/check_type_clustering.py ... --runs 25

Reads only. Writes nothing unless --out is given.
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict


# ------------------------------------------------------------------ Moran's I

def morans_i(values, edges, n_nodes):
    """Moran's I for an unweighted undirected graph given as an edge list.

        I = (N / W) * (sum_ij w_ij z_i z_j) / (sum_i z_i^2)

    With binary adjacency and each undirected edge listed once, W = 2m and
    sum_ij w_ij z_i z_j = 2 * sum_edges z_u z_v, so the 2s cancel to

        I = (N / m) * sum_edges z_u z_v / sum_i z_i^2

    Returns (I, expected_I) where expected_I = -1/(N-1) is the no-autocorrelation
    reference. Returns (None, ...) if the variable is constant, which is not
    "no clustering" — it is undefined, and must not be reported as zero.
    """
    n = n_nodes
    if n < 3 or not edges:
        return None, None
    mean = sum(values) / n
    z = [v - mean for v in values]
    denom = sum(t * t for t in z)
    if denom == 0:
        return None, -1.0 / (n - 1)
    num = 0.0
    for u, v in edges:
        num += z[u] * z[v]
    m = len(edges)
    return (n / m) * num / denom, -1.0 / (n - 1)


# ------------------------------------------------------------------ file input

def read_edges(path, n_hint=None):
    """Edge list from dump_network.jl (src,dst), returned 0-indexed."""
    edges, nodes = [], set()
    with open(path, newline="") as fh:
        r = csv.reader(fh)
        head = next(r)
        if head and head[0].strip().lower() not in ("src", "source"):
            fh.seek(0)
            r = csv.reader(fh)
        for row in r:
            if len(row) < 2:
                continue
            try:
                u, v = int(row[0]), int(row[1])
            except ValueError:
                continue
            edges.append((u, v))
            nodes.add(u); nodes.add(v)
    if not edges:
        sys.exit(f"ERROR: no edges parsed from {path}")
    lo = min(nodes)
    edges = [(u - lo, v - lo) for u, v in edges]
    return edges, max(nodes) - lo + 1


def read_agents(task_dir, max_runs=None):
    """key -> list of (idx, agentType, warmupLambda), from agents*.csv."""
    runs = defaultdict(list)
    files = sorted(f for f in os.listdir(task_dir)
                   if re.fullmatch(r"agents\d+\.csv", f))
    if not files:
        sys.exit(f"ERROR: no agents*.csv in {task_dir}")
    for fn in files:
        with open(os.path.join(task_dir, fn), newline="") as fh:
            for row in csv.reader(fh):
                if len(row) != 6:
                    continue
                try:
                    idx = int(row[1]); wl = float(row[4])
                except ValueError:
                    continue
                runs[row[0]].append((idx, row[5].strip(), wl))
    keys = sorted(runs)
    if max_runs:
        keys = keys[:max_runs]
    return {k: runs[k] for k in keys}


# --------------------------------------------------------------------- per-arm

def arm_stats(task_dir, edges, n_nodes, max_runs, label):
    runs = read_agents(task_dir, max_runs)
    out = {"label": label, "type": [], "lam": [], "skipped": 0, "n_runs": 0,
           "single_type": 0}
    for key, rows in runs.items():
        rows.sort(key=lambda t: t[0])
        idxs = [r[0] for r in rows]
        if len(set(idxs)) != len(idxs):
            out["skipped"] += 1
            continue
        if len(rows) != n_nodes:
            out["skipped"] += 1
            continue
        lo = min(idxs)
        if [i - lo for i in idxs] != list(range(n_nodes)):
            out["skipped"] += 1
            continue
        types = [1.0 if r[1] == "I" else 0.0 for r in rows]
        lams = [r[2] for r in rows]
        it, _ = morans_i(types, edges, n_nodes)
        il, _ = morans_i(lams, edges, n_nodes)
        if it is None:
            out["single_type"] += 1        # mu = 0 or 1: undefined, not zero
        else:
            out["type"].append(it)
        if il is not None:
            out["lam"].append(il)
        out["n_runs"] += 1
    return out


def summarise(v):
    if not v:
        return None
    s = sorted(v)
    n = len(s)
    mean = sum(s) / n
    var = sum((x - mean) ** 2 for x in s) / (n - 1) if n > 1 else 0.0
    return {"n": n, "mean": mean, "sd": var ** 0.5, "median": s[n // 2],
            "min": s[0], "max": s[-1], "se": (var / n) ** 0.5 if n > 1 else 0.0}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arm-a", required=True, help="treatment task dir")
    ap.add_argument("--arm-b", default=None,
                    help="placebo task dir — the randomisation null. Omitting it "
                         "leaves only the analytic E[I] reference, which is weaker.")
    ap.add_argument("--network", required=True, help="edges CSV from dump_network.jl")
    ap.add_argument("--runs", type=int, default=None, help="cap runs per arm")
    ap.add_argument("--out", default=None, help="write per-run values to this CSV")
    args = ap.parse_args()

    edges, n_nodes = read_edges(args.network)
    print("=" * 72)
    print("SPATIAL CLUSTERING OF CULTURAL TYPE — Moran's I")
    print(f"  network : {args.network}")
    print(f"            {n_nodes} nodes, {len(edges)} edges, "
          f"mean degree {2*len(edges)/n_nodes:.3f}")
    print("=" * 72)

    a = arm_stats(args.arm_a, edges, n_nodes, args.runs, "treatment")
    b = arm_stats(args.arm_b, edges, n_nodes, args.runs, "placebo") if args.arm_b else None

    exp_i = -1.0 / (n_nodes - 1)
    print(f"\n  E[I] under no spatial autocorrelation = {exp_i:+.5f}\n")

    st_a, st_b = summarise(a["type"]), summarise(b["type"]) if b else None
    sl_a, sl_b = summarise(a["lam"]), summarise(b["lam"]) if b else None

    print(f"{'':<22}{'runs':>6}{'mean I':>10}{'sd':>9}{'min':>9}{'max':>9}")
    for nm, s in (("agentType, treatment", st_a), ("agentType, placebo", st_b),
                  ("warmupLambda, treat", sl_a), ("warmupLambda, placebo", sl_b)):
        if s:
            print(f"{nm:<22}{s['n']:>6}{s['mean']:>+10.5f}{s['sd']:>9.5f}"
                  f"{s['min']:>+9.5f}{s['max']:>+9.5f}")
    for arm in (a, b):
        if arm and (arm["skipped"] or arm["single_type"]):
            print(f"\n  {arm['label']}: {arm['skipped']} run(s) skipped "
                  f"(agent set does not match the graph), "
                  f"{arm['single_type']} single-type (I undefined, NOT zero)")

    ok = True
    print("\n" + "-" * 72)

    # ---- internal check: the warm-up is identical across arms ---------------
    if sl_a and sl_b:
        d = abs(sl_a["mean"] - sl_b["mean"])
        print(f"  INTERNAL CHECK — warmupLambda Moran's I must match across arms")
        print(f"    treatment {sl_a['mean']:+.6f}   placebo {sl_b['mean']:+.6f}   "
              f"|diff| {d:.2e}")
        if d > 1e-6:
            print("    🔴 They differ. ASSIGN_RULE does not touch the warm-up, so the")
            print("       arms are not the paired comparison the design assumes and")
            print("       nothing below is interpretable.")
            ok = False
        else:
            print("    ✅ identical — same warm-up, same network; only type differs")

    # ---- the statistic ------------------------------------------------------
    if st_a and st_b:
        diff = st_a["mean"] - st_b["mean"]
        se = (st_a["se"] ** 2 + st_b["se"] ** 2) ** 0.5
        print(f"\n  I(treatment) − I(placebo) = {diff:+.5f} ± {se:.5f}"
              f"   (t = {diff/se:+.2f})" if se else "")
        print("  The placebo IS the randomisation null: same network, same warm-up,")
        print("  same count of each type, assigned at random.")
        print("\n  VERDICT")
        if diff > 10 * se and st_a["mean"] > exp_i + 0.02:
            print("    ✅ CLUSTERED. The warm-up puts individualists in contiguous")
            print("       regions, so the placebo genuinely destroyed a structural")
            print("       feature. The P6b null stands as a result about the mechanism.")
        elif abs(diff) < 3 * se:
            print("    🔴 NOT CLUSTERED. Type is spatially unstructured under the")
            print("       warm-up rule, so the placebo changed the LABELS and not the")
            print("       STRUCTURE. P6b is UNTESTED by this design, not refuted, and")
            print("       the null must be reported that way.")
            print("       See open item 13: warmup.jl's dot product may be tracking")
            print("       opinion strength rather than boundary position.")
            ok = False
        else:
            print("    🟠 WEAK. Detectable but small clustering. State the effect size")
            print("       rather than claiming the placebo was or was not an")
            print("       intervention.")
    elif st_a:
        print(f"\n  agentType Moran's I = {st_a['mean']:+.5f} against E[I] = {exp_i:+.5f}")
        print("  ⚠️ No --arm-b, so this leans on the analytic reference alone. Pass the")
        print("     placebo arm: it is the exact randomisation null for this statistic.")

    if args.out:
        with open(args.out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["arm", "statistic", "morans_i"])
            for arm in (x for x in (a, b) if x):
                for v in arm["type"]:
                    w.writerow([arm["label"], "agentType", f"{v:.6f}"])
                for v in arm["lam"]:
                    w.writerow([arm["label"], "warmupLambda", f"{v:.6f}"])
        print(f"\n  wrote {args.out}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
