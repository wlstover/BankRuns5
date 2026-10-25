#!/usr/bin/env python3
"""Ch 3 rung-1 figures from the r1t arms (MOCKUPS, 2026-10-22).

  sorting:  channel-isolated sorting D_arm - D_none against the gap y1 - theta,
            stale arms pooled, one line per lambda pair, with Ch 1's predicted
            sign shaded (G1' right of +g, G4' left of -g).
  whoruns:  who runs across fundamentals: W_I and W_C by theta bin, one panel
            per arm (none, stale-y20, stale-y80), with P(fail) in a strip above;
            the coordination band (pilot_map F10) shaded.

Usage:
    python3 scripts/fig_rung1.py --arms outputs --prefix r1t --out outputs/mockups
"""

import argparse
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import figstyle as fs                                         # noqa: E402
from rung1_relational import PAIR, cmean, load, paired        # noqa: E402

GAP_G = 0.1
THETA_L, BAND_HI = 0.10, 0.40      # coordination band, pilot_map F10
SORT_LAB = {
    "pair": {lam: fr"$\lambda_I={lam[0]},\ \lambda_C={lam[1]}$" for lam in fs.LAMBDA_PAIRS},
    "end": {lam: fr"{lam[0]} / {lam[1]}" for lam in fs.LAMBDA_PAIRS},
    "right": "y optimistic: Ch 1 predicts\nindividualists run more (G1')",
    "left": "y pessimistic: Ch 1 predicts\ncollectivists run more (G4')",
    "x": r"Public signal's gap at tick 1,  $y_1 - \theta$",
    "y": "Change in sorting vs. no public signal\n" + r"$D - D_{\mathrm{none}}$  ($D = W_I - W_C$)",
    "title": r"$\lambda$ pair",
}


def binned(df, x, y, bins):
    """Mean of y by x bin, with a 95% CI clustered on the initialisation."""
    d = df.assign(bin=pd.cut(df[x], bins, include_lowest=True))
    rows = []
    for b, g in d.groupby("bin", observed=True):
        r = cmean(g[y], g.paramSeed, +1)
        h = 2.064 * r["se"] if np.isfinite(r["se"]) else np.nan    # t(24) 97.5%
        rows.append(dict(mid=b.mid, est=r["est"], lo=r["est"] - h, hi=r["est"] + h, n=r["n"]))
    return pd.DataFrame(rows)


def fig_sorting(base, stale, out, lab=None):
    """lab: optional plain-language labels (fig_deck.py --lay); keys as in SORT_LAB."""
    lab = {**SORT_LAB, **(lab or {})}
    m = paired(stale, base, ["D"], "_base")
    m["dD"] = m.D - m.D_base
    bins = np.round(np.arange(-0.8, 0.81, 0.1), 2)
    fig, ax = plt.subplots(figsize=(6.4, 3.9))
    ax.axvspan(GAP_G, 0.8, color=fs.BAND, zorder=0)
    ax.axvspan(-0.8, -GAP_G, color=fs.BAND, zorder=0)
    ax.axhline(0, color=fs.INK3, lw=0.8, zorder=1)
    for lam in fs.LAMBDA_PAIRS:
        sub = m[(m.lambdaI == lam[0]) & (m.lambdaC == lam[1])]
        b = binned(sub, "gap1", "dD", bins)
        c = fs.LAMBDA_INK[lam]
        ax.fill_between(b.mid, b.lo, b.hi, color=c, alpha=0.12, lw=0, zorder=2)
        ax.plot(b.mid, b.est, color=c, marker=fs.LAMBDA_MARK[lam], zorder=3,
                label=lab["pair"][lam])
        ax.annotate(lab["end"][lam], (b.mid.iloc[-1], b.est.iloc[-1]),
                    xytext=(6, 0), textcoords="offset points", va="center",
                    fontsize=8.5, color=fs.INK2)
    ax.text(0.45, 0.97, lab["right"],
            transform=ax.get_xaxis_transform(), ha="center", va="top", fontsize=8.5, color=fs.INK2)
    ax.text(-0.45, 0.97, lab["left"],
            transform=ax.get_xaxis_transform(), ha="center", va="top", fontsize=8.5, color=fs.INK2)
    ax.set_xlim(-0.8, 0.95)
    ax.set_xlabel(lab["x"])
    ax.set_ylabel(lab["y"])
    ax.legend(loc="lower right", fontsize=8.5, title=lab["title"], title_fontsize=8.5)
    fig.savefig(out / "mock_fig_sorting.png")
    plt.close(fig)


def fig_whoruns(arms, out, lam=(0.1, 0.9), y0s=None):
    bins = np.round(np.arange(0, 1.0001, 0.1), 2)
    names = list(arms)
    fig, axes = plt.subplots(2, len(names), figsize=(7.6, 4.4), sharex=True,
                             gridspec_kw=dict(height_ratios=[1, 2.4], hspace=0.08, wspace=0.12))
    for j, nm in enumerate(names):
        df = arms[nm]
        df = df[(df.lambdaI == lam[0]) & (df.lambdaC == lam[1])]
        top, bot = axes[0, j], axes[1, j]
        for a in (top, bot):
            a.axvspan(THETA_L, BAND_HI, color=fs.BAND, zorder=0)
            y0 = (y0s or {}).get(nm)
            y0 is None or a.axvline(y0, color=fs.INK2, lw=1, ls=(0, (4, 3)), zorder=1)
        y0 = (y0s or {}).get(nm)
        if y0 is not None:
            right = y0 < 0.5
            bot.text(y0 + (0.02 if right else -0.02), 0.97, "θ = y₀", ha="left" if right else "right",
                     transform=bot.get_xaxis_transform(), va="top", fontsize=8, color=fs.INK2)
        pf = df.assign(bin=pd.cut(df.theta, bins, include_lowest=True)).groupby("bin", observed=True).failed.mean()
        top.bar([b.mid for b in pf.index], pf.values, width=0.085, color=fs.INK3, zorder=2)
        top.set_ylim(0, 1)
        top.set_yticks([0, 0.5, 1])
        top.set_title(nm, fontsize=10, loc="left", color=fs.INK)
        for col, c, lab in (("W_I", fs.INDIV, "Individualists"), ("W_C", fs.COLLECT, "Collectivists")):
            b = binned(df, "theta", col, bins)
            bot.fill_between(b.mid, b.lo, b.hi, color=c, alpha=0.15, lw=0)
            bot.plot(b.mid, b.est, color=c, marker="o", label=lab)
        bot.set_ylim(0, None)
        bot.set_xlabel(r"Fundamental $\theta$")
        if j == 0:
            top.set_ylabel("P(fail)")
            bot.set_ylabel("Share who withdraw\n(not hit by the shock)")
        else:
            top.set_yticklabels([]); bot.set_yticklabels([])
    ymax = max(a.get_ylim()[1] for a in axes[1])
    for a in axes[1]:
        a.set_ylim(0, ymax)
    axes[1, 0].text((THETA_L + BAND_HI) / 2, ymax * 0.97, "coordination\nband", ha="center",
                    va="top", fontsize=8, color=fs.INK2)
    h, l = axes[1, 0].get_legend_handles_labels()
    fig.legend(h, l, loc="lower center", ncol=2, fontsize=9, bbox_to_anchor=(0.5, -0.06))
    fig.savefig(out / "mock_fig_whoruns.png")
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--arms", type=Path, default=Path("outputs"))
    ap.add_argument("--prefix", default="r1t")
    ap.add_argument("--out", type=Path, default=Path("outputs/mockups"))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    fs.use()
    p = a.prefix
    base = load(a.arms / f"{p}-none")
    stale = pd.concat([load(a.arms / f"{p}-stale-y{y}") for y in (20, 50, 80)], ignore_index=True)
    fig_sorting(base, stale, a.out)
    fig_whoruns({"No public signal": base,
                 "Stale y₀ = 0.2": load(a.arms / f"{p}-stale-y20"),
                 "Stale y₀ = 0.8": load(a.arms / f"{p}-stale-y80")}, a.out,
                y0s={"Stale y₀ = 0.2": 0.2, "Stale y₀ = 0.8": 0.8})
    print(f"wrote {a.out}/mock_fig_sorting.png, mock_fig_whoruns.png")


if __name__ == "__main__":
    main()
