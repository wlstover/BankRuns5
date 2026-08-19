#!/usr/bin/env python3
"""Ground-truth fixtures for tests/check_type_clustering.py.

Two-sided, because this diagnostic can fail in the direction that looks like a
discovery. If it were stuck on "NOT CLUSTERED" it would appear to have found
that the placebo was a no-op — a dramatic result — and a one-sided test would
wave it through. So a genuinely clustered arm MUST return CLUSTERED.

  A  contiguous blocks of type I vs random placebo   -> CLUSTERED, exit 0
  B  random in both arms                             -> NOT CLUSTERED, exit 1
  C  warmupLambda differs across arms                -> internal check fires
  D  single-type runs (mu = 0 / mu = 1)              -> undefined, not zero
  E  Moran's I against a hand-computed value         -> the maths is right
  F  no --arm-b                                      -> says the null is weaker

Run:  python3 tests/test_type_clustering.py
"""

import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "check_type_clustering.py")
sys.path.insert(0, HERE)
from check_type_clustering import morans_i          # noqa: E402

N = 200          # ring size
K = 6            # each node joined to K/2 neighbours a side
RUNS = 12

_passed = _failed = 0


def check(name, cond, detail=""):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f"  PASS  {name}")
    else:
        _failed += 1
        print(f"  FAIL  {name}   {detail}")


def ring_edges(n=N, k=K):
    e = set()
    for i in range(n):
        for d in range(1, k // 2 + 1):
            e.add(tuple(sorted((i, (i + d) % n))))
    return sorted(e)


def write_network(path, edges):
    with open(path, "w") as fh:
        fh.write("src,dst\n")
        for u, v in edges:
            fh.write(f"{u+1},{v+1}\n")       # dump_network.jl is 1-indexed


def write_arm(d, *, clustered, mu=0.5, lam_seed=7, runs=RUNS, single_type=False):
    """agents*.csv for one arm. warmupLambda depends only on lam_seed, mirroring
    the real model where ASSIGN_RULE never touches the warm-up."""
    os.makedirs(d, exist_ok=True)
    n_i = 0 if (single_type and mu == 0) else (N if single_type else int(mu * N))
    with open(os.path.join(d, "agents2.csv"), "w") as fh:
        for r in range(runs):
            key = f"2026-08-18T02:57:44.{r:03d}-{1000+r}-{5000+r}"
            rng = random.Random(lam_seed * 1000 + r)
            lam = [rng.random() for _ in range(N)]
            if single_type:
                types = ["I"] * n_i + ["C"] * (N - n_i)
            elif clustered:
                # one contiguous arc of individualists -> strong positive I
                start = rng.randrange(N)
                idx = {(start + j) % N for j in range(n_i)}
                types = ["I" if i in idx else "C" for i in range(N)]
            else:
                idx = set(rng.sample(range(N), n_i))
                types = ["I" if i in idx else "C" for i in range(N)]
            for i in range(N):
                fh.write(f"{key},{i+1},100.0,0.5,{lam[i]:.6f},{types[i]}\n")
    return d


def run(a, b, net, extra=()):
    cmd = [sys.executable, SCRIPT, "--arm-a", a, "--network", net, *extra]
    if b:
        cmd += ["--arm-b", b]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, " ".join((r.stdout + r.stderr).split())


def main():
    tmp = tempfile.mkdtemp(prefix="clust_")
    edges = ring_edges()
    net = os.path.join(tmp, "net.csv")
    write_network(net, edges)
    print("test_type_clustering")

    # ── E. the maths, against a hand-computed case ────────────────────────
    # A perfectly split ring (first half I, second half C) is maximally
    # clustered: nearly every edge joins like to like, so I -> ~+1.
    half = [1.0] * (N // 2) + [0.0] * (N // 2)
    i_half, exp = morans_i(half, edges, N)
    check("E maximal clustering gives I near +1", 0.90 < i_half < 1.01,
          f"I={i_half:.4f}")
    alt = [float(i % 2) for i in range(N)]
    i_alt, _ = morans_i(alt, edges, N)
    check("E alternating gives strong NEGATIVE I", i_alt < -0.3, f"I={i_alt:.4f}")
    rng = random.Random(3)
    shuf = [1.0] * (N // 2) + [0.0] * (N // 2)
    rng.shuffle(shuf)
    i_rnd, _ = morans_i(shuf, edges, N)
    check("E random is near E[I]", abs(i_rnd - exp) < 0.12, f"I={i_rnd:.4f}")
    check("E constant input is undefined, not zero",
          morans_i([1.0] * N, edges, N)[0] is None)

    # ── A. clustered treatment vs random placebo ──────────────────────────
    print("\n=== Fixture A: warm-up clusters types, placebo randomises ===")
    a = write_arm(os.path.join(tmp, "A_t"), clustered=True)
    b = write_arm(os.path.join(tmp, "A_p"), clustered=False)
    rc, out = run(a, b, net)
    check("A exits 0", rc == 0, f"rc={rc}")
    check("A verdict CLUSTERED", "CLUSTERED." in out and "NOT CLUSTERED" not in out)
    check("A internal check passes", "identical — same warm-up" in out)
    check("A prints a correlogram", "CORRELOGRAM" in out)
    # A contiguous arc of I stays contiguous at 2 and 3 hops, so clustering must
    # persist across lags. A lag-1-only statistic could not tell that apart from
    # a checkerboard, and the subcritical cascade reaches radius 2-3.
    import re as _re
    rows = _re.findall(r" (\d) ([+-][\d.]+) *([+-][\d.]+)", out)
    lagvals = {int(l): (float(t), float(pp)) for l, t, pp in rows}
    check("A clustering persists to lag 3",
          all(lagvals.get(L, (0, 0))[0] > 0.2 for L in (1, 2, 3)),
          f"{ {k: v[0] for k, v in lagvals.items()} }")
    check("A placebo is flat at every lag",
          all(abs(lagvals.get(L, (0, 0))[1]) < 0.05 for L in (1, 2, 3)),
          f"{ {k: v[1] for k, v in lagvals.items()} }")

    # ── B. random in BOTH arms — the case that looks like a discovery ─────
    print("\n=== Fixture B: no spatial structure in either arm ===")
    a2 = write_arm(os.path.join(tmp, "B_t"), clustered=False, lam_seed=7)
    b2 = write_arm(os.path.join(tmp, "B_p"), clustered=False, lam_seed=7)
    rc2, out2 = run(a2, b2, net)
    check("B exits non-zero", rc2 != 0, f"rc={rc2}")
    check("B verdict NOT CLUSTERED", "NOT CLUSTERED" in out2)
    check("B says UNTESTED, not refuted", "UNTESTED by this design" in out2)
    check("B points at item 13", "item 13" in out2)

    # ── C. the internal check must fire when the warm-up differs ──────────
    print("\n=== Fixture C: warmupLambda differs across arms ===")
    a3 = write_arm(os.path.join(tmp, "C_t"), clustered=True, lam_seed=7)
    b3 = write_arm(os.path.join(tmp, "C_p"), clustered=False, lam_seed=99)
    rc3, out3 = run(a3, b3, net)
    check("C internal check fires", "They differ" in out3)
    check("C refuses to interpret", rc3 != 0, f"rc={rc3}")

    # ── D. single-type runs are undefined, not zero ───────────────────────
    print("\n=== Fixture D: mu = 1 runs (every agent type I) ===")
    a4 = write_arm(os.path.join(tmp, "D_t"), clustered=False, single_type=True, mu=1)
    rc4, out4 = run(a4, None, net)
    check("D counts them single-type, I undefined",
          "single-type (I undefined, NOT zero)" in out4)

    # ── F. without the placebo arm, say the null is weaker ────────────────
    print("\n=== Fixture F: no --arm-b ===")
    rc5, out5 = run(a, None, net)
    check("F flags the missing randomisation null",
          "exact randomisation null" in out5)

    print(f"\n{_passed} PASS / {_failed} FAIL")
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
