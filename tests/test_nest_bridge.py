#!/usr/bin/env python3
"""Ground truth for scripts/nest_bridge.py (F8) and scripts/nest_cutoffs.py (F9), rung 2.

  A  theta_needed inverts the nest bank's A*(theta); A* at the decided values
  B  p_solvent (closed form) against brute-force integration over theta
  C  p_withdraw_D against a direct Binomial count of the strict rule
  D  best_split puts a deterministic cutoff in the gap
  E  F9 end to end on synthetic decisions drawn from (b_D): truth PASSES, a rule
     shifted by 0.02 in x FAILS (two-sided: a stuck PASS would look like docking)
  F  (a) with the nest bank: where the other type never runs (mu = 0), Chapter 1's
     low equilibrium for type I is (b)'s cutoff (needs bank_runs_theory; skipped
     with a message if it is not there)

Run:  python3 tests/test_nest_bridge.py
"""

import math
import os
import subprocess
import sys
import tempfile
from dataclasses import replace
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.stats import binom

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import nest_bridge as NB      # noqa: E402
import nest_cutoffs as NC     # noqa: E402

_passed = _failed = 0


def check(name, cond, detail=""):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f"  PASS  {name}")
    else:
        _failed += 1
        print(f"  FAIL  {name}  {detail}")


def p_brute(n, est, om, m=40001):
    w = (1 - om) * n.eps_x + om * n.eps_y
    lo, hi = max(est - w, 0.0), min(est + w, 1.0)
    th = np.linspace(lo, hi, m)
    A, pg = NB.prior_withdrawn(n)
    ok = A[None, :] <= NB.a_star(n, th)[:, None]
    return float((ok.mean(axis=0) * pg).sum())


def synthetic(n, cells, shift, runs, agents, rng):
    rows = []
    for mu, lI, lC in cells:
        for run in range(runs):
            th = rng.uniform()
            for a in range(agents):
                om = lI if a < mu * agents else lC
                x = th + rng.uniform(-n.eps_x, n.eps_x)
                pw = NB.p_withdraw_D(n, NB.p_solvent(n, (1 - om) * (x - shift) + om * n.y, om))
                rows.append((mu, lI, lC, f"{mu}-{lI}-{run}", a, om, x, rng.uniform() < pw))
    return pd.DataFrame(rows, columns=["mu", "lambdaI", "lambdaC", "key", "agent", "individualism",
                                       "x", "withdrew"])


def main():
    n = NB.Nest()
    print("=== A. A*(theta) and its inverse ===")
    A = np.array([0.01, 0.1, 0.3, 0.5, 0.7, 0.8])
    check("A*(theta_needed(A)) = A", np.allclose(NB.a_star(n, NB.theta_needed(n, A)), A))
    got = NB.a_star(n, [0.2, 0.3, 0.5, 0.7, 0.9])
    check("A* at 0.2/0.3/0.5/0.7/0.9 = 0.460/0.612/0.743/0.801/0.835 (decided 10-31)",
          np.allclose(got, [0.460, 0.612, 0.743, 0.801, 0.835], atol=6e-4), got)
    check("A* increasing in theta", np.all(np.diff(NB.a_star(n, np.linspace(0, 1, 101))) > 0))
    check("no theta saves a bank past its liquidation value",
          np.isinf(NB.theta_needed(n, np.array([0.999]))).all())

    print("=== B. p_solvent closed form vs brute force ===")
    for est, om in ((0.15, 0.1), (0.05, 0.2), (0.17, 0.9), (0.03, 0.5), (0.95, 0.3), (0.2, 0.3)):
        a, b = NB.p_solvent(n, est, om), p_brute(n, est, om)
        check(f"est {est}, omega {om}: {a:.5f} vs {b:.5f}", abs(a - b) < 1e-4)
    check("monotone in est", np.all(np.diff([NB.p_solvent(n, e, 0.2) for e in np.linspace(0, 0.4, 81)]) >= 0))

    print("=== C. the strict rule at depth D ===")
    kmax = math.ceil(n.depth / n.R_s) - 1
    check("kmax = 909 at D 1000, R 1.1 (K < D/R)", kmax == 909 and kmax < n.depth / n.R_s < kmax + 1)
    for p in (0.85, 0.905, 0.909, 0.92):
        direct = sum(binom.pmf(k, n.depth, p) for k in range(0, n.depth + 1) if 1.0 > n.R_s * k / n.depth)
        check(f"p {p}: P(withdraw) {NB.p_withdraw_D(n, p):.4f}", abs(NB.p_withdraw_D(n, p) - direct) < 1e-9)

    print("=== D. best_split ===")
    x = np.array([0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
    c, acc = NC.best_split(x, np.array([1, 1, 1, 0, 0, 0], bool))
    check("cutoff 0.35 between the groups, accuracy 1", abs(c - 0.35) < 1e-12 and acc == 1.0, (c, acc))

    print("=== E. F9 end to end (synthetic) ===")
    rng = np.random.default_rng(7)
    cells = ((0.5, 0.1, 0.9), (0.5, 0.3, 0.5))
    with tempfile.TemporaryDirectory() as td:
        bridge = os.path.join(td, "bridge.csv")
        subprocess.run([sys.executable, str(ROOT / "scripts" / "nest_bridge.py"), "--no-equilibria",
                        "--y", "0.2", "-o", bridge], check=True, capture_output=True)
        n2 = replace(n, y=0.2)
        for shift, want in ((0.0, "PASS"), (0.02, "FAIL")):
            arm = os.path.join(td, f"arm{shift}")
            os.makedirs(arm)
            synthetic(n2, cells, shift, 40, 150, rng).to_csv(os.path.join(arm, "consolidated_oneshot.csv"),
                                                             index=False)
            out = os.path.join(td, f"res{shift}.csv")
            subprocess.run([sys.executable, str(ROOT / "scripts" / "nest_cutoffs.py"), arm, "--y", "0.2",
                            "--bridge", bridge, "--boot", "200", "-o", out], check=True, capture_output=True)
            res = pd.read_csv(out)
            cut = res[res.test == "cutoff"]
            check(f"shift {shift}: every identified cutoff is {want} ({len(cut)} of {len(res)} rows)",
                  len(cut) >= 3 and (cut.verdict == want).all(), res[["type", "lambdaI", "verdict"]].values)

    print("=== F. (a) with the nest bank, mu = 0 ===")
    sims = Path(os.environ.get("BANKRUN_THEORY_SIMS", ROOT.parent / "bank_runs_theory" / "sims"))
    if not (sims / "ch1_eta_solver.py").exists():
        print(f"  SKIP  ch1_eta_solver.py not under {sims} (F only; set BANKRUN_THEORY_SIMS)")
    else:
        eqs = NB.solver_equilibria(n, 0.0, 0.3, 0.5, sims)
        c_b = NB.cutoffs_b(n, 0.3)[3]
        lowI = min(q["c_I"] for q in eqs) if eqs else float("nan")
        check(f"low equilibrium c_I {lowI:.4f} = (b) {c_b:.4f} within 0.002", abs(lowI - c_b) < 0.002)

    print(f"\n{_passed} PASS / {_failed} FAIL")
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
