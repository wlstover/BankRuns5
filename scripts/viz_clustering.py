#!/usr/bin/env python3
"""viz_clustering.py — why one-hop clustering is not a firebreak.

Moran's I says cultural type IS spatially clustered under the warm-up rule
(I(treatment) − I(placebo) = +0.102, t = +78) and that the clustering is gone by
two hops. Those two facts together are the 2026-08-19 result, and they are much
easier to see than to state.

The figure shows the same network three ways, at the same mu and the same count
of each type:

    TREATMENT   what the warm-up actually produced
    PLACEBO     the same types assigned at random — the randomisation null
    REGIONS     what the percolation story assumes: contiguous cultural blocks

If treatment and placebo are hard to tell apart by eye while REGIONS is obviously
different, that IS the finding. The correlogram then puts a number on it, and the
component-size panel says why it matters: a firebreak has to be a connected wall
of individualists, and a cascade routes around anything smaller.

Usage
  python3 scripts/viz_clustering.py \\
      --arm-a outputs/production/task_1147 \\
      --arm-b outputs/placebo/task_1147 \\
      --network outputs/production/task_1147/network_edges.csv \\
      --out figures/fig6_clustering_one_hop.png

  # no data to hand: render the illustration from a synthetic field matched to
  # the measured statistics, clearly labelled as such
  python3 scripts/viz_clustering.py --demo --out /tmp/demo.png
"""

from __future__ import annotations

import argparse
import random
import sys
from collections import deque
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402
import numpy as np                       # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tests"))
from check_type_clustering import (       # noqa: E402
    morans_i, lag_pairs, read_edges, read_agents)

I_COL, C_COL = "#eb6834", "#2a78d6"       # matches scripts/viz/cascade_views.py
INK, INK_MUTED, GRID, SURFACE = "#1a1a19", "#6b6a63", "#e3e2dd", "#fcfcfb"
plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK, "text.color": INK,
    "xtick.color": INK_MUTED, "ytick.color": INK_MUTED,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 9, "axes.titlesize": 10, "legend.frameon": False,
})


# ----------------------------------------------------------------- components

def components(members, edges, n):
    """Connected-component sizes of the subgraph induced on `members`.

    This is the firebreak statistic. An individualist only blocks a cascade as
    part of a connected wall; an isolated one is routed around. So the size of
    the largest connected block of individualists is what the percolation story
    actually needs to be large.
    """
    inside = set(members)
    adj = {i: [] for i in inside}
    for u, v in edges:
        if u in inside and v in inside:
            adj[u].append(v); adj[v].append(u)
    seen, sizes = set(), []
    for s in inside:
        if s in seen:
            continue
        seen.add(s); q, sz = deque([s]), 0
        while q:
            u = q.popleft(); sz += 1
            for w in adj[u]:
                if w not in seen:
                    seen.add(w); q.append(w)
        sizes.append(sz)
    return sorted(sizes, reverse=True)


def regions_counterfactual(n, n_i, rng, n_blocks=4):
    """The world the percolation story assumes: contiguous arcs on the ring."""
    types = np.zeros(n, dtype=int)
    per = n_i // n_blocks
    starts = sorted(rng.sample(range(n), n_blocks))
    placed = 0
    for b, s in enumerate(starts):
        take = per if b < n_blocks - 1 else n_i - placed
        for j in range(take):
            types[(s + j) % n] = 1
        placed += take
    # the wrap-around can collide; top up or trim to hold the count exactly
    while types.sum() > n_i:
        types[rng.choice(np.flatnonzero(types).tolist())] = 0
    while types.sum() < n_i:
        types[rng.choice(np.flatnonzero(types == 0).tolist())] = 1
    return types


def synthetic_treatment(n, n_i, edges, rng, target=0.102, iters=200_000):
    """A field with lag-1 Moran's I near `target` and no longer-range structure.

    Demo mode only. Greedy same-type swaps from a random start: it builds
    adjacency correlation without ever building regions, which is precisely the
    shape the real warm-up turns out to have.
    """
    types = np.zeros(n, dtype=int)
    types[rng.sample(range(n), n_i)] = 1
    adj = {i: [] for i in range(n)}
    for u, v in edges:
        adj[u].append(v); adj[v].append(u)

    def local(i, t):
        return sum(1 for w in adj[i] if types[w] == t)

    ones = [i for i in range(n) if types[i] == 1]
    zeros = [i for i in range(n) if types[i] == 0]
    for _ in range(iters):
        a = rng.choice(ones); b = rng.choice(zeros)
        before = local(a, 1) + local(b, 0)
        after = local(a, 0) + local(b, 1)
        if after > before:
            types[a], types[b] = 0, 1
            ones.remove(a); ones.append(b)
            zeros.remove(b); zeros.append(a)
            if morans_i(types.astype(float).tolist(), edges, n)[0] >= target:
                break
    return types


# ---------------------------------------------------------------------- panels

def strip(ax, types, title, n_show=140, note=None):
    """A linear slice of the ring — the backbone, so index order is spatial."""
    v = np.asarray(types[:n_show], dtype=float).reshape(1, -1)
    ax.imshow(v, aspect="auto", interpolation="nearest",
              cmap=matplotlib.colors.ListedColormap([C_COL, I_COL]), vmin=0, vmax=1)
    ax.set_title(title, loc="left", color=INK, pad=3, fontsize=9.5)
    ax.set_yticks([]); ax.set_xticks([])
    ax.grid(False)
    for sp in ax.spines.values():
        sp.set_visible(True); sp.set_color(GRID)
    if note:
        ax.set_xlabel(note, fontsize=8, color=INK_MUTED, loc="left", labelpad=3)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arm-a"); ap.add_argument("--arm-b")
    ap.add_argument("--network"); ap.add_argument("--demo", action="store_true")
    ap.add_argument("--lags", type=int, default=5)
    ap.add_argument("--out", default="figures/fig6_clustering_one_hop.png")
    ap.add_argument("--dpi", type=int, default=200)
    args = ap.parse_args()

    rng = random.Random(20260819)
    if args.demo:
        n, k = 1000, 6
        edges = sorted({tuple(sorted((i, (i + d) % n)))
                        for i in range(n) for d in (1, 2, 3)})
        extra = int(0.05 * len(edges))
        for _ in range(extra):
            u, v = rng.randrange(n), rng.randrange(n)
            if u != v:
                edges.append((min(u, v), max(u, v)))
        n_i = n // 2
        t_types = synthetic_treatment(n, n_i, edges, rng)
        p_types = np.zeros(n, dtype=int); p_types[rng.sample(range(n), n_i)] = 1
        provenance = "SYNTHETIC DEMO — not model output"
    else:
        for need in ("arm_a", "arm_b", "network"):
            if not getattr(args, need):
                ap.error("--arm-a, --arm-b and --network are required without --demo")
        edges, n = read_edges(args.network)
        def first_run(d):
            runs = read_agents(d, max_runs=1)
            key = sorted(runs)[0]
            rows = sorted(runs[key], key=lambda r: r[0])
            lo = min(r[0] for r in rows)
            arr = np.zeros(n, dtype=int)
            for idx, ty, _ in rows:
                arr[idx - lo] = 1 if ty == "I" else 0
            return key, arr
        key_a, t_types = first_run(args.arm_a)
        key_b, p_types = first_run(args.arm_b)
        if t_types.sum() != p_types.sum():
            print(f"⚠️  arms hold different individualist counts "
                  f"({t_types.sum()} vs {p_types.sum()}); the comparison assumes "
                  f"composition is held fixed.", file=sys.stderr)
        n_i = int(t_types.sum())
        provenance = f"{args.arm_a}  run {key_a[:32]}…"

    r_types = regions_counterfactual(n, n_i, rng)
    worlds = [("TREATMENT — warm-up assignment", t_types, I_COL),
              ("PLACEBO — same types, assigned at random", p_types, INK_MUTED),
              ("REGIONS — what the percolation story assumes", r_types, INK)]

    lags = lag_pairs(edges, n, args.lags)
    curves = {}
    for name, ty, _ in worlds:
        f = ty.astype(float).tolist()
        curves[name] = [morans_i(f, lags[L], n)[0] for L in sorted(lags)]

    # The firebreak question is NOT "is there a wall of individualists" — at
    # mu = 0.5 on a mean-degree-6 graph there always is. It is whether the
    # COLLECTIVISTS are cut into pieces. A cascade only stops if the subgraph it
    # travels through fails to percolate, and the site-percolation threshold for
    # a network with this degree distribution is p_c = <k> / (<k^2> - <k>).
    comps = {name: components(np.flatnonzero(ty).tolist(), edges, n)
             for name, ty, _ in worlds}
    ccomps = {name: components(np.flatnonzero(ty == 0).tolist(), edges, n)
              for name, ty, _ in worlds}
    deg = np.zeros(n)
    for u, v in edges:
        deg[u] += 1; deg[v] += 1
    k1, k2 = deg.mean(), (deg ** 2).mean()
    p_c = k1 / (k2 - k1) if k2 > k1 else float("nan")

    # ---------------------------------------------------------------- layout
    fig = plt.figure(figsize=(11, 7.2))
    gs = fig.add_gridspec(2, 2, height_ratios=[1.0, 1.15], hspace=0.42, wspace=0.26,
                          left=0.07, right=0.975, top=0.855, bottom=0.085)
    top = gs[0, :].subgridspec(3, 1, hspace=1.9)

    i1 = morans_i(t_types.astype(float).tolist(), lags[1], n)[0]
    i2 = morans_i(p_types.astype(float).tolist(), lags[1], n)[0]
    i3 = morans_i(r_types.astype(float).tolist(), lags[1], n)[0]
    notes = [
        f"Moran's I at one hop = {i1:+.3f}   →   {50*(1+i1):.1f}% of edges join "
        f"same-type agents, against 50% by chance",
        f"Moran's I at one hop = {i2:+.3f}   →   {50*(1+i2):.1f}%  (the null)",
        f"Moran's I at one hop = {i3:+.3f}   →   {50*(1+i3):.1f}%  — contiguous walls",
    ]
    for row, ((name, ty, _), note) in enumerate(zip(worlds, notes)):
        strip(fig.add_subplot(top[row]), ty, name, note=note)

    # correlogram
    ax = fig.add_subplot(gs[1, 0])
    Ls = sorted(lags)
    for (name, _, col), ls in zip(worlds, ["-", "-", "--"]):
        ax.plot(Ls, curves[name], ls, marker="o", ms=4.5, lw=1.8, color=col,
                label=name.split(" — ")[0])
    ax.axhline(-1.0 / (n - 1), color=INK_MUTED, lw=0.9, ls=":",
               label="no autocorrelation")
    ax.set_ylabel("Moran's I")
    ax.set_title("Clustering vanishes after one hop", loc="left")
    ax.set_xticks(Ls); ax.legend(fontsize=7.5, loc="upper right")
    ax.annotate("a firebreak needs correlation\nthat survives out to here",
                xy=(3.0, 0.012), xytext=(3.05, max(curves[worlds[2][0]]) * 0.62),
                fontsize=7.5, color=INK_MUTED, ha="left",
                arrowprops=dict(arrowstyle="->", color=INK_MUTED, lw=0.9,
                                connectionstyle="arc3,rad=-0.2"))
    ax.set_xlabel("graph distance (hops)", labelpad=4)

    # the collectivists always percolate — that is why nothing blocks
    ax2 = fig.add_subplot(gs[1, 1])
    xs = np.arange(3)
    n_c = n - n_i
    frac = [100 * ccomps[nm][0] / n_c for nm, _, _ in worlds]
    ax2.bar(xs, frac, 0.5, color=[w[2] for w in worlds], alpha=0.85)
    thr = 100 * (1 - p_c)
    ax2.axhline(thr, color=INK_MUTED, lw=1.1, ls=":")
    ax2.annotate(f"below this they fragment\n(p_c = {p_c:.2f} at ⟨k⟩ = {k1:.1f})",
                 (0.015, thr / 118 - 0.015), xycoords="axes fraction",
                 fontsize=7.5, color=INK_MUTED, va="top")
    ax2.set_xticks(xs)
    ax2.set_xticklabels([w[0].split(" — ")[0] for w in worlds], fontsize=8.5)
    ax2.set_ylabel("% of collectivists in ONE connected component")
    ax2.set_ylim(0, 118)
    ax2.set_title("The cascade always has a route through", loc="left")
    for x, f in zip(xs, frac):
        ax2.annotate(f"{f:.0f}%", (x, f + 1.5), ha="center", va="bottom",
                     fontsize=10, color=INK, weight="bold")
    ax2.set_xlabel("even MAXIMAL clustering leaves the collectivists connected —\n"
                   "the shortcuts reconnect whatever the arcs cut",
                   fontsize=8, color=INK_MUTED, loc="left", labelpad=6)

    fig.suptitle("Clustered one hop deep — and it would not matter if it were deeper",
                 x=0.07, ha="left", fontsize=13, color=INK, y=0.965)
    fig.text(0.07, 0.925,
             f"N = {n}, {n_i} individualists ({n_i/n:.0%}), mean degree "
             f"{2*len(edges)/n:.2f}.  Same network and the same type counts in all "
             f"three panels;\n"
             f"strips show the first 140 nodes of the ring backbone.  {provenance}",
             fontsize=8, color=INK_MUTED, va="top")

    out = Path(args.out); out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=args.dpi, bbox_inches="tight")
    print(f"wrote {out}")
    print(f"\nsite-percolation threshold p_c = <k>/(<k^2>-<k>) = {p_c:.4f}  "
          f"(<k> = {k1:.2f}, <k^2> = {k2:.2f})")
    print(f"collectivists occupy {100*n_c/n:.0f}% of nodes — "
          f"{'ABOVE' if n_c/n > p_c else 'below'} threshold, so they percolate\n")
    print(f"{'world':<12}{'I(lag1)':>9}{'I(lag2)':>9}{'big I blk':>11}"
          f"{'big C comp':>12}{'% of C':>8}")
    for name, _, _ in worlds:
        c = curves[name]
        print(f"{name.split(' — ')[0]:<12}{c[0]:>+9.4f}{c[1]:>+9.4f}"
              f"{comps[name][0]:>11}{ccomps[name][0]:>12}"
              f"{100*ccomps[name][0]/n_c:>7.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
