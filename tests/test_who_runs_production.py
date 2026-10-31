#!/usr/bin/env python3
"""Ground-truth fixture for scripts/who_runs_production.py.

Builds a tiny synthetic arm (consolidated_results.csv + consolidated_types.csv in
the consolidate_results.py schemas) whose answers are worked out by hand below,
then checks every block:

  A  P(run), drain mean, P(drain >= 0.9) per cell; unobserved runs dropped
  B  WHO: I - C endogenous withdrawal rate, run SE and task_id-clustered CR1 SE
  C  WHEN: mean position posSumEndog / nEndog
  D  LOSS: stay share, upper bound, exposure and loss bounds from depStayersUninsured
  E  INSURED split, first-quarter share
  F  the same arm WITHOUT drainShare and the 10-20 insurance columns runs, skips
     those blocks, and leaves the other numbers unchanged
  G  make_figures.py figure_drain() draws from this arm and skips without drainShare

Hand-computed cells (gap = 0.7 - 0.3 = 0.4; every type has n = 10, nExog = 2):

  mu 0.5, r 0.1   run A failed, drain 1.0:  I nEndog 6 (0.75), C 2 (0.25)  d = +0.50
                  run B survived, drain 0.5: I 4 (0.50),      C 4 (0.50)  d =  0.00
  mu 0.5, r 0.2   run C failed:              I 4 (0.50),      C 2 (0.25)  d = +0.25
                  run D failed:              I 6 (0.75),      C 2 (0.25)  d = +0.50
  pooled over r: mean d = 0.3125; clustered on the 2 task_ids, the cluster
  residual sums are -0.125 and +0.125, so CR1 SE = sqrt(2 * 0.125^2 / 16 * 2) = 0.0625.

Run:  python3 tests/test_who_runs_production.py
"""

import importlib.util
import math
import os
import sys
import tempfile

import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


W = _load("who_runs_production", os.path.join(ROOT, "scripts", "who_runs_production.py"))

_passed = _failed = 0


def check(name, cond, detail=""):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f"  ok    {name}")
    else:
        _failed += 1
        print(f"  FAIL  {name}  {detail}")


def close(a, b, tol=1e-9):
    return a is not None and not (isinstance(a, float) and math.isnan(a)) and abs(a - b) < tol


# ── fixture ─────────────────────────────────────────────────────────────────
def trow(task, key, r, mu, typ, nEndog, posSum, nFQ, depEndog=40.0, paidEndog=40.0,
         depStayers=40.0, depSU=0.0, nIns=5, nEndogIns=2, n=10, nExog=2):
    return dict(task_id=task, key=key, armTag="synthetic", reserveRatio=r, depQuantile=0.5,
                sigma=2.0, k=6, p=0.05, mu=mu, lambdaI=0.3, lambdaC=0.7, type=typ, n=n,
                nExog=nExog, nEndog=nEndog, depTotal=100.0, depExog=20.0, depEndog=depEndog,
                depExog_=None, paidExog=20.0, paidEndog=paidEndog, depStayers=depStayers,
                posSumEndog=posSum, nFirstQuarter=nFQ, nInsured=nIns, nEndogInsured=nEndogIns,
                depUninsured=30.0, depStayersUninsured=depSU)


def rrow(task, seed, key, r, mu, run, drain, completed="true"):
    return dict(task_id=task, paramSeed=seed, replication=1, k=6, p=0.05, reserveRatio=r,
                depQuantile=0.5, sigma=2.0, warmupAlpha=0.1, mu=mu, lambdaI=0.3, lambdaC=0.7,
                seed=1, key=key, armTag="synthetic", assignRule="warmup", mcDepth=100,
                completed=completed, bankRun=run, nWithdrawn=50, depositWithdrawn=500.0,
                vaultInit=100.0, vaultFinal=0.0, drainShare=drain, insuranceCap=7.5)


def build(d, full=True):
    res = [
        rrow(1, 11, "A", 0.1, 0.5, "true", 1.0), rrow(1, 12, "B", 0.1, 0.5, "false", 0.5),
        rrow(2, 21, "C", 0.2, 0.5, "true", 0.95), rrow(2, 22, "D", 0.2, 0.5, "true", 0.8),
        rrow(3, 31, "E", 0.1, 0.0, "true", 1.0), rrow(3, 32, "F", 0.1, 0.0, "true", 0.7),
        rrow(4, 41, "G", 0.1, 1.0, "false", 0.2), rrow(4, 42, "H", 0.1, 1.0, "true", 1.0),
        # unobserved: completed but no result row, and a never-completed run
        rrow(4, 43, "X", 0.1, 1.0, "", ""), rrow(4, 44, "Y", 0.1, 1.0, "true", 1.0, completed=""),
    ]
    typ = [
        # run A (failed): I loses (60-50) + 20 stayers; C loses 0 + 60 stayers
        trow(1, "A", 0.1, 0.5, "I", 6, 1.2, 2, depEndog=60, paidEndog=50, depStayers=20, depSU=10,
             nIns=4, nEndogIns=1),
        trow(1, "A", 0.1, 0.5, "C", 2, 1.6, 0, depEndog=20, paidEndog=20, depStayers=60, depSU=45,
             nIns=4, nEndogIns=1),
        trow(1, "B", 0.1, 0.5, "I", 4, 2.0, 1), trow(1, "B", 0.1, 0.5, "C", 4, 2.0, 1),
        trow(2, "C", 0.2, 0.5, "I", 4, 1.0, 1), trow(2, "C", 0.2, 0.5, "C", 2, 1.0, 1),
        trow(2, "D", 0.2, 0.5, "I", 6, 1.5, 2), trow(2, "D", 0.2, 0.5, "C", 2, 1.0, 0),
        # endpoints: one type only (the other has n = 0) -> no I - C
        trow(3, "E", 0.1, 0.0, "C", 5, 2.5, 1), trow(3, "E", 0.1, 0.0, "I", 0, 0.0, 0, n=0, nExog=0),
        trow(4, "G", 0.1, 1.0, "I", 5, 2.5, 1), trow(4, "G", 0.1, 1.0, "C", 0, 0.0, 0, n=0, nExog=0),
    ]
    res, typ = pd.DataFrame(res), pd.DataFrame(typ).drop(columns="depExog_")
    if not full:
        res = res.drop(columns=["vaultInit", "vaultFinal", "drainShare", "insuranceCap"])
        typ = typ.drop(columns=["nInsured", "nEndogInsured", "depUninsured", "depStayersUninsured"])
    res.to_csv(os.path.join(d, "consolidated_results.csv"), index=False)
    typ.to_csv(os.path.join(d, "consolidated_types.csv"), index=False)


def row(df, **kw):
    m = pd.Series(True, index=df.index)
    for k, v in kw.items():
        m &= df[k].astype(str) == str(v)
    s = df[m]
    assert len(s) == 1, f"{kw}: {len(s)} rows"
    return s.iloc[0]


# ── tests ───────────────────────────────────────────────────────────────────
def run_full(d):
    build(d, full=True)
    res, typ = W.load(d)
    t = W.add_stats(typ)

    print("A  P(run) and drain share")
    check("unobserved runs dropped", len(res) == 8, f"got {len(res)}")
    pr = W.prun_table(res)
    c = row(pr, mu=0.5, gap=0.4, reserveRatio=0.1)
    check("P(run) mu .5 r .1 = 0.5", close(c.p_run, 0.5))
    check("drain mean mu .5 r .1 = 0.75", close(c.drain_mean, 0.75))
    check("P(drain >= .9) mu .5 r .1 = 0.5", close(c.p_drain_ge_090, 0.5))
    c = row(pr, mu=0.5, gap=0.4, reserveRatio="pooled")
    check("pooled P(run) mu .5 = 0.75", close(c.p_run, 0.75))
    check("pooled drain mu .5 = 0.8125", close(c.drain_mean, (1 + .5 + .95 + .8) / 4))
    check("pooled P(drain >= .9) mu .5 = 0.5", close(c.p_drain_ge_090, 0.5))
    check("mu = 0 cell present, P(run) = 1", close(row(pr, mu=0.0, reserveRatio=0.1).p_run, 1.0))
    check("insuranceCap carried", close(c.insuranceCap_mean, 7.5))

    print("B  WHO")
    who = W.ic_contrast(t, "wd_rate", "all")
    c = row(who, mu=0.5, reserveRatio=0.1)
    check("r .1: I - C = 0.25", close(c.I_minus_C, 0.25))
    check("r .1: run SE = 0.25", close(c.se_run, 0.25))
    check("r .1: I = 0.625, C = 0.375", close(c.I, 0.625) and close(c.C, 0.375))
    c = row(who, mu=0.5, reserveRatio="pooled")
    check("pooled: I - C = 0.3125", close(c.I_minus_C, 0.3125))
    check("pooled: 4 runs, 2 task clusters", c.runs == 4 and c.n_task == 2)
    check("pooled: task-clustered CR1 SE = 0.0625", close(c.se_task, 0.0625), f"got {c.se_task}")
    check("pooled: one run per paramSeed, so seed SE = run SE", c.n_seed == 4 and close(c.se_seed, c.se_run))
    check("endpoints excluded from I - C", set(who.mu) == {0.5})
    whof = W.ic_contrast(t, "wd_rate", "failed")
    check("failed only: pooled I - C = (0.5+0.25+0.5)/3",
          close(row(whof, mu=0.5, reserveRatio="pooled").I_minus_C, 1.25 / 3))

    print("C  WHEN")
    pos = W.ic_contrast(t, "pos", "failed")
    c = row(pos, mu=0.5, reserveRatio=0.1)
    check("run A: pos I 0.2, C 0.8, d = -0.6", close(c.I, 0.2) and close(c.C, 0.8) and close(c.I_minus_C, -0.6))

    print("D  LOSS")
    # cap 7.5. I: U = 6 uninsured, Eu = 5 of them withdrew -> m in [max(0, 1-2), 1] = [0, 1]
    #   loss_lo = (10 + 10 - 7.5) / 80, loss_hi = (10 + 10) / 80
    # C: U = 6, Eu = 1 -> m in [3, 5]; loss_lo = (45 - 37.5) / 80, loss_hi = (45 - 22.5) / 80
    for col, i, cc in (("stay_share", 0.2, 0.6), ("loss_upper", 0.375, 0.75),
                       ("unins_exposure", 0.1, 0.45),
                       ("loss_lo", 12.5 / 80, 7.5 / 80), ("loss_hi", 20 / 80, 22.5 / 80)):
        c = row(W.ic_contrast(t, col, "failed"), mu=0.5, reserveRatio=0.1)
        check(f"run A {col}: I {i}, C {cc}", close(c.I, i) and close(c.C, cc) and close(c.I_minus_C, i - cc))

    # with nExogInsured the bounds collapse: give run A's C both exog agents uninsured -> m = 3
    typ2 = typ.assign(nExogInsured=0)
    t2 = W.add_stats(typ2)
    c = t2[(t2.key == "A") & (t2.type == "C")].iloc[0]
    check("nExogInsured present: loss_lo = loss_hi = (45 - 22.5)/80",
          close(c.loss_lo, 22.5 / 80) and close(c.loss_hi, 22.5 / 80))

    # lossStayers (2026-10-31, fire-sale bank): the exact loss share; absent if all NaN
    typ3 = typ.assign(lossStayers=3.0)
    t3 = W.add_stats(typ3)
    want = (t3.depEndog - t3.paidEndog + 3.0) / (t3.depTotal - t3.depExog)
    check("lossStayers present: loss_exact = (depEndog - paidEndog + lossStayers) / (depTotal - depExog)",
          "loss_exact" in t3 and all(abs(t3.loss_exact - want).fillna(0) < 1e-12))
    check("lossStayers all NaN (vault bank): no loss_exact",
          "loss_exact" not in W.add_stats(typ.assign(lossStayers=float("nan"))))

    print("E  INSURED and first quarter")
    c = row(W.ic_contrast(t, "wd_rate_insured", "failed"), mu=0.5, reserveRatio=0.1)
    check("run A insured rate I = C = 0.25", close(c.I, 0.25) and close(c.C, 0.25))
    c = row(W.ic_contrast(t, "wd_rate_uninsured", "failed"), mu=0.5, reserveRatio=0.1)
    check("run A uninsured rate I 5/6, C 1/6", close(c.I, 5 / 6) and close(c.C, 1 / 6))
    fq = W.first_quarter(t)
    c = row(fq, mu=0.5, gap=0.4)
    # failed runs A, C, D: fq share I = 2/2, 1/2, 2/2; population share 0.5 each
    check("first-quarter share I = 5/6, excess 1/3",
          close(c.first_quarter_share_I, 5 / 6) and close(c.excess, 1 / 3) and c.runs == 3)

    out = os.path.join(d, "out")
    check("main() runs end to end", W.main([d, "--out", out]) == 0)
    check("insured CSV written", os.path.exists(os.path.join(out, "who_runs_insured.csv")))
    return who


def run_reduced(d, who_full):
    print("F  without drainShare and the insurance columns")
    build(d, full=False)
    res, typ = W.load(d)
    t = W.add_stats(typ)
    pr = W.prun_table(res)
    check("no drain columns", "drain_mean" not in pr)
    check("no exact-loss / insured stats", not {"loss_lo", "wd_rate_insured"} & set(t.columns))
    who = W.ic_contrast(t, "wd_rate", "all")
    check("WHO unchanged", close(row(who, mu=0.5, reserveRatio="pooled").I_minus_C,
                                 row(who_full, mu=0.5, reserveRatio="pooled").I_minus_C))
    out = os.path.join(d, "out")
    check("main() runs end to end", W.main([d, "--out", out]) == 0)
    check("no insured CSV", not os.path.exists(os.path.join(out, "who_runs_insured.csv")))


def run_figure(d_full, d_reduced):
    print("G  make_figures.py drain-share figure")
    try:
        import matplotlib
        matplotlib.use("Agg")
    except ImportError:
        print("  skip  matplotlib not installed")
        return
    MF = _load("make_figures", os.path.join(ROOT, "scripts", "make_figures.py"))
    for d, want in ((d_full, True), (d_reduced, False)):
        png = os.path.join(d, "fig_drain.png")
        made = MF.figure_1b_drain_share(os.path.join(d, "consolidated_results.csv"), png)
        check(f"drain figure {'made' if want else 'skipped'}", bool(made) == want and os.path.exists(png) == want)


def main():
    with tempfile.TemporaryDirectory() as d1, tempfile.TemporaryDirectory() as d2:
        who = run_full(d1)
        run_reduced(d2, who)
        build(d1, full=True)
        run_figure(d1, d2)
    print(f"\n{_passed} passed, {_failed} failed")
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
