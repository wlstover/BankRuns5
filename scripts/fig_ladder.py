"""Deck figure: the ladder of depositor heterogeneity.

Three panels, left to right: the signal varies (Goldstein-Pauzner: one
fundamental, one noisy draw per depositor), location varies (networks and
media decide who hears it, from whom, when), interpretation varies (the same
two signals, different dispositional weights; this dissertation).

Writes figures/deck/ladder.png. Palette matches docs/build_deck.js.
"""
import os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, Circle

NAVY, BLUE, GREY, LIGHT, PALE = "#16213E", "#3B6BB5", "#6B7280", "#D9E3F3", "#EEF2F9"
IND, COL = "#EB6834", "#2A78D6"  # individualists, collectivists (as in the exhibits)
OUT = os.path.join(os.path.dirname(__file__), "..", "figures", "deck", "ladder.png")

plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10})
fig, axes = plt.subplots(1, 3, figsize=(12.0, 4.2))
for ax in axes:
    ax.set_xlim(0, 10); ax.set_ylim(0, 10); ax.axis("off")

def head(ax, n, title, sub):
    ax.add_patch(Circle((0.55, 9.3), 0.42, color=BLUE, zorder=3))
    ax.text(0.55, 9.3, str(n), color="white", ha="center", va="center", fontsize=11, fontweight="bold", zorder=4)
    ax.text(1.25, 9.55, title, color=NAVY, fontsize=13, fontweight="bold", va="center")
    ax.text(1.25, 8.85, sub, color=GREY, fontsize=9.5, va="center")

def depositor(ax, x, y, color=GREY, r=0.28, z=3):
    ax.add_patch(Circle((x, y), r, facecolor=color, edgecolor="white", lw=1.0, zorder=z))

def arrow(ax, p, q, color=GREY, lw=1.2, alpha=1.0, style="-|>", shrink=4):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle=style, mutation_scale=9, color=color, lw=lw, alpha=alpha,
                                 shrinkA=shrink, shrinkB=shrink, zorder=2))

# ---------------- 1. dispersed ----------------
ax = axes[0]
head(ax, 1, "Signal", "one fundamental, one noisy draw each")
# the fundamental: a bar at the top
ax.add_patch(plt.Rectangle((3.0, 6.9), 4.0, 0.75, facecolor=NAVY, edgecolor="none", zorder=3))
ax.text(5.0, 7.27, "bank fundamental  θ", color="white", ha="center", va="center", fontsize=10, zorder=4)
# the signal line at the bottom with depositors scattered along it
ax.plot([1.0, 9.0], [2.2, 2.2], color=GREY, lw=1.0, zorder=1)
ax.text(5.0, 1.3, "private signal  x = θ + noise", color=GREY, ha="center", fontsize=9.5)
ax.plot([5.0, 5.0], [2.0, 2.4], color=NAVY, lw=1.5, zorder=2)
xs = np.array([1.7, 2.7, 3.6, 4.3, 4.9, 5.4, 6.0, 6.9, 8.2])
for i, x in enumerate(xs):
    arrow(ax, (5.0 + (x - 5.0) * 0.15, 6.9), (x, 2.2), color=GREY, lw=0.9, alpha=0.55)
    depositor(ax, x, 2.2, GREY)
ax.text(1.4, 3.3, "run", color=GREY, fontsize=9, ha="left", style="italic")
ax.text(8.6, 3.3, "stay", color=GREY, fontsize=9, ha="right", style="italic")
ax.text(9.6, 5.4, "same signal technology,\ndifferent draws", color=NAVY, ha="right", fontsize=9.5,
        bbox=dict(facecolor="white", edgecolor="none", pad=2), zorder=5)

# ---------------- 2. delivered ----------------
ax = axes[1]
head(ax, 2, "Location", "who hears it, from whom, when")
rng = np.random.default_rng(7)
pos = {0: (2.0, 6.3), 1: (3.6, 4.2), 2: (3.4, 2.0), 3: (5.2, 5.6), 4: (5.6, 3.2), 5: (7.2, 6.6),
       6: (7.6, 4.3), 7: (8.3, 2.3), 8: (1.6, 3.0), 9: (6.4, 1.6)}
edges = [(0, 1), (1, 2), (1, 3), (3, 4), (3, 5), (4, 6), (5, 6), (6, 7), (0, 8), (8, 2), (4, 9), (9, 7), (2, 4)]
for a, b in edges:
    ax.plot([pos[a][0], pos[b][0]], [pos[a][1], pos[b][1]], color=LIGHT, lw=2.0, zorder=1)
reached = {0: 1, 1: 1, 8: 1, 3: 2, 2: 2, 4: 3, 5: 3}
for a, b in [(0, 1), (0, 8), (1, 3), (1, 2), (3, 4), (3, 5)]:
    arrow(ax, pos[a], pos[b], color=BLUE, lw=1.6, shrink=7)
for n, (x, y) in pos.items():
    if n == 0:
        depositor(ax, x, y, NAVY, r=0.34)
    elif n in reached:
        depositor(ax, x, y, BLUE, r=0.28)
    else:
        depositor(ax, x, y, LIGHT, r=0.28)
ax.text(2.0, 7.15, "first to hear", color=NAVY, fontsize=9, ha="center")
ax.text(9.4, 4.95, "not yet\nreached", color=GREY, fontsize=9, ha="center", style="italic")
ax.text(5.0, 0.6, "networks and media: Kelly–Ó Gráda, Iyer–Puri, Cookson et al.", color=GREY, ha="center", fontsize=9.5)

# ---------------- 3. interpreted ----------------
ax = axes[2]
head(ax, 3, "Interpretation", "the same two signals, different weights")
# two signal sources at the top
for x, lab, col in [(2.6, "private signal  x", NAVY), (7.4, "public signal  y", GREY)]:
    ax.add_patch(plt.Rectangle((x - 1.75, 6.9), 3.5, 0.75, facecolor=col, edgecolor="none", zorder=3))
    ax.text(x, 7.27, lab, color="white", ha="center", va="center", fontsize=10, zorder=4)
# two depositors at the bottom, weights shown by arrow thickness
for x, col, wx, wy, name in [(3.0, IND, 3.2, 0.9, "individualist"), (7.0, COL, 0.9, 3.2, "collectivist")]:
    arrow(ax, (2.6, 6.9), (x, 3.0), color=col, lw=wx, shrink=10)
    arrow(ax, (7.4, 6.9), (x, 3.0), color=col, lw=wy, shrink=10)
    depositor(ax, x, 2.6, col, r=0.42)
    ax.text(x, 1.55, name, color=col, ha="center", fontsize=10, fontweight="bold")
ax.text(3.0, 0.75, "leans on what it sees", color=GREY, ha="center", fontsize=9)
ax.text(7.0, 0.75, "leans on the public line", color=GREY, ha="center", fontsize=9)
ax.text(5.0, 8.1, "culture sets the weight", color=NAVY, ha="center", fontsize=9.5, style="italic")

fig.subplots_adjust(left=0.01, right=0.99, top=0.98, bottom=0.02, wspace=0.08)
fig.savefig(OUT, dpi=300, facecolor="white")
print("wrote", OUT)
