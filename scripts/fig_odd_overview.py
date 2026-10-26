"""Deck figure: ODD-style overview of the simulation (entities and schedule).

Landscape, three columns, so it fills the slide on its own: entities and
state variables | the run's schedule (1-3, then 5-6) | the tick loop (4).
Deposits are D (total) and d_i (individual), the fire-sale discount is delta,
the 1% deposit cap is shown, the network is Newman-Watts; CARA is not shown.
Writes figures/deck/odd_overview.png (2400 x 1080 px). Palette matches
docs/build_deck.js.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

NAVY, GREY, EDGE, FILL, BODY = "#1F2937", "#6B7280", "#9CA3AF", "#F3F4F6", "#374151"
OUT = os.path.join(os.path.dirname(__file__), "..", "figures", "deck", "odd_overview.png")
W, H = 2400, 1150
TS, BS, LH, PAD = 23, 20, 44, 22
plt.rcParams.update({"font.family": "DejaVu Sans", "mathtext.fontset": "dejavusans"})
fig = plt.figure(figsize=(W / 100, H / 100), dpi=100)
ax = fig.add_axes([0, 0, 1, 1]); ax.set_xlim(0, W); ax.set_ylim(H, 0); ax.axis("off")

def box(x, y, w, h, title, lines, fill="white"):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=16",
                                facecolor=fill, edgecolor=EDGE, lw=1.8, zorder=2))
    ax.text(x + PAD, y + PAD + 4, title, fontsize=TS, fontweight="bold", color=NAVY, va="top", ha="left", zorder=3)
    for k, ln in enumerate(lines):
        ax.text(x + PAD, y + PAD + 4 + 52 + k * LH, ln, fontsize=BS, color=BODY, va="top", ha="left", zorder=3)

def arrow(p, q, color=GREY):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle="-|>", mutation_scale=20, color=color, lw=1.8, zorder=3))

def header(x, text):
    ax.text(x + 6, 26, text, fontsize=26, fontweight="bold", color=NAVY, va="top")

# ---------------- column 1: entities ----------------
X1, W1 = 30, 740
header(X1, "Entities and state variables")
box(X1, 80, W1, 260, "Depositors  (N = 1,000)", [
    r"deposit $d_i$ ~ LogNormal(1, σ), capped at 1% of $D$",
    r"type I or C; weight $\lambda_I < \lambda_C$",
    r"private signal $x_i = \theta + s\,\varepsilon_i$",
    "balance left; withdrawn or not"])
box(X1, 360, W1, 210, "Social network", [
    "Newman–Watts small world (k, p): each depositor",
    "sees the share of its neighbours who have",
    "withdrawn"])
box(X1, 590, W1, 300, "Bank", [
    r"deposits $D$ in total; reserves $rD$ held as cash",
    r"long asset $(1 - r + e)D$; $e$ = equity per unit of $D$",
    r"sold at $1 - \delta$ per unit if cash runs short",
    r"returns $R(\theta) = 1 + 0.4\,\theta$ at period 2",
    r"promises $R_{stay}$ per unit left in"])
box(X1, 910, W1, 210, "Environment", [
    r"fundamental $\theta$ ~ U[0, 1], one per run",
    r"public signal $y$: none, stale ($y_0$),",
    r"tracks $\theta$, or corrects ($\rho$ per tick)"])

# ---------------- column 2: schedule ----------------
X2, W2 = 820, 740
c2 = X2 + W2 / 2
header(X2, "Process schedule (one run)")
box(X2, 80, W2, 170, "1  Cultural warm-up", [
    "Flache–Macy dynamics on the network; the top μ",
    "become individualists (I), the rest collectivists (C)"])
arrow((c2, 252), (c2, 274))
box(X2, 275, W2, 130, "2  Draw the run's world", [r"$\theta$; each depositor's $x_i$; the public signal $y_1$"])
arrow((c2, 407), (c2, 429))
box(X2, 430, W2, 130, "3  Exogenous shock", ["a random set of depositors withdraws everything"])
box(X2, 680, W2, 170, "5  Period 2", [
    "liquidity failure if cash ran out mid-run; else the",
    r"bank fails if cash + long asset at $R(\theta)$ < promises"])
arrow((c2, 852), (c2, 874))
box(X2, 875, W2, 170, "6  Record", [
    r"failure type; who ran by type ($W_I$, $W_C$; D and D\$);",
    "timing by tick; size deciles; partial withdrawals"])

# ---------------- column 3: the tick loop ----------------
X3, W3 = 1610, 760
ax.add_patch(FancyBboxPatch((X3, 80), W3, 1040, boxstyle="round,pad=0,rounding_size=16",
                            facecolor=FILL, edgecolor=EDGE, lw=1.8, zorder=1))
ax.text(X3 + PAD, 104, "4  Tick loop", fontsize=TS + 2, fontweight="bold", color=NAVY, va="top", zorder=3)
ax.text(X3 + PAD, 146, "banked depositors, in random order", fontsize=BS, color=BODY, va="top", zorder=3)
IX, IW = X3 + 22, W3 - 100
box(IX, 200, IW, 130, "a  Observe", [r"neighbours' withdrawals; public $y_t$"])
box(IX, 350, IW, 170, "b  Form beliefs (λ on others)", [
    r"$\theta$:  $(1-\lambda)\,x_i + \lambda\,y_t$",
    r"runs:  $(1-\lambda)$ own prior + $\lambda$ neighbours"])
box(IX, 540, IW, 210, "c  Value by Monte Carlo", [
    "stay: period-2 payoff on the balance left in",
    "withdraw: a fraction f ∈ {0, ¼, ½, ¾, 1},",
    "paid now, after any fire sale"])
box(IX, 770, IW, 170, "d  Act", [
    "withdraw the best f; if cash is short,",
    r"the bank sells the long asset at $1 - \delta$"])
lx = IX + IW + 30
ax.plot([IX + IW, lx, lx], [855, 855, 265], color=NAVY, lw=1.8, zorder=3)
arrow((lx, 265), (IX + IW + 2, 265), color=NAVY)
ax.text(IX, 1060, "↻ next tick, while anyone withdrew", fontsize=BS, color=BODY, va="top", zorder=3)
# flow between columns: 3 -> tick loop -> 5
arrow((X2 + W2 + 2, 495), (X3 - 2, 495))
arrow((X3 - 2, 765), (X2 + W2 + 2, 765))

fig.savefig(OUT, dpi=100, facecolor="white")
print("wrote", OUT)
