#!/usr/bin/env python3
"""Who runs, when, and who bears the losses, by cultural type (production arms, 2026-10-20).

The sweep-scale counterpart of scripts/who_runs_pilot.py. A production arm keeps no
per-agent logs (BANKRUN_LOG = summary); functions4.jl typeSummary() writes one row
per run x type instead, which consolidate_results.py gathers into
consolidated_types.csv. Reads <arm_dir>/consolidated_results.csv and
<arm_dir>/consolidated_types.csv and reports, by mu x lambda gap (lambdaC - lambdaI)
x reserveRatio (and pooled over reserve):

  0. P(run)  mean(bankRun), mean drainShare and P(drainShare >= 0.9), all mu.
             drainShare is skipped if the column is absent or blank (pre-10-15 runs).
  1. WHO     endogenous withdrawal rate nEndog / (n - nExog) per type. The seeded
             exogenous withdrawers are excluded, as in the pilot.
  2. WHEN    mean position of the type's endogenous withdrawers in the endogenous
             withdrawal order, posSumEndog / nEndog (0 = first, 1 = last, 0.5 if
             only one; typeSummary uses the pilot's definition). Plus the share of
             type I among the first-quarter endogenous withdrawers (pos <= 0.25)
             against type I's share of the non-exogenous population.
  3. LOSS    aggregates do not identify the exact loss: a stayer in a failed bank
             recovers min(deposit, cap), and the per-agent split is not kept. So:
               stay_share      depStayers / depTotal, deposits left in the bank,
                               failed runs (the pilot's denominator would exclude
                               the exogenous agents; this is the share of ALL the
                               type's deposits, as specified for the production arm).
               loss_upper      (depEndog - paidEndog + depStayers) / (depTotal - depExog),
                               failed runs: the pilot's loss_share with every stayer
                               treated as uninsured. An UPPER bound; EXACT when the
                               cap is 0 (depQuantile = 0: quantile(lognormal, 0) = 0).
                               The withdrawer term depEndog - paidEndog is exact.
             If depStayersUninsured is present (functions4.jl typeSummary, 10-20:
             the FULL deposits of stayers with deposit > insuranceCap):
               unins_exposure  depStayersUninsured / depTotal, failed runs: deposits
                               of uninsured stayers, i.e. at risk above AND below
                               the cap. Not a loss.
             and, if the run-level insuranceCap is also present and finite:
               loss_lo/loss_hi bounds on the pilot's loss_share, failed runs:
                               (depEndog - paidEndog + L) / (depTotal - depExog), with
                               L = depStayersUninsured - cap * m the stayers' loss
                               and m the number of uninsured stayers. m is not
                               recorded: with U = n - nInsured and Eu = nEndog -
                               nEndogInsured, m lies in [max(0, U - Eu - nExog), U - Eu]
                               because the exogenous withdrawers' insured split
                               is not kept. EXACT (lo = hi) when nExog = 0 for the
                               type, or when nExogInsured exists (then used).
                               Adding nExogInsured (or nStayersUninsured) to
                               typeSummary() would make LOSS exact everywhere.
  4. INSURED endogenous withdrawal rate among insured (nEndogInsured / nInsured) and
             uninsured ((nEndog - nEndogInsured) / (n - nInsured)) agents, by type,
             when nInsured and nEndogInsured exist. The denominators include the
             exogenous withdrawers unless nExogInsured exists too (then removed), so
             without it these rates are slightly low, by the same factor for I and C.
             depUninsured / depTotal and the run-level insuranceCap are reported
             if present. The block is skipped cleanly if the columns are absent.
             Under the adaptive scheme (depQuantile outside [0, 1)) insuranceCap is
             NaN and every agent counts as uninsured, so the split is empty there.

Uncertainty, as in the pilot: each run contributes ONE I - C difference (mixed
populations only, 0 < mu < 1; a run missing either type is dropped for that
statistic); the table reports their mean and a 95% CI across runs (1.96 x SE).
SEs clustered (CR1) on task_id and on paramSeed are reported alongside when those
columns exist. In the production design a paramSeed is one cell's replicate seed,
so the paramSeed SE is close to the run SE; task_id is the coarse one.

Differences from the pilot: WHEN uses the type's mean position (posSumEndog/nEndog),
i.e. the pilot's 'pos' averaged within run; the pilot's first-quarter table pools
withdrawers across runs, here it is a per-run share averaged over runs (failed runs).

Run: python3 scripts/who_runs_production.py <arm_dir> [--out DIR]
     (writes <out>/who_runs_{prun,contrasts,first_quarter,insured}.csv;
      default out = <arm_dir>/analysis)
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

GROUP = ["mu", "gap", "reserveRatio"]
INSURED_COLS = ["nInsured", "nEndogInsured"]


def as_flag(s):
    return s.astype(str).str.strip().str.lower().isin(["true", "t", "1", "1.0"])


def load(arm_dir):
    arm_dir = Path(arm_dir)
    res = pd.read_csv(arm_dir / "consolidated_results.csv", low_memory=False)
    typ = pd.read_csv(arm_dir / "consolidated_types.csv", low_memory=False)
    # A row counts only if the run finished AND wrote a result (analysis_p6b.R load_arm).
    has_result = res["bankRun"].notna() & res["bankRun"].astype(str).str.strip().ne("")
    res = res[as_flag(res["completed"]) & has_result].copy()
    res["bankRun"] = as_flag(res["bankRun"])
    res["gap"] = (res.lambdaC - res.lambdaI).round(2)
    for c in ("drainShare", "insuranceCap"):
        if c in res:
            res[c] = pd.to_numeric(res[c], errors="coerce")
    keep = ["key", "bankRun"] + [c for c in ("paramSeed", "drainShare", "insuranceCap") if c in res]
    typ = typ.merge(res[keep], on="key", how="inner")
    typ["gap"] = (typ.lambdaC - typ.lambdaI).round(2)
    return res, typ


def prun_table(res):
    """0. P(run) and drain share by mu x gap x reserve, plus pooled over reserve."""
    has_drain = "drainShare" in res and res.drainShare.notna().any()
    aggs = dict(runs=("bankRun", "size"), p_run=("bankRun", "mean"))
    if has_drain:
        aggs.update(drain_mean=("drainShare", "mean"), drain_n=("drainShare", "count"),
                    p_drain_ge_090=("drainShare", lambda x: (x.dropna() >= 0.9).mean()))
    if "insuranceCap" in res:
        aggs.update(insuranceCap_mean=("insuranceCap", "mean"))
    by = res.groupby(GROUP).agg(**aggs).reset_index()
    pooled = res.groupby(["mu", "gap"]).agg(**aggs).reset_index().assign(reserveRatio="pooled")
    return pd.concat([by, pooled[by.columns]], ignore_index=True)


def add_stats(typ):
    """Per run x type statistics (one row per run x type)."""
    t = typ.copy()
    with np.errstate(divide="ignore", invalid="ignore"):
        t["wd_rate"] = t.nEndog / (t.n - t.nExog)
        t["pos"] = np.where(t.nEndog > 0, t.posSumEndog / t.nEndog.where(t.nEndog > 0), np.nan)
        t["stay_share"] = t.depStayers / t.depTotal
        t["loss_upper"] = (t.depEndog - t.paidEndog + t.depStayers) / (t.depTotal - t.depExog)
        if "depStayersUninsured" in t:
            t["unins_exposure"] = t.depStayersUninsured / t.depTotal
            if "insuranceCap" in t and t.insuranceCap.notna().any() and "nInsured" in t:
                wd_loss = t.depEndog - t.paidEndog
                m_hi = (t.n - t.nInsured) - (t.nEndog - t.nEndogInsured)
                if "nStayersUninsured" in t and t.nStayersUninsured.notna().all():
                    m_lo = m_hi = t.nStayersUninsured        # exact (since 2026-10-20)
                elif "nExogInsured" in t:
                    m_lo = m_hi = m_hi - (t.nExog - t.nExogInsured)
                else:
                    m_lo = (m_hi - t.nExog).clip(lower=0)
                den = t.depTotal - t.depExog
                # more uninsured stayers -> more of their deposits covered up to the cap
                t["loss_lo"] = (wd_loss + (t.depStayersUninsured - t.insuranceCap * m_hi).clip(lower=0)) / den
                t["loss_hi"] = (wd_loss + (t.depStayersUninsured - t.insuranceCap * m_lo).clip(lower=0)) / den
        if "depUninsured" in t:
            t["unins_share"] = t.depUninsured / t.depTotal
        if all(c in t for c in INSURED_COLS):
            ex_i = t.nExogInsured if "nExogInsured" in t else 0
            ex_u = (t.nExog - t.nExogInsured) if "nExogInsured" in t else 0
            t["wd_rate_insured"] = t.nEndogInsured / (t.nInsured - ex_i)
            t["wd_rate_uninsured"] = (t.nEndog - t.nEndogInsured) / (t.n - t.nInsured - ex_u)
    return t.replace([np.inf, -np.inf], np.nan)


def cluster_se(x, cl):
    """CR1 SE of mean(x), clustered on cl; (se, n_clusters)."""
    x = np.asarray(x, float)
    u = pd.Series(x - x.mean()).groupby(np.asarray(cl)).sum()
    g, n = len(u), len(x)
    if g < 2:
        return np.nan, g
    return np.sqrt((u ** 2).sum() / n ** 2 * g / (g - 1)), g


def ic_contrast(t, col, subset="all"):
    """I - C per run, averaged by mu x gap x reserve (and pooled over reserve)."""
    m = t[(t.mu > 0) & (t.mu < 1)]
    if subset == "failed":
        m = m[m.bankRun]
    idx = ["key", "task_id"] + GROUP + (["paramSeed"] if "paramSeed" in m else [])
    w = m.pivot_table(index=idx, columns="type", values=col, aggfunc="first")
    if not {"I", "C"} <= set(w.columns):
        return pd.DataFrame()
    w = w[["I", "C"]].dropna().reset_index()
    w["d"] = w.I - w.C
    rows = []
    for pooled in (False, True):
        keys = ["mu", "gap"] if pooled else GROUP
        for k, s in w.groupby(keys):
            k = k if isinstance(k, tuple) else (k,)
            r = dict(zip(keys, k))
            if pooled:
                r["reserveRatio"] = "pooled"
            n = len(s)
            se = s.d.std(ddof=1) / np.sqrt(n) if n > 1 else np.nan
            r.update(stat=col, subset=subset, I=s.I.mean(), C=s.C.mean(), I_minus_C=s.d.mean(),
                     se_run=se, ci95_lo=s.d.mean() - 1.96 * se, ci95_hi=s.d.mean() + 1.96 * se,
                     runs=n)
            r["se_task"], r["n_task"] = cluster_se(s.d, s.task_id)
            if "paramSeed" in s:
                r["se_seed"], r["n_seed"] = cluster_se(s.d, s.paramSeed)
            rows.append(r)
    out = pd.DataFrame(rows)
    lead = ["stat", "subset"] + GROUP
    return out[lead + [c for c in out.columns if c not in lead]]


def first_quarter(t):
    """Type I share among first-quarter endogenous withdrawers vs I's population share, failed mixed runs."""
    m = t[(t.mu > 0) & (t.mu < 1) & t.bankRun]
    w = m.pivot_table(index=["key"] + GROUP, columns="type",
                      values=["nFirstQuarter", "n", "nExog"], aggfunc="first").dropna()
    if w.empty:
        return pd.DataFrame()
    fq = w["nFirstQuarter"]
    pop = w["n"] - w["nExog"]
    r = pd.DataFrame({"fq_share_I": fq.I / (fq.I + fq.C), "pop_share_I": pop.I / (pop.I + pop.C)})
    r = r.dropna().reset_index()
    r["excess"] = r.fq_share_I - r.pop_share_I
    out = r.groupby(["mu", "gap"]).agg(pop_share_I=("pop_share_I", "mean"),
                                       first_quarter_share_I=("fq_share_I", "mean"),
                                       excess=("excess", "mean"), runs=("key", "size")).reset_index()
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("arm_dir")
    ap.add_argument("--out", default=None, help="output dir (default <arm_dir>/analysis)")
    a = ap.parse_args(argv)
    out_dir = Path(a.out) if a.out else Path(a.arm_dir) / "analysis"
    out_dir.mkdir(parents=True, exist_ok=True)

    res, typ = load(a.arm_dir)
    t = add_stats(typ)
    pd.set_option("display.width", 180, "display.precision", 4, "display.max_rows", 400)
    print(f"arm: {a.arm_dir}; runs with a result: {len(res):,}; run x type rows matched: {len(typ):,}")

    pr = prun_table(res)
    if "drain_mean" not in pr:
        print("drainShare: absent or blank — drain columns skipped")
    print("\n0. P(run) and drain share, pooled over reserve:")
    print(pr[pr.reserveRatio == "pooled"].drop(columns="reserveRatio").to_string(index=False))
    pr.to_csv(out_dir / "who_runs_prun.csv", index=False)

    specs = [("wd_rate", "all"), ("wd_rate", "failed"), ("pos", "all"), ("pos", "failed"),
             ("stay_share", "failed"), ("loss_upper", "failed")]
    if "unins_exposure" in t:
        specs += [("unins_exposure", "failed")]
    else:
        print("\ndepStayersUninsured: absent — uninsured exposure and loss bounds skipped")
    if "loss_lo" in t:
        specs += [("loss_lo", "failed"), ("loss_hi", "failed")]
    elif "unins_exposure" in t:
        print("\ninsuranceCap absent or NaN (adaptive scheme) — loss bounds skipped")
    if "unins_share" in t:
        specs += [("unins_share", "all")]
    titles = {"wd_rate": "1. WHO: endogenous withdrawal rate nEndog/(n-nExog)",
              "pos": "2. WHEN: mean position among endogenous withdrawers (0 first, 1 last)",
              "stay_share": "3. LOSS: deposits left in the failed bank, depStayers/depTotal",
              "loss_upper": "3. LOSS: upper bound, stayers treated as uninsured (exact if cap = 0)",
              "unins_exposure": "3. LOSS: uninsured exposure of stayers, depStayersUninsured/depTotal",
              "loss_lo": "3. LOSS: share of non-exogenous deposits lost (pilot definition), LOWER bound",
              "loss_hi": "3. LOSS: share of non-exogenous deposits lost (pilot definition), UPPER bound",
              "unins_share": "4. INSURED: uninsured deposit share depUninsured/depTotal"}
    tabs = []
    for col, sub in specs:
        c = ic_contrast(t, col, sub)
        if c.empty:
            continue
        tabs.append(c)
        print(f"\n{titles[col]}  [{sub} runs; mixed mu; I - C per run; pooled over reserve]")
        show = c[c.reserveRatio == "pooled"].drop(columns=["stat", "subset", "reserveRatio"])
        print(show.to_string(index=False))

    if all(c in t for c in INSURED_COLS):
        ins = []
        for col in ("wd_rate_insured", "wd_rate_uninsured"):
            for sub in ("all", "failed"):
                c = ic_contrast(t, col, sub)
                if not c.empty:
                    ins.append(c)
        if ins:
            ins = pd.concat(ins, ignore_index=True)
            print("\n4. INSURED vs UNINSURED endogenous withdrawal rate (pooled over reserve):")
            print(ins[ins.reserveRatio == "pooled"].drop(columns="reserveRatio").to_string(index=False))
            ins.to_csv(out_dir / "who_runs_insured.csv", index=False)
    else:
        print("\nnInsured / nEndogInsured: absent — insured vs uninsured split skipped")

    con = pd.concat(tabs, ignore_index=True) if tabs else pd.DataFrame()
    con.to_csv(out_dir / "who_runs_contrasts.csv", index=False)
    fq = first_quarter(t)
    if not fq.empty:
        print("\n2b. Type I share of first-quarter endogenous withdrawers, failed mixed runs:")
        print(fq.to_string(index=False))
    fq.to_csv(out_dir / "who_runs_first_quarter.csv", index=False)
    print(f"\nwrote {out_dir}/who_runs_{{prun,contrasts,first_quarter"
          f"{',insured' if all(c in t for c in INSURED_COLS) else ''}}}.csv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
