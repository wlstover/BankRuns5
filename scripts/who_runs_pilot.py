#!/usr/bin/env python3
"""Who runs, when, and who bears the losses, by cultural type (pilot, 2026-10-13).

Reads outputs/who_runs_pilot/ (scripts/who_runs_pilot.jl) and reports, for the
mixed populations (0 < mu < 1), by lambda gap and by run outcome:

  1. WHO   share of each type that withdrew endogenously (the seeded exogenous
           withdrawers are excluded: they are a random shock, not a decision);
  2. WHEN  among endogenous withdrawers, position in the withdrawal sequence
           (0 = first, 1 = last) and the type mix of the first quarter of withdrawers;
  3. LOSS  share of each type's deposits lost. A withdrawer is paid in full while
           the vault covers the deposit, else max(vault, insured amount)
           (functions4.jl withdraw()); a stayer in a failed bank (vault <= 0 at the
           end) recovers only the insured amount min(deposit, cap); a stayer in a
           surviving bank loses nothing.

Uncertainty: each statistic is computed per run as I minus C, then averaged over
runs (mean +- 1.96 SE across runs), so within-run correlation is respected.

NB the ABM's lambda is the weight on the PRIVATE signal (type I = high lambda),
the opposite orientation to Ch 1's omega (weight on the public signal).

Run: python3 scripts/who_runs_pilot.py  (writes outputs/who_runs_pilot/summary.csv)
"""

from pathlib import Path

import numpy as np
import pandas as pd

D = Path(__file__).resolve().parent.parent / "outputs" / "who_runs_pilot"


def load():
    res = pd.read_csv(D / "results.csv")
    ag = pd.read_csv(D / "agents1.csv", header=None,
                     names=["key", "agent", "deposit", "lam", "warmupLambda", "type"])
    en = pd.read_csv(D / "bankRunEndogenous1.csv", header=None,
                     names=["key", "agent", "withdraw", "deposit", "tick", "vault", "wdProb", "stayProb"])
    ex = pd.read_csv(D / "bankRunExogenous1.csv", header=None,
                     names=["key", "agent", "exogenous", "deposit", "tick", "vault"])
    en["seq"] = np.arange(len(en))           # file order = decision order within a run
    ex["seq"] = -1
    return res, ag, en, ex


def payout(dep, vault_after, cap):
    before = vault_after + dep
    return np.where(dep > before, np.maximum.reduce([np.zeros_like(dep), before, np.minimum(dep, cap)]), dep)


def per_agent(res, ag, en, ex):
    wd = en[en.withdraw].copy()
    wd["how"] = "endog"
    ex = ex.copy(); ex["how"] = "exog"
    w = pd.concat([ex[["key", "agent", "deposit", "tick", "vault", "seq", "how"]],
                   wd[["key", "agent", "deposit", "tick", "vault", "seq", "how"]]])
    w = w.merge(res[["key", "insuranceCap"]], on="key")
    w["paid"] = payout(w.deposit.to_numpy(), w.vault.to_numpy(), w.insuranceCap.to_numpy())
    # order among endogenous withdrawers, 0 = first, 1 = last
    e = w[w.how == "endog"].sort_values("seq").copy()
    e["rank"] = e.groupby("key").cumcount()
    e["n"] = e.groupby("key")["agent"].transform("size")
    e["pos"] = np.where(e.n > 1, e["rank"] / (e.n - 1).clip(lower=1), 0.5)
    a = ag.merge(res, on="key").merge(w[["key", "agent", "how", "paid"]], on=["key", "agent"], how="left")
    a = a.merge(e[["key", "agent", "pos", "tick"]], on=["key", "agent"], how="left")
    a["withdrew_endog"] = a.how.eq("endog")
    a["exog"] = a.how.eq("exog")
    stay_paid = np.where(a.bankRun, np.minimum(a.deposit, a.insuranceCap), a.deposit)
    a["paid"] = np.where(a.how.isna(), stay_paid, a.paid)
    a["lost"] = a.deposit - a.paid
    a["gap"] = (a.lambdaC - a.lambdaI).round(2)
    return a


def run_level(a):
    """One row per (run, type) among agents not hit by the exogenous shock."""
    b = a[~a.exog]
    g = b.groupby(["key", "mu", "gap", "bankRun", "type"])
    out = g.agg(n=("agent", "size"), wd_rate=("withdrew_endog", "mean"),
                pos=("pos", "mean"), dep=("deposit", "sum"), lost=("lost", "sum")).reset_index()
    out["loss_share"] = out.lost / out.dep
    return out


def diff_ci(rl, col):
    w = rl.pivot_table(index=["key", "gap", "bankRun"], columns="type", values=col).dropna()
    d = (w["I"] - w["C"]).groupby(level=["gap", "bankRun"])
    m = w.groupby(level=["gap", "bankRun"]).mean()
    out = pd.DataFrame({"I": m["I"], "C": m["C"], "I_minus_C": d.mean(),
                        "ci95": 1.96 * d.std() / np.sqrt(d.count()), "runs": d.count()})
    return out


def first_quarter(a):
    e = a[a.withdrew_endog & a.bankRun & (a.mu > 0) & (a.mu < 1)]
    rows = []
    for gap, s in e.groupby("gap"):
        early = s[s.pos <= 0.25]
        rows.append(dict(gap=gap, pop_share_I=(a[(a.gap == gap) & (a.mu > 0) & (a.mu < 1)].type == "I").mean(),
                         withdrawers_share_I=(s.type == "I").mean(), first_quarter_share_I=(early.type == "I").mean(),
                         n_withdrawers=len(s)))
    return pd.DataFrame(rows)


def main():
    res, ag, en, ex = load()
    a = per_agent(res, ag, en, ex)
    mixed = a[(a.mu > 0) & (a.mu < 1)]
    rl = run_level(mixed)
    pd.set_option("display.width", 160, "display.precision", 3)

    print(f"runs: {len(res)}; bank runs: {res.bankRun.mean():.1%}; agents per run: {len(ag) // len(res)}")
    print("\nP(run) by mu and gap:")
    print(res.assign(gap=(res.lambdaC - res.lambdaI).round(2)).pivot_table(index="mu", columns="gap", values="bankRun"))
    print("\nMean withdrawers per run (endogenous + exogenous) by outcome:")
    print(res.groupby("bankRun").nWithdrawn.describe()[["mean", "50%", "min", "max"]])

    tabs = {}
    for col, title in (("wd_rate", "1. WHO: share of type withdrawing endogenously"),
                       ("pos", "2. WHEN: mean position in withdrawal sequence (0 first, 1 last)"),
                       ("loss_share", "3. LOSS: share of type's deposits lost")):
        t = diff_ci(rl, col)
        tabs[col] = t
        print(f"\n{title}  [mixed populations, mu in (0,1); I minus C per run, 95% CI across runs]")
        print(t)
    print("\n2b. Type mix among withdrawers in failed banks (mixed populations):")
    fq = first_quarter(a)
    print(fq.to_string(index=False))

    out = pd.concat({k: v for k, v in tabs.items()}, names=["stat"]).reset_index()
    out.to_csv(D / "summary.csv", index=False)
    fq.to_csv(D / "first_quarter.csv", index=False)
    a.to_csv(D / "agents_merged.csv.gz", index=False)
    print(f"\nwrote {D/'summary.csv'}, {D/'first_quarter.csv'}, {D/'agents_merged.csv.gz'}")


if __name__ == "__main__":
    main()
