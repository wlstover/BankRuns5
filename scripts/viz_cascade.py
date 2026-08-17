#!/usr/bin/env python3
"""viz_cascade.py — render the dynamics of a single BankRuns5 run.

Chapter 3 argues about dynamics — individualists igniting cascades that
collectivists relay, firebreaks, propagation through a small-world network —
and until now the chapter had no picture of any of it. The only network figure,
figures/fig5_network_snapshot.png, is entirely synthetic: make_figures.py:216
builds a networkx graph with an illustrative BFS and no model output at all.
(It also calls nx.watts_strogatz_graph while the model runs
newman_watts_strogatz, so its caption is wrong too — open item 11.)

USAGE
  # views that need no network
  python3 scripts/viz_cascade.py --task-dir outputs/test_run --view timeline
  python3 scripts/viz_cascade.py --task-dir outputs/test_run --view vault

  # views that need the regenerated graph (see scripts/dump_network.jl)
  julia --project scripts/dump_network.jl --manifest outputs/production/manifest.csv \\
        --task 73 --out outputs/production/task_73/network
  python3 scripts/viz_cascade.py --task-dir outputs/production/task_73 \\
        --network outputs/production/task_73/network_edges.csv \\
        --view distance --view network --animate

  # what runs are in here?
  python3 scripts/viz_cascade.py --task-dir outputs/test_run --list

  # is this file torn? (the 249/250 question)
  python3 scripts/viz_cascade.py --audit outputs/production/task_73
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from viz import cascade_data as cd            # noqa: E402
from viz import cascade_views as cv           # noqa: E402

VIEWS = ("timeline", "vault", "distance", "network")
NEEDS_NETWORK = {"distance", "network"}

# Field counts by file, for the torn-row audit.
AUDIT_SPEC = [("agents*.csv", 6), ("bankRunEndogenous*.csv", 8),
              ("bankRunExogenous*.csv", 6), ("bankRunResults*.csv", None),
              ("bankRunParametersInit.csv", None)]


def audit(task_dir: Path) -> int:
    """Field-count histogram for every per-run file in a task directory.

    ⚠️ This is the check for whether the '249/250, finished one run short'
    signature is torn writes rather than lost runs. 15 workers append to these
    files with no coordination; bankRunEndogenous is measurably 1.7% torn. If
    bankRunResults tears the same way, a torn line reads as a missing run and
    every downstream count is short by exactly that much.
    """
    print(f"Torn-row audit: {task_dir}\n" + "-" * 66)
    any_torn = False
    for pattern, expect in AUDIT_SPEC:
        for p in sorted(task_dir.glob(pattern)):
            counts = cd.check_torn_rows(p, expect or 0)["field_counts"]
            total = sum(counts.values())
            modal = max(counts, key=lambda k: counts[k])
            expect_n = expect or modal
            good = counts.get(expect_n, 0)
            bad = total - good
            flag = "  ← TORN" if bad else ""
            print(f"{p.name:34s} {total:>9,} rows, {expect_n} fields expected, "
                  f"{bad:>7,} malformed ({100*bad/total if total else 0:5.2f}%){flag}")
            if bad:
                any_torn = True
                for k, v in sorted(counts.items()):
                    if k != expect_n:
                        print(f"{'':36s}{k:>3} fields x{v:,}")
    print("-" * 66)
    if any_torn:
        print("⚠️  Torn rows present. Every reader of these files must filter on the")
        print("    exact field count and report the drop. If bankRunResults is in the")
        print("    list above, that is a run-count shortfall with a mechanical cause.")
    else:
        print("No torn rows found in this task directory.")
    return 1 if any_torn else 0


def build_synthetic_network(n, k, p, seed=20260817):
    """Development stand-in ONLY. Structurally a Newman-Watts graph of the right
    size, but NOT the edge set the model used — the model's edges depend on
    Julia's RNG stream and cannot be reproduced in networkx."""
    import networkx as nx
    g = nx.newman_watts_strogatz_graph(n, k, p, seed=seed)
    return nx.relabel_nodes(g, {i: i + 1 for i in g.nodes})   # Julia is 1-indexed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--task-dir", type=Path, help="directory holding agents*/bankRun*.csv")
    ap.add_argument("--key", default=None, help="which run; default = first mixed-type key")
    ap.add_argument("--view", action="append", choices=VIEWS,
                    help="repeatable; default = timeline + vault")
    ap.add_argument("--network", type=Path, help="edge CSV from dump_network.jl")
    ap.add_argument("--synthetic-network", action="store_true",
                    help="DEVELOPMENT ONLY: fabricate a structurally-similar graph")
    ap.add_argument("--reserve-ratio", type=float, default=None,
                    help="annotates the vault view; read it from the manifest")
    ap.add_argument("--animate", action="store_true", help="also write a GIF")
    ap.add_argument("--out-dir", type=Path, default=None,
                    help="default <task-dir>/viz")
    ap.add_argument("--list", action="store_true", help="list runs and exit")
    ap.add_argument("--audit", type=Path, help="torn-row audit of a task dir, then exit")
    ap.add_argument("--dpi", type=int, default=200)
    args = ap.parse_args()

    if args.audit:
        return audit(args.audit)
    if not args.task_dir:
        ap.error("--task-dir is required (or use --audit)")

    if args.list:
        keys = cd.list_keys(args.task_dir)
        mixed = keys[keys["n_types"] > 1]
        print(keys.to_string(index=False))
        print(f"\n{len(keys)} runs; {len(mixed)} with both types.")
        if not mixed.empty:
            print(f"Suggested --key {mixed.iloc[0]['key']!r}")
        else:
            print("⚠️  No mixed-type run here: every key is mu = 0 or mu = 1, so the "
                  "I-vs-C views cannot be drawn.")
        return 0

    views = args.view or ["timeline", "vault"]
    out_dir = args.out_dir or (args.task_dir / "viz")
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading {args.task_dir} …")
    run = cd.load_run(args.task_dir, args.key)

    graph = None
    if set(views) & NEEDS_NETWORK or args.animate:
        if args.network:
            graph = cd.load_network(args.network)
            print(f"  network: {graph.number_of_nodes()} nodes, "
                  f"{graph.number_of_edges()} edges from {args.network}")
            meta = args.network.with_name(
                args.network.name.replace("_edges.csv", "_meta.csv"))
            if meta.exists():
                import pandas as pd
                m = pd.read_csv(meta).set_index("field")["value"]
                print(f"  provenance: genSeed={m.get('genSeed')} "
                      f"k={m.get('wsK')} p={m.get('wsP')} hash={m.get('edgeHash')}")
            if graph.number_of_nodes() != run.n_agents:
                print(f"  ⚠️  graph has {graph.number_of_nodes()} nodes but the run "
                      f"has N={run.n_agents}. These do not match; distances will be "
                      f"meaningless. Check --network points at THIS cell.")
        elif args.synthetic_network:
            print("  ⚠️  SYNTHETIC NETWORK — structurally similar, NOT the model's")
            print("      edges. Views 'distance' and 'network' are illustrative only")
            print("      and must not be published or interpreted. Use dump_network.jl.")
            graph = build_synthetic_network(run.n_agents, 6, 0.05)
        else:
            print("ERROR: views 'distance'/'network' need --network <edges.csv> "
                  "from scripts/dump_network.jl (or --synthetic-network to develop).",
                  file=sys.stderr)
            return 2

    import matplotlib.pyplot as plt
    written = []

    for view in views:
        try:
            if view == "timeline":
                fig, ax = plt.subplots(figsize=(5.5, 3.4))
                cv.timeline_by_type(run, ax)
            elif view == "vault":
                fig, ax = plt.subplots(figsize=(5.5, 3.4))
                cv.vault_depletion(run, ax, args.reserve_ratio)
            elif view == "distance":
                fig, ax = plt.subplots(figsize=(5.5, 3.4))
                _, summary = cv.propagation_distance(run, graph, ax)
                csv_path = out_dir / f"distance_{run.key}.csv"
                summary.to_csv(csv_path, index=False)
                written.append(csv_path)
                print(f"  spearman rho = {summary['spearman_rho'].iloc[0]:+.3f} "
                      f"(p = {summary['spearman_p'].iloc[0]:.3g})")
            elif view == "network":
                fig = cv.network_frames(run, graph)
            fig.tight_layout()
            path = out_dir / f"{view}_{run.key}.png"
            fig.savefig(path, dpi=args.dpi, bbox_inches="tight")
            plt.close(fig)
            written.append(path)
        except ValueError as e:
            print(f"  SKIPPED '{view}': {e}", file=sys.stderr)

    if args.animate and graph is not None:
        gif = cv.animate_cascade(run, graph, out_dir / f"cascade_{run.key}.gif")
        written.append(gif)

    print("\nWrote:")
    for p in written:
        print(f"  {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
