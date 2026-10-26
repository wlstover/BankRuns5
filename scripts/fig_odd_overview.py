"""Deck figure: ODD-style overview of the simulation (entities and schedule).

Redrawn 2026-10-26 to replace the old mock_odd_overview.png: deposits are D
(total) and d_i (individual), the fire-sale discount is delta, the 1% deposit
cap is shown, and the network is Newman-Watts. Writes figures/deck/odd_overview.png
(1340 x 1350 px, same aspect as the old image). Palette matches docs/build_deck.js.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

NAVY, GREY, EDGE, FILL = "#1F2937", "#6B7280", "#9CA3AF", "#F3F4F6"
OUT = os.path.join(os.path.dirname(__file__), "..", "figures", "deck", "odd_overview.png")
W, H = 1340, 1350
plt.rcParams.update({"font.family": "DejaVu Sans", "mathtext.fontset": "dejavusans"})
fig = plt.figure(figsize=(W / 100, H / 100), dpi=100)
ax = fig.add_axes([0, 0, 1, 1]); ax.set_xlim(0, W); ax.set_ylim(H, 0); ax.axis("off")

def box(x, y, w, h, title, lines, fill="white", ts=16.5, bs=13.5, pad=18, lh=31):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0,rounding_size=14",
                                facecolor=fill, edgecolor=EDGE, lw=1.6, zorder=2))
    ax.text(x + pad, y + pad + 6, title, fontsize=ts, fontweight="bold", color=NAVY, va="top", ha="left", zorder=3)
    for k, ln in enumerate(lines):
        ax.text(x + pad, y + pad + 6 + 36 + k * lh, ln, fontsize=bs, color="#374151", va="top", ha="left", zorder=3)

def down_arrow(x, y0, y1):
    ax.add_patch(FancyArrowPatch((x, y0), (x, y1), arrowstyle="-|>", mutation_scale=16, color=GREY, lw=1.4, zorder=3))

# ---------------- left: entities ----------------
LX, LW = 25, 505
ax.text(LX + 8, 30, "Entities and state variables", fontsize=20, fontweight="bold", color=NAVY, va="top")
box(LX, 75, LW, 200, "Depositors  (N = 1,000)", [
    r"deposit $d_i$ ~ LogNormal(1, σ), capped at 1% of $D$",
    r"type I or C; weight $\lambda_I < \lambda_C$",
    r"private signal $x_i = \theta + s\,\varepsilon_i$",
    "balance left; withdrawn or not",
])
box(LX, 290, LW, 150, "Social network", [
    "Newman–Watts small world (k, p): each",
    "depositor sees the share of its neighbours",
    "who have withdrawn",
])
box(LX, 455, LW, 232, "Bank", [
    r"deposits $D$ in total; reserves $rD$ held as cash",
    r"long asset $(1 - r + e)D$, $e$ = equity per unit of $D$",
    r"if cash runs short, it sells at $1 - \delta$ per unit",
    r"return $R(\theta) = 1 + 0.4\,\theta$ at period 2",
    r"promises $R_{stay}$ per unit left in",
])
box(LX, 702, LW, 150, "Environment", [
    r"fundamental $\theta$ ~ U[0, 1], one per run",
    r"public signal $y$: none, stale ($y_0$),",
    r"tracks $\theta$, or corrects ($\rho$ per tick)",
])

# ---------------- right: schedule ----------------
RX, RW = 575, 610
cx = RX + RW / 2
ax.text(RX + 8, 30, "Process schedule (one run)", fontsize=20, fontweight="bold", color=NAVY, va="top")
box(RX, 75, RW, 120, "1  Cultural warm-up", [
    "Flache–Macy dynamics on the network; the top μ",
    "become individualists (I), the rest collectivists (C)"])
down_arrow(cx, 197, 214)
box(RX, 215, RW, 88, "2  Draw the run's world", [r"$\theta$; each depositor's $x_i$; the public signal $y_1$"])
down_arrow(cx, 305, 322)
box(RX, 323, RW, 88, "3  Exogenous shock", ["a random set of depositors withdraws everything"])
down_arrow(cx, 413, 430)
# tick loop container
ax.add_patch(FancyBboxPatch((RX, 431), RW, 612, boxstyle="round,pad=0,rounding_size=14",
                            facecolor=FILL, edgecolor=EDGE, lw=1.6, zorder=1))
ax.text(RX + 18, 455, "4  Tick loop (banked depositors, random order)", fontsize=16.5, fontweight="bold", color=NAVY, va="top", zorder=3)
IX, IW = RX + 22, RW - 90
box(IX, 490, IW, 84, "a  Observe", [r"neighbours' withdrawals; public $y_t$"])
box(IX, 588, IW, 118, "b  Form beliefs (λ on the social side)", [
    r"$\theta$:  $(1-\lambda)\,x_i + \lambda\,y_t$",
    r"withdrawals:  $(1-\lambda)$ own prior + $\lambda$ neighbours"])
box(IX, 720, IW, 150, "c  Value the options by Monte Carlo", [
    "stay: period-2 payoff on the balance left in",
    "withdraw: a fraction f ∈ {0, ¼, ½, ¾, 1},",
    "paid now, after any fire sale"])
box(IX, 884, IW, 118, "d  Act", [
    "withdraw the best f; if cash is short,",
    r"the bank sells the long asset at $1 - \delta$"])
# loop-back arrow on the right of the inner boxes
lx = IX + IW + 28
ax.plot([IX + IW, lx, lx], [965, 965, 532], color=NAVY, lw=1.6, zorder=3)
ax.add_patch(FancyArrowPatch((lx, 532), (IX + IW + 2, 532), arrowstyle="-|>", mutation_scale=16, color=NAVY, lw=1.6, zorder=3))
ax.text(lx + 14, 700, "next tick,\nwhile anyone\nwithdrew", fontsize=13, color="#374151", va="center", ha="left", zorder=3)
down_arrow(cx, 1045, 1062)
box(RX, 1063, RW, 120, "5  Period 2", [
    "liquidity failure if cash ran out mid-run; else the bank",
    r"fails if cash + long asset at $R(\theta)$ < promises"])
down_arrow(cx, 1185, 1202)
box(RX, 1203, RW, 120, "6  Record", [
    r"failure type; who ran by type ($W_I$, $W_C$; D and D\$);",
    "timing by tick; size deciles; partial withdrawals"])

fig.savefig(OUT, dpi=100, facecolor="white")
print("wrote", OUT)
