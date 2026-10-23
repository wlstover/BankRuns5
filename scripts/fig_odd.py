#!/usr/bin/env python3
"""ODD diagrams for Ch 3 (MOCKUPS, 2026-10-22; variants updated 2026-10-23).

  overview: entities and state variables (left) and the process schedule (right),
            for the fire-sale reference model (ODD: Overview; Process overview
            and scheduling).
  variants: which setting each run family uses, component by component; cells
            that differ from the rung-1 reference are dark.

Usage:
    python3 scripts/fig_odd.py --out outputs/mockups
"""

import argparse
import sys
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import figstyle as fs   # noqa: E402


def box(ax, x, y, w, h, title, body=None, fill="#ffffff", edge=None, title_color=None,
        size=8.6, title_size=9.4, lw=1.0, ls="-"):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.006,rounding_size=0.012",
                                fc=fill, ec=edge or fs.INK3, lw=lw, ls=ls))
    ax.text(x + 0.012, y + h - 0.012, title, va="top", ha="left", fontsize=title_size,
            fontweight="medium", color=title_color or fs.INK)
    if body:
        ax.text(x + 0.012, y + h - 0.042, body, va="top", ha="left", fontsize=size,
                color=fs.INK2, linespacing=1.35)


def arrow(ax, p, q, **kw):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle="-|>", mutation_scale=10,
                                 color=kw.pop("color", fs.INK2), lw=kw.pop("lw", 1.1), **kw))


def overview(out):
    fig, ax = plt.subplots(figsize=(8.4, 8.6))
    ax.set_xlim(-0.01, 1.08); ax.set_ylim(-0.17, 1.0); ax.axis("off")

    # Entities and state variables
    ax.text(0.0, 0.995, "Entities and state variables", fontsize=10.5, fontweight="medium", va="top")
    ents = [
        ("Depositors  (N = 1,000)",
         "deposit $d_i$ ~ LogNormal(1, σ)\ntype I or C; weight $\\lambda_I$ < $\\lambda_C$\n"
         "private signal $x_i = \\theta + s\\,\\varepsilon_i$\nbalance left; withdrawn or not"),
        ("Social network",
         "Watts–Strogatz (k, p): each depositor\nsees the share of its neighbours\nwho have withdrawn"),
        ("Bank",
         "reserves $rD$ (cash)\nlong asset $(1 - r + e)D$, sells at $1 - d$\nreturn $R(\\theta) = 1 + 0.4\\theta$ "
         "at period 2\npromises $R_{stay}$ per unit left in"),
        ("Environment",
         "fundamental θ ~ U[0, 1], one per run\npublic signal y: none, stale ($y_0$),\n"
         "tracks θ, or corrects ($\\rho$ per tick)"),
    ]
    y = 0.945
    for t, b in ents:
        h = 0.035 + 0.031 * (b.count("\n") + 1)
        box(ax, 0.0, y - h, 0.41, h, t, b)
        y -= h + 0.018

    # Process schedule
    X, W = 0.46, 0.50
    ax.text(X, 0.995, "Process schedule (one run)", fontsize=10.5, fontweight="medium", va="top")
    steps = [
        ("1  Cultural warm-up", "Flache–Macy dynamics on the network; the top μ\nbecome individualists (I), the rest collectivists (C)"),
        ("2  Draw the run's world", "θ; each depositor's $x_i$; the public signal $y_1$"),
        ("3  Exogenous shock", "a random set of depositors withdraws everything"),
    ]
    y = 0.945
    for t, b in steps:
        h = 0.035 + 0.031 * (b.count("\n") + 1)
        box(ax, X, y - h, W, h, t, b)
        y -= h + 0.028
        arrow(ax, (X + W / 2, y + 0.026), (X + W / 2, y + 0.003))

    # The tick loop
    loop_top = y
    inner = [
        ("a  Observe", "neighbours' withdrawals; public $y_t$"),
        ("b  Form beliefs (weight λ on the social side)",
         "θ:  $(1-\\lambda)\\,x_i + \\lambda\\,y_t$\nwithdrawals:  $(1-\\lambda)$ own prior + $\\lambda$ neighbours"),
        ("c  Value the options by Monte Carlo",
         "stay: period-2 payoff on the balance left in\nwithdraw: a fraction $f \\in$ {0, ¼, ½, ¾, 1},\npaid now, after any fire sale"),
        ("d  Act", "withdraw the best f; if cash is short,\nthe bank sells the long asset at $1 - d$"),
    ]
    hs = [0.035 + 0.031 * (b.count("\n") + 1) for _, b in inner]
    loop_h = sum(hs) + 0.022 * (len(inner) - 1) + 0.075
    ax.add_patch(FancyBboxPatch((X, loop_top - loop_h), W, loop_h,
                                boxstyle="round,pad=0.006,rounding_size=0.015",
                                fc=fs.BAND, ec=fs.INK3, lw=1.0))
    ax.text(X + 0.012, loop_top - 0.012, "4  Tick loop (banked depositors, random order)",
            va="top", fontsize=9.4, fontweight="medium")
    yy = loop_top - 0.05
    for (t, b), h in zip(inner, hs):
        box(ax, X + 0.02, yy - h, W - 0.075, h, t, b, size=8.3, title_size=8.9)
        yy -= h + 0.022
    # loop-back arrow on the right
    xr = X + W - 0.028
    ax.plot([X + W - 0.055, xr, xr], [yy + 0.06, yy + 0.06, loop_top - 0.075], color=fs.INK2, lw=1.0)
    arrow(ax, (xr, loop_top - 0.075), (X + W - 0.055, loop_top - 0.075))
    ax.text(X + W + 0.012, (yy + loop_top) / 2, "next tick,\nwhile anyone\nwithdrew", fontsize=7.8,
            color=fs.INK2, va="center")
    y = loop_top - loop_h - 0.028
    arrow(ax, (X + W / 2, y + 0.026), (X + W / 2, y + 0.003))
    tail = [
        ("5  Period 2", "liquidity failure if cash ran out mid-run; else the bank\nfails if cash + long asset at R(θ) < promises"),
        ("6  Record", "failure type; who ran by type ($W_I$, $W_C$; D and D\\$);\ntiming by tick; size deciles; partial withdrawals"),
    ]
    for i, (t, b) in enumerate(tail):
        h = 0.035 + 0.031 * (b.count("\n") + 1)
        box(ax, X, y - h, W, h, t, b)
        y -= h + 0.028
        if i < len(tail) - 1:
            arrow(ax, (X + W / 2, y + 0.026), (X + W / 2, y + 0.003))
    fig.savefig(out / "mock_odd_overview.png")
    plt.close(fig)


# Component rows: (label, {column: setting}); the reference column is r1t.
COLS = ["Vault model\n(current draft)", "Rung 1\n(r1t)", "Rung 1, partial\n(r1p, r1c)",
        "Rung 4: S1\n(r1c-none, r4-*)", "Fire-sale sweep\n(§3, §6)", "Super-individuals\n(later)"]
PLANNED = {"Fire-sale sweep\n(§3, §6)", "Super-individuals\n(later)"}
REF = "Rung 1\n(r1t)"
ROWS = [
    ("Balance sheet",       ["vault only", "fire-sale", "fire-sale", "fire-sale", "fire-sale", "fire-sale"]),
    ("Payoff compared",     ["P(paid in full)", "recovery", "recovery", "recovery", "recovery", "recovery"]),
    ("Fundamental θ",       ["none", "U[0, 1]", "U[0, 1]", "U[0, 1]", "U[0, 1]", "U[0, 1]"]),
    ("Private signal",      ["none", "of θ", "of θ", "of θ", "of θ", "of θ"]),
    ("Public signal of θ",  ["none", "none / stale /\ntracks / corrects", "=as r1t", "none", "stale", "to decide"]),
    ("λ weights",           ["head count", "both blends", "both blends", "both blends", "both blends", "both blends"]),
    ("Withdrawal",          ["all or nothing", "all or nothing", "fractions (¼)", "fractions (¼;\n1/20 in r4-g20)",
                             "fractions (grid\nafter r4-g20)", "share of cohort"]),
    ("Risk preference",     ["neutral", "neutral", "neutral (r1p);\nCARA 0.1 (r1c)", "CARA 0.1", "CARA 0.1", "to decide"]),
    ("Deposit insurance",   ["quantile axis", "none", "none", "none", "quantile axis", "none"]),
    ("Deposit spread σ",    ["axis", "2.5 (1 in one arm)", "=2.5 (1 in one arm)", "=2.5 (1 reported)",
                             "2.5, capped at 1%;\n1 counterfactual", "3.15 (platform)"]),
    ("Agent",               ["depositor", "depositor", "depositor", "depositor", "depositor", "cohort of ~542"]),
    ("Banks across cells",  ["own per cell", "shared (paired)", "shared (paired)", "shared (paired)", "shared (paired)", "shared (paired)"]),
]


def variants(out):
    nr, nc = len(ROWS), len(COLS)
    fig, ax = plt.subplots(figsize=(9.6, 6.4))
    ax.set_xlim(0, 1); ax.set_ylim(-0.07, 1); ax.axis("off")
    x0, cw = 0.17, (1 - 0.17) / nc
    top, rh = 0.88, 0.88 / nr
    refj = COLS.index(REF)
    for j, c in enumerate(COLS):
        ax.text(x0 + (j + 0.5) * cw, top + 0.015, c, ha="center", va="bottom", fontsize=8.6,
                fontweight="medium", color=fs.INK, fontstyle="italic" if c in PLANNED else "normal")
    ax.text(x0 + (refj + 0.5) * cw, top + 0.105, "reference", ha="center", fontsize=7.8, color=fs.INK2)
    for i, (lab, vals) in enumerate(ROWS):
        yc = top - (i + 0.5) * rh
        ax.text(x0 - 0.01, yc, lab, ha="right", va="center", fontsize=8.6, color=fs.INK)
        for j, v in enumerate(vals):
            same = v.startswith("=")          # same setting as the reference, labelled differently
            v = v.lstrip("=")
            differs = not same and v != ROWS[i][1][refj]
            planned = COLS[j] in PLANNED
            open_ = v == "to decide"
            differs = differs and not open_
            fill = "#3a3936" if differs else fs.BAND if open_ else "#ffffff"
            ax.add_patch(FancyBboxPatch((x0 + j * cw + 0.006, yc - rh / 2 + 0.006), cw - 0.012, rh - 0.012,
                                        boxstyle="round,pad=0,rounding_size=0.008", fc=fill,
                                        ec=fs.INK3, lw=0.7, ls=(0, (3, 2)) if planned else "-"))
            ax.text(x0 + (j + 0.5) * cw, yc, v, ha="center", va="center", fontsize=7.6,
                    color="#ffffff" if differs else fs.INK2, linespacing=1.1,
                    fontstyle="italic" if open_ else "normal")
    ax.text(0.0, -0.05, "Dark cells differ from the rung-1 reference; grey cells are open decisions. Dashed columns are planned and provisional.",
            fontsize=8, color=fs.INK2)
    fig.savefig(out / "mock_odd_variants.png")
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", type=Path, default=Path("outputs/mockups"))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    fs.use()
    overview(a.out)
    variants(a.out)
    print(f"wrote {a.out}/mock_odd_overview.png, mock_odd_variants.png")


if __name__ == "__main__":
    main()
