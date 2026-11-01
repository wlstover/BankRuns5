#!/usr/bin/env python3
"""F8: Chapter 1's predictions for the rung 2 nest (docs/rung2_nest.md), cell by cell.

Two solver numbers per cell and type (Walter, 2026-10-31):

  (a) Chapter 1's equilibrium cutoffs: bank_runs_theory/sims/ch1_eta_solver.py
      (equilibria), with its linear A*(theta) (assumption A1) replaced by the nest
      bank's own A*(theta), eta = SHOCK_COUNT / N and L = 0.
  (b) the cutoff of a Chapter 1 agent holding the ABM's belief law: the head-count
      of other withdrawers drawn from the prior (the shock's own distribution,
      truncated Geometric(0.1) on 0..1000), independent of theta, and theta from the
      ABM's window U[est +- w] truncated to [0, 1] (functions4.jl thetaBelief).
      (b_inf) the noise-free cutoff, P(solvent | est) = 1/R;
      (b_D)   the ABM's own rule at Monte Carlo depth D: withdraw iff fewer than D/R
              of D draws are solvent (strict tie-break, P_WD = 1 under
              LIQUIDITY=unlimited), so P(withdraw | x) = P(Bin(D, p(x)) < D/R).
              Its cutoff is where that probability is 1/2; the curve is written too.

Agreement of the ABM's empirical cutoffs (F9, scripts/nest_cutoffs.py) with (b) is the
identity test of the mechanics; (a) - (b) is the belief law's gap (level-k vs
equilibrium). (b) does not depend on mu: the belief law ignores what others do.

The nest bank (decided 2026-10-31), per unit of deposits: cash r, long asset
l = 1 - r + e, fire-sale discount d, stayers promised R_s, long return
R(theta) = R_lo + (R_hi - R_lo) theta. Under LIQUIDITY=unlimited, with A withdrawn at
par (A >= r), the period-2 margin is S(A) = (l - (A - r)/(1 - d)) R(theta) - R_s (1 - A),
linear in A, so A*(theta) solves S = 0 (fails iff A > A*).

Run:    python3 scripts/nest_bridge.py [--theory-sims PATH] [-o outputs/analysis/nest_bridge.csv]
"""

import argparse
import csv
import itertools
import math
import os
import sys
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
from scipy.stats import binom

ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Nest:
    # bank (docs/rung2_nest.md 3a)
    r: float = 0.01
    e: float = 0.06
    d: float = 0.10
    R_s: float = 1.1
    R_lo: float = 1.0
    R_hi: float = 1.4
    # population and signals (the grid fixed 2026-10-31)
    N: int = 1000
    shock: int = 10
    y: float = 0.5               # the stale public level; the grid runs 0.5 and 0.2 (one arm each)
    eps_x: float = 0.10
    eps_y: float = 0.10
    depth: int = 1000
    geom_p: float = 0.1          # parameterGen.jl exogenousProb: truncated(Geometric(0.1), 0, 1000)
    geom_hi: int = 1000


def a_star(n: Nest, theta):
    """Largest withdrawn share the nest bank survives at theta (A >= r)."""
    R = n.R_lo + (n.R_hi - n.R_lo) * np.asarray(theta, dtype=float)
    ell = 1.0 - n.r + n.e
    return (ell * R - n.R_s + n.r * R / (1.0 - n.d)) / (R / (1.0 - n.d) - n.R_s)


def prior_withdrawn(n: Nest):
    """Withdrawn share in one sub-simulation draw and its probability: the shock plus
    max(0, g - shock) others, g ~ the prior, at most N - 1 others (the focal agent stays)."""
    g = np.arange(0, n.geom_hi + 1)
    pg = n.geom_p * (1.0 - n.geom_p) ** g
    pg /= pg.sum()
    m = np.minimum(np.maximum(g, n.shock), n.N - 1)
    return m / n.N, pg


def theta_needed(n: Nest, A):
    """Smallest theta at which the bank survives withdrawn share A (A*(theta) = A,
    A*(theta) increasing): R(theta) = R_s (1 - A) / (l + (r - A)/(1 - d)); inf if the
    long position left after paying A is not positive (no theta saves it)."""
    left = (1.0 - n.r + n.e) + (n.r - np.asarray(A, dtype=float)) / (1.0 - n.d)
    with np.errstate(divide="ignore", invalid="ignore"):
        R = np.where(left > 0.0, n.R_s * (1.0 - A) / left, np.inf)
    return (R - n.R_lo) / (n.R_hi - n.R_lo)


def p_solvent(n: Nest, est: float, omega: float):
    """P(solvent) for an agent with blended estimate est and weight omega: exact, the
    prior's head-count and theta ~ U[est +- w] truncated to [0, 1] (thetaBelief)."""
    w = (1.0 - omega) * n.eps_x + omega * n.eps_y
    lo, hi = max(est - w, 0.0), min(est + w, 1.0)
    A, pg = prior_withdrawn(n)
    need = theta_needed(n, A)
    if hi <= lo:                                     # window outside [0, 1]: a point mass at the edge
        edge = 0.0 if est + w <= 0.0 else 1.0
        return float(((edge >= need) * pg).sum())
    return float((np.clip((hi - need) / (hi - lo), 0.0, 1.0) * pg).sum())


def p_withdraw_D(n: Nest, p: float):
    """The ABM's strict rule at depth D: withdraw iff 1 > R_s K / D, K ~ Bin(D, p)."""
    kmax = math.ceil(n.depth / n.R_s) - 1            # largest K with K < D / R_s
    return float(binom.cdf(kmax, n.depth, p))


def bisect(f, lo, hi, tol=1e-7):
    """Root of an increasing f on [lo, hi] (f(lo) < 0 < f(hi))."""
    flo, fhi = f(lo), f(hi)
    if not (flo < 0.0 < fhi):
        return float("nan")
    while hi - lo > tol:
        mid = 0.5 * (lo + hi)
        if f(mid) < 0.0:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def x_of(n: Nest, est, omega):
    return (est - omega * n.y) / (1.0 - omega)


def cutoffs_b(n: Nest, omega: float):
    """(b_inf, b_D) cutoffs in est and in x."""
    lo, hi = -0.5, 1.5
    t_inf = bisect(lambda t: p_solvent(n, t, omega) - 1.0 / n.R_s, lo, hi)
    t_D = bisect(lambda t: 0.5 - p_withdraw_D(n, p_solvent(n, t, omega)), lo, hi)
    return t_inf, x_of(n, t_inf, omega), t_D, x_of(n, t_D, omega)


def solver_equilibria(n: Nest, mu, om_I, om_C, sims: Path):
    """(a): Chapter 1's threshold equilibria with the nest bank's A*(theta)."""
    sys.path.insert(0, str(sims))
    import ch1_eta_solver as S                        # noqa: E402
    S.A_star = lambda p, theta: np.minimum(a_star(n, theta), 1.0)
    p = S.Params(eta=n.shock / n.N, mu=mu, omega_I=om_I, omega_C=om_C, y=n.y,
                 eps_x=n.eps_x, eps_y=n.eps_y, R=n.R_s, L=0.0)
    out = []
    for tI, tC in S.equilibria(p):
        out.append(dict(t_I=tI, t_C=tC, c_I=S.cutoff(p, "I", tI), c_C=S.cutoff(p, "C", tC),
                        threshold_I=S.best_response_is_threshold(p, "I", tI, tC),
                        threshold_C=S.best_response_is_threshold(p, "C", tI, tC),
                        plateau=S.plateau(p, tI, tC)))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--theory-sims", default=os.environ.get(
        "BANKRUN_THEORY_SIMS", str(ROOT.parent / "bank_runs_theory" / "sims")))
    ap.add_argument("-o", "--out", default=str(ROOT / "outputs" / "analysis" / "nest_bridge.csv"))
    ap.add_argument("--curve", default=None, help="also write the (b_D) P(withdraw | x) curves here")
    ap.add_argument("--no-equilibria", action="store_true", help="(b) only (fast)")
    ap.add_argument("--y", type=float, nargs="+", default=[0.5, 0.2], help="stale public levels")
    args = ap.parse_args()
    sims = Path(args.theory_sims)
    if not args.no_equilibria and not (sims / "ch1_eta_solver.py").exists():
        sys.exit(f"ch1_eta_solver.py not found under {sims} (set --theory-sims or BANKRUN_THEORY_SIMS)")

    mus = (0.0, 0.25, 0.5, 0.75, 1.0)
    pairs = ((0.1, 0.9), (0.2, 0.8), (0.3, 0.5))     # (lambda_I, lambda_C), the reference grid
    print(f"nest bank: A*(0.1/0.2/0.3/0.5/0.7/0.9) = "
          + "/".join(f"{a:.3f}" for a in a_star(Nest(), [0.1, 0.2, 0.3, 0.5, 0.7, 0.9])))
    rows = []
    for yv in args.y:
      n = replace(Nest(), y=yv)
      b = {om: cutoffs_b(n, om) for om in sorted({o for pr in pairs for o in pr})}
      for (lI, lC), mu in itertools.product(pairs, mus):
        eqs = [] if args.no_equilibria else solver_equilibria(n, mu, lI, lC, sims)
        for J, om in (("I", lI), ("C", lC)):
            t_inf, c_inf, t_D, c_D = b[om]
            base = dict(y=yv, mu=mu, lambdaI=lI, lambdaC=lC, type=J, omega=om,
                        t_b_inf=t_inf, c_b_inf=c_inf, t_b_D=t_D, c_b_D=c_D, n_eq=len(eqs))
            if not eqs:
                rows.append(base | dict(eq=-1, t_a=float("nan"), c_a=float("nan")))
            for k, q in enumerate(eqs):
                rows.append(base | dict(eq=k, t_a=q[f"t_{J}"], c_a=q[f"c_{J}"],
                                        threshold=q[f"threshold_{J}"],
                                        plateau_who=(q["plateau"] or {}).get("who_runs", ""),
                                        plateau_survives=(q["plateau"] or {}).get("bank_survives", "")))
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    cols = list(dict.fromkeys(k for r in rows for k in r))
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    print(f"{'y':>4} {'lamI/lamC':>9} {'mu':>5} {'type':>4} {'c_b_inf':>8} {'c_b_D':>8} {'n_eq':>4}  c_a (each equilibrium)")
    for yv, (lI, lC), mu in itertools.product(args.y, pairs, mus):
        for J in ("I", "C"):
            rr = [r for r in rows if r["y"] == yv and r["mu"] == mu and r["lambdaI"] == lI and r["type"] == J]
            ca = " ".join(f"{r['c_a']:.4f}" for r in rr if r["eq"] >= 0)
            print(f"{yv:4.1f} {lI:.1f}/{lC:.1f}  {mu:5.2f} {J:>4} {rr[0]['c_b_inf']:8.4f} {rr[0]['c_b_D']:8.4f} "
                  f"{rr[0]['n_eq']:4d}  {ca}")
    if args.curve:
        with open(args.curve, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["y", "omega", "x", "est", "p_solvent", "p_withdraw_D"])
            for yv in args.y:
                n = replace(Nest(), y=yv)
                for om in sorted({o for pr in pairs for o in pr}):
                    t_D = cutoffs_b(n, om)[2]
                    for est in np.linspace(t_D - 0.03, t_D + 0.03, 121):
                        ps = p_solvent(n, est, om)
                        w.writerow([yv, om, x_of(n, est, om), est, ps, p_withdraw_D(n, ps)])
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
