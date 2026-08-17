"""cascade_views.py — the four views of a single BankRuns5 run.

DESIGN NOTES (why the charts look the way they do)
--------------------------------------------------
Palette: categorical slots 1 and 2 of the reference theme, blue #2a78d6 and
orange #eb6834, assigned in FIXED order — individualists always orange,
collectivists always blue, in every view. Validated with the six-checks
validator: CVD separation dE 24.7 (protan), normal-vision 33.6, contrast and
lightness all pass.

Identity is never carried by colour alone. Every series also has its own line
style and marker, because a dissertation gets printed, photocopied and
projected, and the colour is the first thing to go.

One axis per chart, always. Where two quantities of different scale matter
(cascade size and vault level), they are two panels, never two y-scales.
"""

from __future__ import annotations

from pathlib import Path

import matplotlib
import numpy as np
import pandas as pd

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

# ── Fixed categorical assignment. Never cycled, never reordered. ────────────
TYPE_STYLE = {
    "I": dict(color="#eb6834", ls="-",  marker="o", label="Individualist"),
    "C": dict(color="#2a78d6", ls="--", marker="s", label="Collectivist"),
}
INK        = "#1a1a19"
INK_MUTED  = "#6b6a63"
GRID       = "#e3e2dd"
SURFACE    = "#fcfcfb"

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE,
    "axes.edgecolor": GRID, "axes.labelcolor": INK, "text.color": INK,
    "xtick.color": INK_MUTED, "ytick.color": INK_MUTED,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6,
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 9, "axes.titlesize": 10, "legend.frameon": False,
})


def short_key(key, width=28):
    """Production keys are <timestamp>-<seed1>-<seed2> and are far too long for
    a figure title. The seeds are the part that identifies the run."""
    k = str(key)
    return k if len(k) <= width else "…" + k[-(width - 1):]


def _tidy(ax, title=None, xlabel=None, ylabel=None):
    if title:  ax.set_title(title, loc="left", pad=8)
    if xlabel: ax.set_xlabel(xlabel)
    if ylabel: ax.set_ylabel(ylabel)
    ax.set_axisbelow(True)
    return ax


def _require_mixed(run, what):
    if run.single_type:
        raise ValueError(
            f"{what} needs both agent types, but run {run.key!r} has only "
            f"{sorted(run.agents['agentType'].unique())} "
            f"(mu_observed = {run.mu_observed:.2f}). At mu = 0 or mu = 1 the "
            f"cultural comparison does not exist. Pick a key with 0 < mu < 1."
        )


# ── View 1: cascade timeline by type ───────────────────────────────────────
def timeline_by_type(run, ax=None, normalise=True):
    """Cumulative withdrawals vs tick, split by cultural type.

    Normalised WITHIN type by default: at mu = 0.25 there are three times as
    many collectivists, so raw counts compare population sizes rather than
    behaviour. The share of each type that has withdrawn is the comparable
    quantity, and it is what P2 is a claim about — individualists exiting
    EARLIER, not more.
    """
    _require_mixed(run, "The timeline-by-type view")
    ax = ax or plt.subplots(figsize=(5.5, 3.4))[1]

    w = run.withdrawals()
    ticks = np.arange(0, max(run.ticks) + 1)
    sizes = run.agents.groupby("agentType").size()

    for t in ("I", "C"):
        st = TYPE_STYLE[t]
        per = w[w["agentType"] == t].groupby("tick").size().reindex(ticks, fill_value=0)
        cum = per.cumsum().astype(float)
        y = cum / sizes.get(t, np.nan) if normalise else cum
        ax.plot(ticks, y, color=st["color"], ls=st["ls"], lw=2.0,
                marker=st["marker"], ms=4.5, label=f"{st['label']}  (n={sizes.get(t,0)})")
        # Selective direct label at the end of the line, not on every point.
        ax.annotate(st["label"], (ticks[-1], y.iloc[-1]), xytext=(4, 0),
                    textcoords="offset points", color=st["color"],
                    va="center", fontsize=8, fontweight="bold")

    ax.set_xticks(ticks)
    ax.legend(loc="lower right", fontsize=8)
    return _tidy(ax, f"Cascade timeline — run {short_key(run.key)}",
                 "Tick", "Share of type withdrawn" if normalise else "Agents withdrawn")


# ── View 2: vault depletion ────────────────────────────────────────────────
def vault_depletion(run, ax=None, reserve_ratio=None):
    """Vault level over the cascade, with the insolvency line at zero.

    The bank fails when a claim exceeds the vault (functions4.jl withdraw), so
    zero is the meaningful threshold. If the reserve ratio is supplied, the
    opening vault is annotated as r x total deposits — the quantity that makes
    'r sets the cluster size that counts as failure' concrete.
    """
    ax = ax or plt.subplots(figsize=(5.5, 3.4))[1]

    v = (run.decisions.groupby("tick")["vault"]
         .agg(["max", "min"]).reindex(range(0, max(run.ticks) + 1)).ffill())
    ax.step(v.index, v["min"], where="post", color=INK, lw=2.0,
            label="Vault (end of tick)")
    ax.fill_between(v.index, 0, v["min"], step="post", color=INK, alpha=0.06)
    ax.axhline(0, color="#e34948", lw=1.5, ls=":", label="Insolvency")

    opening = float(v["max"].iloc[0])
    note = f"opening vault {opening:,.0f}"
    if reserve_ratio is not None:
        total = run.agents["deposit"].sum()
        note += f"\n= r={reserve_ratio:g} x total deposits {total:,.0f}"
    ax.annotate(note, (0, opening), xytext=(8, -4), textcoords="offset points",
                fontsize=8, color=INK_MUTED, va="top")

    ax.set_xticks(list(v.index))
    ax.legend(loc="upper right", fontsize=8)
    return _tidy(ax, f"Vault depletion — run {short_key(run.key)}", "Tick", "Vault")


# ── View 3: propagation distance (the diagnostic) ──────────────────────────
def propagation_distance(run, graph, ax=None):
    """Graph distance from the exogenous shock vs the tick an agent withdrew.

    NOT decoration. If contagion is spatial, agents further from the shock fall
    later and the distribution shifts right with tick. If `blendedTotal`'s
    population-level term makes the signal effectively mean-field, network
    position cannot matter and the boxes are flat — which would be a finding
    about the model, and would qualify the percolation framing in the chapter.

    Returns (ax, summary) where summary carries the per-tick medians and a
    Spearman correlation, so the reader is not asked to eyeball a trend.
    """
    import networkx as nx
    from scipy.stats import spearmanr

    ax = ax or plt.subplots(figsize=(5.5, 3.4))[1]

    origin = run.origin_idx
    if not origin:
        raise ValueError(
            f"run {run.key!r} has no exogenous withdrawals, so the cascade has "
            f"no origin set and distance is undefined.")

    present = [o for o in origin if o in graph]
    if not present:
        raise ValueError(
            f"none of the {len(origin)} origin agents are nodes in the supplied "
            f"graph (graph has {graph.number_of_nodes()} nodes, run has "
            f"N={run.n_agents}). The graph does not match this run.")

    dist = nx.multi_source_dijkstra_path_length(graph, set(present))
    w = run.withdrawals()
    w = w[w["tick"] > 0].copy()                      # tick 0 IS the origin
    w["distance"] = w["idx"].map(dist)
    w = w.dropna(subset=["distance"])
    if w.empty:
        raise ValueError("no endogenous withdrawals reachable from the shock.")

    ticks = sorted(w["tick"].unique())
    data = [w.loc[w["tick"] == t, "distance"].values for t in ticks]
    bp = ax.boxplot(data, positions=ticks, widths=0.55, patch_artist=True,
                    medianprops=dict(color=INK, lw=1.6),
                    flierprops=dict(marker=".", ms=3, mfc=INK_MUTED,
                                    mec="none", alpha=0.5))
    for patch in bp["boxes"]:
        patch.set(facecolor="#2a78d6", alpha=0.22, edgecolor="#2a78d6", lw=1.2)
    for part in ("whiskers", "caps"):
        for ln in bp[part]:
            ln.set(color=INK_MUTED, lw=1.0)

    rho, p = spearmanr(w["tick"], w["distance"])
    spatial = bool(rho > 0.1 and p < 0.05)
    verdict = ("spatial: distance grows with tick" if spatial
               else "NO distance-tick relationship — consistent with mean-field")
    # Reserve headroom rather than letting the verdict land on a whisker.
    lo, hi = ax.get_ylim()
    ax.set_ylim(lo, hi + 0.30 * (hi - lo))
    ax.annotate(f"Spearman rho = {rho:+.3f}  (p = {p:.3g})\n{verdict}",
                (0.02, 0.97), xycoords="axes fraction", va="top", fontsize=8,
                color=INK_MUTED,
                bbox=dict(boxstyle="round,pad=0.35", fc=SURFACE, ec=GRID, lw=0.6))

    ax.set_xticks(ticks)
    summary = pd.DataFrame({
        "tick": ticks,
        "n": [len(d) for d in data],
        "median_distance": [float(np.median(d)) for d in data],
        "mean_distance": [float(np.mean(d)) for d in data],
    }).assign(spearman_rho=rho, spearman_p=p, spatial=spatial)
    _tidy(ax, f"Propagation distance from the shock — run {short_key(run.key)}",
          "Tick withdrawn", "Graph distance from nearest shocked agent")
    return ax, summary


# ── View 4: the network cascade ────────────────────────────────────────────
def _layout(graph, kind="circular", seed=20260817):
    """Circular by default. Newman-Watts is a ring plus long-range shortcuts;
    on a ring the shortcuts are visible as chords and 'distance from the shock'
    reads directly as arc length. A spring layout tangles both away."""
    import networkx as nx
    if kind == "circular":
        return nx.circular_layout(graph)
    if kind == "spring":
        return nx.spring_layout(graph, seed=seed, iterations=60)
    raise ValueError(f"unknown layout {kind!r}; use 'circular' or 'spring'")


def network_frames(run, graph, ticks=None, pos=None, ncols=None,
                   figsize_per=(3.2, 3.2), layout="circular"):
    """Static multi-panel snapshot of the cascade — the chapter figure.

    Layout is computed ONCE and reused across panels. Recomputing per frame
    makes nodes drift between panels and the eye reads motion that is not in
    the data.
    """
    import networkx as nx

    pos = pos if pos is not None else _layout(graph, layout)
    ticks = ticks if ticks is not None else run.ticks
    ncols = ncols or min(len(ticks), 4)
    nrows = int(np.ceil(len(ticks) / ncols))
    fig, axes = plt.subplots(nrows, ncols,
                             figsize=(figsize_per[0] * ncols, figsize_per[1] * nrows),
                             squeeze=False)

    w = run.withdrawals().set_index("idx")
    types = run.agents.set_index("idx")["agentType"]
    dep = run.agents.set_index("idx")["deposit"]
    # Deposits are log-normal: raw size makes one node a blob and the rest dots.
    size = 6 + 44 * (np.log1p(dep) / np.log1p(dep.max()))

    nodes = [n for n in graph.nodes if n in types.index]
    for ax, t in zip(axes.ravel(), ticks):
        nx.draw_networkx_edges(graph, pos, ax=ax, alpha=0.12, width=0.4,
                               edge_color=INK)
        fallen = set(w.index[w["tick"] <= t])
        for ty in ("C", "I"):                       # I drawn last = on top
            st = TYPE_STYLE[ty]
            for state, alpha, ec in (("standing", 0.30, "none"),
                                     ("withdrawn", 1.0, SURFACE)):
                sel = [n for n in nodes if types[n] == ty
                       and ((n in fallen) == (state == "withdrawn"))]
                if not sel:
                    continue
                nx.draw_networkx_nodes(
                    graph, pos, nodelist=sel, ax=ax,
                    node_color=st["color"], node_size=[size[n] for n in sel],
                    alpha=alpha, edgecolors=ec, linewidths=0.6)
        ax.set_title(f"tick {t}   ({len(fallen)} withdrawn)", fontsize=9, loc="left")
        ax.set_aspect("equal")
        ax.set_axis_off()

    for ax in axes.ravel()[len(ticks):]:
        ax.set_axis_off()

    # The legend must describe the marks that are actually drawn. Still-banked
    # nodes are a FADED version of their own type colour, not grey — an earlier
    # grey "still banked" swatch described a mark that appears nowhere.
    handles = []
    for t in ("I", "C"):
        st = TYPE_STYLE[t]
        handles.append(plt.Line2D([], [], marker="o", ls="none", ms=7,
                                  color=st["color"], label=f"{st['label']} — withdrawn"))
        handles.append(plt.Line2D([], [], marker="o", ls="none", ms=7, alpha=0.30,
                                  color=st["color"], label=f"{st['label']} — still banked"))
    fig.legend(handles=handles, loc="lower center", ncol=4, fontsize=8,
               bbox_to_anchor=(0.5, -0.02))
    fig.suptitle(f"Cascade on the network — run {short_key(run.key)} "
                 f"(N={run.n_agents}, mu={run.mu_observed:.2f})",
                 x=0.02, ha="left", fontsize=11)
    fig.tight_layout(rect=(0, 0.03, 1, 0.97))
    return fig


def animate_cascade(run, graph, out_path, pos=None, fps=1.5, dpi=110,
                    layout="circular"):
    """Same frames, written as an animation for the defense/deck.

    Tries GIF via pillow; that is the format with no external dependency.
    """
    import networkx as nx
    from matplotlib.animation import FuncAnimation, PillowWriter

    pos = pos if pos is not None else _layout(graph, layout)
    w = run.withdrawals().set_index("idx")
    types = run.agents.set_index("idx")["agentType"]
    dep = run.agents.set_index("idx")["deposit"]
    size = 6 + 44 * (np.log1p(dep) / np.log1p(dep.max()))
    nodes = [n for n in graph.nodes if n in types.index]

    fig, ax = plt.subplots(figsize=(5.6, 5.6))

    def draw(t):
        ax.clear(); ax.set_axis_off(); ax.set_aspect("equal")
        nx.draw_networkx_edges(graph, pos, ax=ax, alpha=0.12, width=0.4,
                               edge_color=INK)
        fallen = set(w.index[w["tick"] <= t])
        for ty in ("C", "I"):
            st = TYPE_STYLE[ty]
            for state, alpha, ec in (("standing", 0.30, "none"),
                                     ("withdrawn", 1.0, SURFACE)):
                sel = [n for n in nodes if types[n] == ty
                       and ((n in fallen) == (state == "withdrawn"))]
                if sel:
                    nx.draw_networkx_nodes(
                        graph, pos, nodelist=sel, ax=ax,
                        node_color=st["color"], node_size=[size[n] for n in sel],
                        alpha=alpha, edgecolors=ec, linewidths=0.6)
        ax.set_title(f"run {short_key(run.key)} — tick {t}   "
                     f"{len(fallen)}/{run.n_agents} withdrawn "
                     f"({100*len(fallen)/run.n_agents:.0f}%)",
                     loc="left", fontsize=10)

    anim = FuncAnimation(fig, draw, frames=run.ticks, interval=1000 / fps)
    out_path = Path(out_path)
    anim.save(out_path, writer=PillowWriter(fps=fps), dpi=dpi)
    plt.close(fig)
    return out_path
