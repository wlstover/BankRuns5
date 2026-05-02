"""
make_figures.py — Chapter 3 §6.6 + theory §4.6 figures.

Produces three figures from outputs/consolidated_results.csv:

    fig1_p6a_headline.png       P(run) vs mu × lambda-gap, collapsed across
                                reserve. The headline P6a confirmation.

    fig2_reserve_null.png       P(run) vs mu × reserve ratio, collapsed across
                                lambda gap. Demonstrates the reserve null that
                                supports the cascade-saturation framing.

    fig4_p6a_p6b_schematic.png  Two-panel pedagogical schematic. Left: hypothetical
                                moderate-regime curve with both channels (P6a
                                baseline plus P6b interior peak). Right: observed
                                aggressive-regime curve from the sweep (P6a only).

Run from the BankRuns5/ root after rsync'ing the consolidated CSV from HPC:
    python scripts/make_figures.py

Figure 4 produces synthetic data and works without the CSV.
"""

import csv
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

BASE = Path(__file__).resolve().parent.parent
INPUT = BASE / "outputs" / "consolidated_results.csv"
OUT_DIR = BASE / "outputs" / "analysis"
OUT_DIR.mkdir(parents=True, exist_ok=True)

plt.rcParams.update({
    "font.family": "serif",
    "font.size": 11,
    "axes.titlesize": 12,
    "axes.labelsize": 11,
    "legend.fontsize": 10,
})


def aggregate():
    """Return dict[(mu, lambdaI, lambdaC, reserveRatio)] -> {completed, runs}."""
    cells = defaultdict(lambda: {"completed": 0, "runs": 0})
    with open(INPUT) as f:
        for row in csv.DictReader(f):
            if row["completed"] != "true":
                continue
            if row["bankRun"] not in ("true", "false"):
                continue
            key = (float(row["mu"]), float(row["lambdaI"]),
                   float(row["lambdaC"]), float(row["reserveRatio"]))
            cells[key]["completed"] += 1
            if row["bankRun"] == "true":
                cells[key]["runs"] += 1
    return cells


def figure_1_headline(cells):
    by_mu_gap = defaultdict(lambda: {"completed": 0, "runs": 0})
    for (mu, li, lc, _rr), v in cells.items():
        gap = round(lc - li, 2)
        by_mu_gap[(mu, gap)]["completed"] += v["completed"]
        by_mu_gap[(mu, gap)]["runs"] += v["runs"]

    mus = sorted({k[0] for k in by_mu_gap})
    gaps = sorted({k[1] for k in by_mu_gap}, reverse=True)

    fig, ax = plt.subplots(figsize=(7.5, 5))
    colors = ["#1f3a93", "#d35400", "#27ae60"]
    for gap, color in zip(gaps, colors):
        rates = [by_mu_gap[(m, gap)]["runs"] / by_mu_gap[(m, gap)]["completed"]
                 for m in mus]
        ax.plot(mus, rates, marker="o", color=color, linewidth=2,
                markersize=7, label=fr"$\lambda_C - \lambda_I = {gap:.1f}$")
        delta = (rates[0] - rates[-1]) * 100
        ax.annotate(fr"$\Delta = {delta:.1f}$pp",
                    xy=(mus[-1], rates[-1]),
                    xytext=(8, -12 if gap == max(gaps) else 8),
                    textcoords="offset points",
                    fontsize=9, color=color)

    ax.set_xlabel(r"Fraction individualist $\mu$")
    ax.set_ylabel(r"$P(\mathrm{bank\ run})$")
    ax.set_title(
        "Bank-run probability is monotonically decreasing in cultural composition\n"
        r"(stratified by signal-weighting gap $\lambda_C - \lambda_I$)"
    )
    ax.set_xticks(mus)
    ax.set_yticks(np.arange(0.5, 1.01, 0.05))
    ax.set_yticklabels([f"{int(t * 100)}%" for t in np.arange(0.5, 1.01, 0.05)])
    ax.set_ylim(0.6, 0.95)
    ax.legend(loc="upper right", frameon=False, title="Signal-weighting gap")
    ax.grid(True, alpha=0.3, linewidth=0.5)

    plt.tight_layout()
    out = OUT_DIR / "fig1_p6a_headline.png"
    plt.savefig(out, dpi=200, bbox_inches="tight")
    plt.close()
    print(f"Wrote {out}")


def figure_2_reserve_null(cells):
    by_mu_rr = defaultdict(lambda: {"completed": 0, "runs": 0})
    for (mu, _li, _lc, rr), v in cells.items():
        by_mu_rr[(mu, rr)]["completed"] += v["completed"]
        by_mu_rr[(mu, rr)]["runs"] += v["runs"]

    mus = sorted({k[0] for k in by_mu_rr})
    reserves = sorted({k[1] for k in by_mu_rr})

    fig, ax = plt.subplots(figsize=(7.5, 5))
    colors = ["#c0392b", "#8e44ad"]
    markers = ["o", "s"]
    for rr, color, marker in zip(reserves, colors, markers):
        rates = [by_mu_rr[(m, rr)]["runs"] / by_mu_rr[(m, rr)]["completed"]
                 for m in mus]
        ax.plot(mus, rates, marker=marker, color=color, linewidth=2,
                markersize=7, label=f"Reserve ratio = {rr:g}")

    ax.set_xlabel(r"Fraction individualist $\mu$")
    ax.set_ylabel(r"$P(\mathrm{bank\ run})$")
    ax.set_title(
        "Reserve-ratio interaction is approximately null in the swept regime\n"
        "(consistent with cascade-pressure saturation; cultural channel dominates)"
    )
    ax.set_xticks(mus)
    ax.set_yticks(np.arange(0.5, 1.01, 0.05))
    ax.set_yticklabels([f"{int(t * 100)}%" for t in np.arange(0.5, 1.01, 0.05)])
    ax.set_ylim(0.6, 0.95)
    ax.legend(loc="upper right", frameon=False)
    ax.grid(True, alpha=0.3, linewidth=0.5)

    plt.tight_layout()
    out = OUT_DIR / "fig2_reserve_null.png"
    plt.savefig(out, dpi=200, bbox_inches="tight")
    plt.close()
    print(f"Wrote {out}")


def figure_4_schematic():
    mu_grid = np.linspace(0, 1, 200)

    # Left panel — moderate-regime hypothetical: P6a baseline (monotone decline)
    # plus P6b residual (Gaussian interior bump). Shapes are illustrative.
    p6a_baseline = 0.55 - 0.20 * mu_grid
    p6b_residual = 0.20 * np.exp(-((mu_grid - 0.55) / 0.20) ** 2)
    p6_combined = p6a_baseline + p6b_residual

    # Right panel — observed values from the current sweep.
    mu_obs = np.array([0.0, 0.25, 0.5, 0.75, 1.0])
    fail_obs = np.array([0.844, 0.827, 0.773, 0.721, 0.684])

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))

    # Left
    ax = axes[0]
    ax.plot(mu_grid, p6a_baseline, "--", color="#7f8c8d", linewidth=1.6,
            label="P6a baseline (direct channel)")
    ax.plot(mu_grid, p6_combined, "-", color="#1f3a93", linewidth=2.2,
            label="P6a + P6b (combined)")
    ax.fill_between(mu_grid, p6a_baseline, p6_combined,
                    color="#1f3a93", alpha=0.15,
                    label="P6b residual (indirect channel)")
    peak_idx = int(np.argmax(p6_combined))
    ax.annotate("interior peak\n(P6b emerges)",
                xy=(mu_grid[peak_idx], p6_combined[peak_idx]),
                xytext=(0.18, 0.85),
                arrowprops=dict(arrowstyle="->", color="#34495e", lw=1),
                fontsize=10, color="#34495e")
    ax.set_xlabel(r"Fraction individualist $\mu$")
    ax.set_ylabel(r"$P(\mathrm{bank\ run})$")
    ax.set_title("Theoretical: moderate-parameter regime\n"
                 "(both channels observable)")
    ax.set_xticks([0, 0.25, 0.5, 0.75, 1.0])
    ax.set_ylim(0.0, 1.0)
    ax.set_yticks(np.arange(0, 1.01, 0.2))
    ax.set_yticklabels([f"{int(t * 100)}%" for t in np.arange(0, 1.01, 0.2)])
    ax.legend(loc="lower left", frameon=False, fontsize=9)
    ax.grid(True, alpha=0.3, linewidth=0.5)

    # Right
    ax = axes[1]
    ax.plot(mu_obs, fail_obs, marker="o", color="#c0392b", linewidth=2.2,
            markersize=9, label="Observed (current sweep)")
    for m, f in zip(mu_obs, fail_obs):
        ax.annotate(f"{f:.0%}", (m, f),
                    textcoords="offset points", xytext=(0, 12),
                    ha="center", fontsize=9, color="#c0392b")
    ax.annotate("smooth monotone decline\n(only P6a observable;\nP6b saturated)",
                xy=(0.5, 0.773),
                xytext=(0.55, 0.40),
                arrowprops=dict(arrowstyle="->", color="#7f1d1d", lw=1),
                fontsize=10, color="#7f1d1d")
    ax.set_xlabel(r"Fraction individualist $\mu$")
    ax.set_ylabel(r"$P(\mathrm{bank\ run})$")
    ax.set_title("Observed: aggressive-parameter regime\n"
                 "(P6b saturated; only direct channel exposed)")
    ax.set_xticks([0, 0.25, 0.5, 0.75, 1.0])
    ax.set_ylim(0.0, 1.0)
    ax.set_yticks(np.arange(0, 1.01, 0.2))
    ax.set_yticklabels([f"{int(t * 100)}%" for t in np.arange(0, 1.01, 0.2)])
    ax.legend(loc="lower left", frameon=False, fontsize=9)
    ax.grid(True, alpha=0.3, linewidth=0.5)

    plt.tight_layout()
    out = OUT_DIR / "fig4_p6a_p6b_schematic.png"
    plt.savefig(out, dpi=200, bbox_inches="tight")
    plt.close()
    print(f"Wrote {out}")


def figure_5_network_snapshot():
    """Two-panel Watts-Strogatz snapshot. Pedagogical figure showing what the
    simulation actually looks like; intended for the ABM chapter §3 model
    overview and the proposal deck where most of the committee is not
    ABM-fluent. Static snapshot only -- a dynamic visualization is flagged
    for post-Friday work."""
    import networkx as nx

    rng = np.random.default_rng(42)
    N, k, p, mu = 80, 6, 0.1, 0.5

    G = nx.watts_strogatz_graph(n=N, k=k, p=p, seed=42)
    pos = nx.circular_layout(G)

    n_indiv = int(round(mu * N))
    types = np.array(["I"] * n_indiv + ["C"] * (N - n_indiv))
    rng.shuffle(types)

    # Illustrative cascade: BFS from a collectivist seed, recruit collectivist
    # neighbors at high probability and individualist neighbors at low
    # probability, until ~60% withdrawn (matches sweep mid-range fail rates).
    target_withdrawn = int(0.6 * N)
    withdrawn = set()
    seed = int(rng.choice([i for i in range(N) if types[i] == "C"]))
    frontier = [seed]
    withdrawn.add(seed)
    while len(withdrawn) < target_withdrawn and frontier:
        new_frontier = []
        for node in frontier:
            for nbr in G.neighbors(node):
                if nbr in withdrawn:
                    continue
                p_withdraw = 0.85 if types[nbr] == "C" else 0.30
                if rng.random() < p_withdraw:
                    withdrawn.add(nbr)
                    new_frontier.append(nbr)
                    if len(withdrawn) >= target_withdrawn:
                        break
            if len(withdrawn) >= target_withdrawn:
                break
        frontier = new_frontier

    color_indiv = "#d35400"
    color_collec = "#1f3a93"
    node_colors = [color_indiv if types[i] == "I" else color_collec
                   for i in range(N)]

    fig, axes = plt.subplots(1, 2, figsize=(13, 6.5))

    for ax, title, show_withdrawn in [
        (axes[0], r"Initial state ($t=0$): all agents banking", False),
        (axes[1], "Terminal state: cascade resolved", True),
    ]:
        nx.draw_networkx_edges(G, pos, ax=ax, alpha=0.25, width=0.7)

        if show_withdrawn:
            banking = [i for i in range(N) if i not in withdrawn]
            wlist = list(withdrawn)
            nx.draw_networkx_nodes(
                G, pos, ax=ax, nodelist=banking,
                node_color=[node_colors[i] for i in banking],
                node_size=180, edgecolors="black", linewidths=0.8,
            )
            nx.draw_networkx_nodes(
                G, pos, ax=ax, nodelist=wlist,
                node_color="white", node_size=180,
                edgecolors=[node_colors[i] for i in wlist],
                linewidths=2.0,
            )
        else:
            nx.draw_networkx_nodes(
                G, pos, ax=ax, nodelist=list(range(N)),
                node_color=node_colors,
                node_size=180, edgecolors="black", linewidths=0.8,
            )

        ax.set_title(title)
        ax.axis("off")

    legend_elements = [
        plt.Line2D([0], [0], marker="o", color="w", markerfacecolor=color_indiv,
                   markersize=11, markeredgecolor="black", markeredgewidth=0.8,
                   label=r"Individualist (low $\lambda$), banking"),
        plt.Line2D([0], [0], marker="o", color="w", markerfacecolor=color_collec,
                   markersize=11, markeredgecolor="black", markeredgewidth=0.8,
                   label=r"Collectivist (high $\lambda$), banking"),
        plt.Line2D([0], [0], marker="o", color="w", markerfacecolor="white",
                   markersize=11, markeredgecolor=color_indiv, markeredgewidth=2.0,
                   label="Individualist, withdrawn"),
        plt.Line2D([0], [0], marker="o", color="w", markerfacecolor="white",
                   markersize=11, markeredgecolor=color_collec, markeredgewidth=2.0,
                   label="Collectivist, withdrawn"),
    ]
    fig.legend(handles=legend_elements, loc="lower center", ncol=4,
               frameon=False, bbox_to_anchor=(0.5, -0.02))

    fig.suptitle(
        rf"Watts-Strogatz network at $N={N}$, $k={k}$, $p={p}$, $\mu={mu}$  "
        r"(illustrative; production simulations use $N=1000$)",
        fontsize=11, y=1.0,
    )

    plt.tight_layout(rect=[0, 0.04, 1, 0.97])
    out = OUT_DIR / "fig5_network_snapshot.png"
    plt.savefig(out, dpi=200, bbox_inches="tight")
    plt.close()
    print(f"Wrote {out}")


if __name__ == "__main__":
    if INPUT.exists():
        # Quick sanity check: row count.
        with open(INPUT) as f:
            n_rows = sum(1 for _ in f) - 1
        print(f"Loaded consolidated_results.csv ({n_rows:,} rows)")
        if n_rows < 600_000:
            print("WARNING: row count below the post-fix expected ~709K.")
            print("         Local CSV may be stale; rsync the latest from HPC.")
        cells = aggregate()
        figure_1_headline(cells)
        figure_2_reserve_null(cells)
    else:
        print(f"NOTE: {INPUT} not found. Skipping fig1 and fig2.")
        print("Producing fig4 (schematic, synthetic data) only.")
    figure_4_schematic()
    figure_5_network_snapshot()
    print(f"\nAll figures in: {OUT_DIR}")
