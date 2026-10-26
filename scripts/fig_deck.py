#!/usr/bin/env python3
"""Ch 3 exhibits for the 2026-10-26 presentation (reference bank: r1k, cap 1%).

One figure per slide, mapped to the seven-section outline (docs/deck_2026-10-26.md):

  e01_sorting            §1  sorting change vs the public signal's gap (fig_rung1)
  e02_whoruns            §1  who withdraws across theta, by type, three arms (fig_rung1)
  e03_tests_by_bank      §1  the confirmatory tests on three versions of the bank
  e04_oneshot_by_size    §2  one-shot exit share by size: Celsius, r1c, r1k (held)
  e05_pfail_by_mu        §3  P(fail) by individualist share mu, per lambda pair
  e06_withdraw_by_mu     §3  share who withdraw, by type, across mu
  e07_herding            §3  P(withdraw | decision) by neighbours out, by type
  e08_pfail_by_signal    §4  P(fail) by public-signal arm, per lambda pair
  e09_channels           §4  who runs (D) when y is optimistic, lambda in one blend or both
  e10_concentration      §5  P(fail) by mu: sigma 1, sigma 2.5 capped, sigma 2.5 uncapped

95% CIs are CR1 on the 25 initialisations (t(24)), as in rung1_relational.py.

--lay writes the five seminar exhibits (e01, e05, e07, e08, e10) with plain-language
labels to figures/deck_lay/ (2026-10-26 seminar, lay audience); same data, same marks.

Usage:
    python3 scripts/fig_deck.py [--arms outputs] [--out figures/deck] [--lay]
"""

import argparse
import shutil
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import figstyle as fs                                          # noqa: E402
import fig_rung1                                                # noqa: E402
from rung1_relational import cmean, load                       # noqa: E402

T24 = 2.064
MUS = [0.0, 0.25, 0.5, 0.75, 1.0]
LAM_LABEL = {lam: fr"$\lambda_I={lam[0]},\ \lambda_C={lam[1]}$" for lam in fs.LAMBDA_PAIRS}
TECH = {
    "pair": LAM_LABEL, "pair_title": r"$\lambda$ pair",
    "mu": r"Share of individualists, $\mu$", "pfail": "P(bank fails)",
    "pfail_pooled": "P(bank fails), λ pairs pooled",
    "herd_x": "Share of the agent's neighbours who have withdrawn",
    "herd_y": "P(withdraw | deciding)",
    "signal": {"r1k-stale-y20": "Stale, y₀ = 0.2", "r1k-none": "None",
               "r1k-tracks-g0": "Tracks θ", "r1k-stale-y50": "Stale, y₀ = 0.5",
               "r1k-stale-y80": "Stale, y₀ = 0.8"},
    "signal_title": "Public signal",
    "bank": {"r4-s1-s10": "σ 1 (no concentration)", "r1k-none": "σ 2.5, cap 1% (reference)",
             "r1c-none": "σ 2.5, uncapped"},
    "bank_title": "Deposit distribution",
}
SIZE = {(0.1, 0.9): "Large (λ 0.1, 0.9)", (0.2, 0.8): "Medium (λ 0.2, 0.8)", (0.3, 0.5): "Small (λ 0.3, 0.5)"}
LAY = {
    "pair": SIZE, "pair_title": "Difference between types",
    "mu": "Share of depositors who are individualists", "pfail": "Chance the bank fails",
    "pfail_pooled": "Chance the bank fails",
    "herd_x": "Share of a depositor's neighbours who have withdrawn",
    "herd_y": "Chance of withdrawing",
    "signal": {"r1k-stale-y20": "Outdated, pessimistic", "r1k-none": "None",
               "r1k-tracks-g0": "Accurate", "r1k-stale-y50": "Outdated, middling",
               "r1k-stale-y80": "Outdated, optimistic"},
    "signal_title": "Public news",
    "bank": {"r4-s1-s10": "Deposits similar in size",
             "r1k-none": "A few large deposits, capped at 1%",
             "r1c-none": "A few large deposits, uncapped"},
    "bank_title": "Deposit sizes",
    "sorting": {
        "pair": SIZE, "end": SIZE, "title": "Difference between types",
        "right": "News too optimistic: theory predicts\nindividualists run more",
        "left": "News too pessimistic: theory predicts\ncollectivists run more",
        "x": "How far public news is from the truth\n(left: too pessimistic, right: too optimistic)",
        "y": "Individualists' run rate minus\ncollectivists', vs. no news",
    },
}
TXT = TECH        # main() swaps in LAY for --lay
# Celsius one-shot exit share by size (bank_runs_celsius whale_timing, negative-balance
# filter, 2026-10-23): D1-D5 0.82-0.90, D10 0.52, top 1% 0.38, top 0.1% 0.35.
CELSIUS = {"D1–D5": (0.82, 0.90), "D10": 0.52, "Top 1%": 0.38, "Top 0.1%": 0.35}


def ci(x, g):
    r = cmean(x, g, +1)
    h = T24 * r["se"] if np.isfinite(r["se"]) else 0.0
    return r["est"], r["est"] - h, r["est"] + h


def results(arm):
    r = pd.read_csv(arm / "consolidated_results.csv")
    b = pd.read_csv(arm / "consolidated_balance.csv", usecols=["task_id", "key", "failType"])
    r = r.merge(b, on=["task_id", "key"])
    r["failed"] = (r.failType != "none").astype(float)
    return r


def types(arm):
    r = pd.read_csv(arm / "consolidated_results.csv", usecols=["task_id", "key", "paramSeed"])
    t = pd.read_csv(arm / "consolidated_types.csv")
    t = t[t.n > t.nExog].merge(r, on=["task_id", "key"])
    t["W"] = t.nEndog / (t.n - t.nExog)
    return t


def lam_lines(ax, df, x, y, xs):
    for lam in fs.LAMBDA_PAIRS:
        sub = df[(df.lambdaI == lam[0]) & (df.lambdaC == lam[1])]
        e = np.array([ci(sub.loc[sub[x] == v, y], sub.loc[sub[x] == v, "paramSeed"]) for v in xs])
        c = fs.LAMBDA_INK[lam]
        ax.fill_between(xs, e[:, 1], e[:, 2], color=c, alpha=0.12, lw=0)
        ax.plot(xs, e[:, 0], color=c, marker=fs.LAMBDA_MARK[lam], label=TXT["pair"][lam])
    ax.legend(fontsize=8.5, title=TXT["pair_title"], title_fontsize=8.5)


def e01_e02(arms, out):
    tmp = out / "_rung1"
    tmp.mkdir(exist_ok=True)
    base = load(arms / "r1k-none")
    stale = pd.concat([load(arms / f"r1k-stale-y{y}") for y in (20, 50, 80)], ignore_index=True)
    fig_rung1.fig_sorting(base, stale, tmp)
    fig_rung1.fig_whoruns({"No public signal": base,
                           "Stale y₀ = 0.2": load(arms / "r1k-stale-y20"),
                           "Stale y₀ = 0.8": load(arms / "r1k-stale-y80")}, tmp,
                          y0s={"Stale y₀ = 0.2": 0.2, "Stale y₀ = 0.8": 0.8})
    shutil.move(tmp / "mock_fig_sorting.png", out / "e01_sorting.png")
    shutil.move(tmp / "mock_fig_whoruns.png", out / "e02_whoruns.png")
    tmp.rmdir()


def e01_lay(arms, out):
    tmp = out / "_rung1"
    tmp.mkdir(exist_ok=True)
    base = load(arms / "r1k-none")
    stale = pd.concat([load(arms / f"r1k-stale-y{y}") for y in (20, 50, 80)], ignore_index=True)
    fig_rung1.fig_sorting(base, stale, tmp, lab=LAY["sorting"])
    shutil.move(tmp / "mock_fig_sorting.png", out / "e01_sorting.png")
    tmp.rmdir()


def e03_tests_by_bank(arms, out):
    banks = [("r1t", "risk-neutral,\nall or nothing"), ("r1c", "CARA 0.1,\npartial"),
             ("r1k", "CARA 0.1, partial,\ncap 1% (reference)")]
    tests = [("G1'", +1), ("G4'", -1), ("G2a'", +1), ("G3", +1), ("G3c", +1)]
    rows = []
    for tag, lab in banks:
        a = arms / f"{tag}-analysis"
        t = pd.concat([pd.read_csv(a / "rung1_tests_D.csv"), pd.read_csv(a / "rung1_g3c_D.csv")])
        for _, r in t.iterrows():
            rows.append(dict(bank=lab, test=r.test, lambdas=r.lambdas, est=r.est, se=r.se))
    d = pd.DataFrame(rows)
    fig, axes = plt.subplots(1, len(tests), figsize=(9.6, 3.4), sharey=True,
                             gridspec_kw=dict(wspace=0.35))
    ys = np.arange(len(banks))[::-1].astype(float)
    for ax, (name, sign) in zip(axes, tests):
        dt = d[d.test == name]
        s = dt[dt.lambdas == "pooled"].set_index("bank").loc[[b for _, b in banks]]
        lo, hi = s.est - T24 * s.se, s.est + T24 * s.se
        lim = max(dt.est.abs().max(), hi.abs().max(), lo.abs().max()) * 1.25
        ax.axvspan(0, sign * lim, color=fs.BAND, zorder=0)
        ax.axvline(0, color=fs.INK3, lw=0.8)
        ax.hlines(ys, lo, hi, color=fs.INK, lw=2)
        ax.plot(s.est, ys, "o", color=fs.INK, ms=6, zorder=3, label="Pooled, 95% CI")
        for k, lam in enumerate(fs.LAMBDA_PAIRS):
            pe = dt[dt.lambdas == str(lam)].set_index("bank").loc[[b for _, b in banks], "est"]
            ax.plot(pe, ys - 0.2 - 0.12 * k, fs.LAMBDA_MARK[lam], ms=4.5, mfc="none",
                    mec=fs.LAMBDA_INK[lam], mew=1.2, zorder=3, label=LAM_LABEL[lam])
        ax.set_xlim(-lim, lim)
        ax.set_title(name + (" (post hoc)" if name == "G3c" else ""), fontsize=10, loc="left")
        ax.tick_params(axis="x", labelsize=8)
        ax.grid(axis="y", visible=False)
    axes[0].set_yticks(ys - 0.15)
    axes[0].set_yticklabels([b for _, b in banks], fontsize=8.5)
    h, l = axes[0].get_legend_handles_labels()
    fig.legend(h, l, loc="lower center", ncol=4, fontsize=8.5, bbox_to_anchor=(0.5, -0.1))
    fig.text(0.5, -0.17, "Head-count D. Shaded side = Ch 1's predicted sign; hollow markers = each λ pair",
             ha="center", fontsize=9, color=fs.INK2)
    fig.savefig(out / "e03_tests_by_bank.png")
    plt.close(fig)


def e04_oneshot_by_size(arms, out):
    groups = ["D1–D5", "D10", "Top 1%", "Top 0.1%"]
    keys = {"D10": "d10", "Top 1%": "top1", "Top 0.1%": "top01"}
    x = np.arange(len(groups))
    fig, ax = plt.subplots(figsize=(6.0, 3.6))
    lo, hi = CELSIUS["D1–D5"]
    ax.fill_between([-0.15, 0.15], lo, hi, color=fs.INK, alpha=0.18, lw=0)
    cel = [np.mean(CELSIUS["D1–D5"])] + [CELSIUS[g] for g in groups[1:]]
    ax.plot(x, cel, color=fs.INK, marker="o", label="Celsius (2022)")
    for tag, lab, c, m in (("r1c", "ABM, uncapped", "#6b6a66", "s"),
                           ("r1k", "ABM, cap 1% (reference)", "#a9a8a3", "^")):
        s = pd.read_csv(arms / f"{tag}-analysis" / "rung4_s1_curve.csv").set_index("group")
        v = [s.loc[[f"d{i}" for i in range(1, 6)], "oneshot_pooled"].mean()] + \
            [s.loc[keys[g], "oneshot_pooled"] for g in groups[1:]]
        ax.plot(x, v, color=c, marker=m, label=lab)
    ax.set_xticks(x)
    ax.set_xticklabels(groups)
    ax.set_ylim(0, 1.05)
    ax.set_xlabel("Depositor size group")
    ax.set_ylabel("Exits that withdraw everything at once")
    ax.legend(fontsize=8.5, loc="lower left")
    fig.savefig(out / "e04_oneshot_by_size.png")
    plt.close(fig)


def e05_pfail_by_mu(arms, out):
    r = results(arms / "r1k-none")
    fig, ax = plt.subplots(figsize=(6.0, 3.8))
    lam_lines(ax, r, "mu", "failed", MUS)
    ax.set_xticks(MUS)
    ax.set_ylim(0, None)
    ax.set_xlabel(TXT["mu"])
    ax.set_ylabel(TXT["pfail"])
    fig.savefig(out / "e05_pfail_by_mu.png")
    plt.close(fig)


def e06_withdraw_by_mu(arms, out):
    t = types(arms / "r1k-none")
    fig, axes = plt.subplots(1, 3, figsize=(9.0, 3.2), sharey=True, gridspec_kw=dict(wspace=0.1))
    for ax, lam in zip(axes, fs.LAMBDA_PAIRS):
        sub = t[(t.lambdaI == lam[0]) & (t.lambdaC == lam[1])]
        for ty, c, lab in (("I", fs.INDIV, "Individualists"), ("C", fs.COLLECT, "Collectivists")):
            s = sub[sub.type == ty]
            xs = [m for m in MUS if (s.mu == m).any()]
            e = np.array([ci(s.loc[s.mu == m, "W"], s.loc[s.mu == m, "paramSeed"]) for m in xs])
            ax.fill_between(xs, e[:, 1], e[:, 2], color=c, alpha=0.15, lw=0)
            ax.plot(xs, e[:, 0], color=c, marker="o", label=lab)
        ax.set_title(LAM_LABEL[lam], fontsize=9.5, loc="left")
        ax.set_xticks(MUS)
        ax.set_xlabel(r"Share of individualists, $\mu$")
    axes[0].set_ylabel("Share who withdraw\n(not hit by the shock)")
    axes[0].set_ylim(0, None)
    axes[0].legend(fontsize=8.5)
    fig.savefig(out / "e06_withdraw_by_mu.png")
    plt.close(fig)


def e07_herding(arms, out):
    s = pd.read_csv(arms / "r1k-analysis" / "rung4_s3_rates.csv", index_col=0).dropna(how="all")
    mid = {"0": 0.0, "(.1,.2]": 0.15, "(.2,.35]": 0.275, "(.35,.5]": 0.425, "(.5,1]": 0.75}
    x = [mid[i] for i in s.index]
    fig, ax = plt.subplots(figsize=(6.0, 3.6))
    for ty, c, lab in (("C", fs.COLLECT, "Collectivists"), ("I", fs.INDIV, "Individualists")):
        ax.plot(x, s[ty], color=c, marker="o", label=lab)
        ax.annotate(lab, (x[-1], s[ty].iloc[-1]), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=8.5, color=fs.INK2)
    ax.set_xlim(-0.02, 0.92)
    ax.set_ylim(0, 1.05)
    ax.set_xlabel(TXT["herd_x"])
    ax.set_ylabel(TXT["herd_y"])
    ax.legend(fontsize=8.5, loc="center right")
    fig.savefig(out / "e07_herding.png")
    plt.close(fig)


def e08_pfail_by_signal(arms, out):
    order = [(t, TXT["signal"][t]) for t in
             ("r1k-stale-y20", "r1k-none", "r1k-tracks-g0", "r1k-stale-y50", "r1k-stale-y80")]
    fig, ax = plt.subplots(figsize=(6.4, 3.4))
    ys = np.arange(len(order))[::-1]
    off = {lam: o for lam, o in zip(fs.LAMBDA_PAIRS, (0.18, 0, -0.18))}
    for lam in fs.LAMBDA_PAIRS:
        e = []
        for tag, _ in order:
            r = results(arms / tag)
            sub = r[(r.lambdaI == lam[0]) & (r.lambdaC == lam[1])]
            e.append(ci(sub.failed, sub.paramSeed))
        e = np.array(e)
        c = fs.LAMBDA_INK[lam]
        ax.hlines(ys + off[lam], e[:, 1], e[:, 2], color=c, lw=2)
        ax.plot(e[:, 0], ys + off[lam], fs.LAMBDA_MARK[lam], color=c, ms=6, label=TXT["pair"][lam])
    ax.set_yticks(ys)
    ax.set_yticklabels([lab for _, lab in order])
    ax.grid(axis="y", visible=False)
    ax.set_xlim(0, None)
    ax.set_xlabel(TXT["pfail"])
    ax.set_ylabel(TXT["signal_title"])
    ax.legend(fontsize=8.5, title=TXT["pair_title"], title_fontsize=8.5, loc="lower right")
    fig.savefig(out / "e08_pfail_by_signal.png")
    plt.close(fig)


def e09_channels(arms, out, gap=0.1):
    order = [("r1k-stale-y80-count", "λ in the head-count\nblend only"),
             ("r1k-stale-y80-theta", "λ in the θ-signal\nblend only"),
             ("r1k-stale-y80", "λ in both\n(model default)")]
    fig, ax = plt.subplots(figsize=(6.4, 3.6))
    x = np.arange(len(order))
    off = {lam: o for lam, o in zip(fs.LAMBDA_PAIRS, (-0.2, 0, 0.2))}
    data = {tag: load(arms / tag) for tag, _ in order}
    for lam in fs.LAMBDA_PAIRS:
        e = []
        for tag, _ in order:
            d = data[tag]
            d = d[(d.lambdaI == lam[0]) & (d.lambdaC == lam[1]) & (d.gap1 > gap) & d.failed]
            e.append(ci(d.D, d.paramSeed))
        e = np.array(e)
        c = fs.LAMBDA_INK[lam]
        ax.vlines(x + off[lam], e[:, 1], e[:, 2], color=c, lw=2)
        ax.plot(x + off[lam], e[:, 0], fs.LAMBDA_MARK[lam], color=c, ms=6, label=LAM_LABEL[lam])
    ax.axhline(0, color=fs.INK3, lw=0.8)
    ax.set_xticks(x)
    ax.set_xticklabels([lab for _, lab in order], fontsize=9)
    ax.grid(axis="x", visible=False)
    ax.set_ylabel("Who runs: $D = W_I - W_C$\n" + r"(failed runs, $y_1-\theta>0.1$)")
    ax.legend(fontsize=8.5, title=r"$\lambda$ pair", title_fontsize=8.5, loc="upper left")
    fig.savefig(out / "e09_channels.png")
    plt.close(fig)


def e10_concentration(arms, out):
    banks = [(t, TXT["bank"][t], c, m) for t, c, m in
             (("r4-s1-s10", "#a9a8a3", "^"), ("r1k-none", "#6b6a66", "s"), ("r1c-none", "#1f1f1d", "o"))]
    fig, ax = plt.subplots(figsize=(6.0, 3.8))
    for tag, lab, c, m in banks:
        r = results(arms / tag)
        e = np.array([ci(r.loc[r.mu == v, "failed"], r.loc[r.mu == v, "paramSeed"]) for v in MUS])
        ax.fill_between(MUS, e[:, 1], e[:, 2], color=c, alpha=0.12, lw=0)
        ax.plot(MUS, e[:, 0], color=c, marker=m, label=lab)
    ax.set_xticks(MUS)
    ax.set_ylim(0, None)
    ax.set_xlabel(TXT["mu"])
    ax.set_ylabel(TXT["pfail_pooled"])
    ax.legend(fontsize=8.5, title=TXT["bank_title"], title_fontsize=8.5)
    fig.savefig(out / "e10_concentration.png")
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--arms", type=Path, default=Path("outputs"))
    ap.add_argument("--out", type=Path, default=None, help="default figures/deck (figures/deck_lay with --lay)")
    ap.add_argument("--lay", action="store_true", help="plain-language labels, seminar exhibits only")
    a = ap.parse_args()
    a.out = a.out or Path("figures/deck_lay" if a.lay else "figures/deck")
    a.out.mkdir(parents=True, exist_ok=True)
    fs.use()
    if a.lay:
        global TXT
        TXT = LAY
        e01_lay(a.arms, a.out)
        figs = (e05_pfail_by_mu, e07_herding, e08_pfail_by_signal, e10_concentration)
    else:
        e01_e02(a.arms, a.out)
        figs = (e03_tests_by_bank, e04_oneshot_by_size, e05_pfail_by_mu, e06_withdraw_by_mu,
                e07_herding, e08_pfail_by_signal, e09_channels, e10_concentration)
    for f in figs:
        f(a.arms, a.out)
    print(f"wrote {len(list(a.out.glob('e*.png')))} figures to {a.out}")


if __name__ == "__main__":
    main()
