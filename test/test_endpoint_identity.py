#!/usr/bin/env python3
"""Ground-truth fixtures for scripts/check_endpoint_identity.py.

The failure this check exists to prevent is a FALSE GREEN, so most of these
fixtures are worlds where the naive answer is "identical" and the correct answer
is "refuse". Tested two-sided throughout.

  A  correct world: endpoints bit-identical, interior differs        -> PASS
  B  an endpoint run differs                                         -> FAIL
  C  endpoint seed pair present in one arm only                      -> FAIL
  D  interior identical too (ASSIGN_RULE never reached the model)    -> FAIL
  E  params_sha differs between arms                                 -> FAIL (fatal)
  F  both arms carry the same assign_rule                            -> FAIL (fatal)
  G  a paired cell disagrees on a non-intervention parameter         -> FAIL (fatal)
  H  no endpoint cells in the manifest                               -> FAIL (fatal)
  I  self-compare (arm A against itself)                             -> FAIL (fatal)
  J  correct world, but the positive control is disabled             -> FAIL (not proven)

Run:  python3 test/test_endpoint_identity.py
"""

import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, os.pardir, "scripts", "check_endpoint_identity.py")

MANIFEST_COLS = ("task_id,reserve,depq,sigma,k,p,alpha,mu,lambdaI,lambdaC,"
                 "arm_tag,assign_rule,mc_depth,seed_offset,params_sha,submitted_at")
RUNS = 20
NWORKERS = 4

_passed = 0
_failed = 0


def check(name, cond, detail=""):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f"  PASS  {name}")
    else:
        _failed += 1
        print(f"  FAIL  {name}   {detail}")


def seeds(tid):
    rng = random.Random(1000 + tid)
    return [(rng.randint(1, 10**6), rng.randint(1, 10**6)) for _ in range(RUNS)]


def write_cell(arm, tid, mu, differ, drop_one=False):
    """differ=False -> outcomes are a deterministic function of the seeds, so the
    two arms coincide. differ=True -> the arm's own label perturbs them."""
    d = os.path.join(arm, f"task_{tid}")
    os.makedirs(d, exist_ok=True)
    files = {c: open(os.path.join(d, f"bankRunResults{c}.csv"), "w")
             for c in range(2, 2 + NWORKERS)}
    sd = seeds(tid)
    if drop_one:
        sd = sd[:-1]
    for i, (s1, s2) in enumerate(sd):
        salt = 7 if differ else 0
        n = (s1 + s2 + salt) % 641
        files[2 + (i % NWORKERS)].write(
            f"2026-08-17T14:23:45.123-{s1}-{s2},{'true' if n > 200 else 'false'},"
            f"{n},{n * 1000.5:.2f}\n")
    for f in files.values():
        f.close()
    with open(os.path.join(d, "agents2.csv"), "w") as f:
        for s1, s2 in sd:
            for j in range(1, 6):
                f.write(f"2026-08-17T14:23:45.123-{s1}-{s2},{j},"
                        f"{(s1 % 97) + j}.0,0.5,0.5,{'I' if mu == '1.0' else 'C'}\n")


def build_arm(root, name, rule, tids, sha="ef96a99c573fccc8",
              interior_differs=True, bad_param=None, drop_in=None):
    arm = os.path.join(root, name)
    os.makedirs(arm, exist_ok=True)
    lines = [MANIFEST_COLS]
    for tid, mu in tids:
        endpoint = mu in ("0.0", "1.0")
        sigma = "3.0" if (bad_param == tid) else "2.0"
        lines.append(f"{tid},0.25,0.0,{sigma},6,0.05,0.1,{mu},0.1,0.9,"
                     f"{name},{rule},100,7000,{sha},2026-08-17T10:00:00")
        write_cell(arm, tid,
                   mu,
                   differ=(not endpoint) and interior_differs and rule != "warmup",
                   drop_one=(drop_in == tid))
    with open(os.path.join(arm, "manifest.csv"), "w") as f:
        f.write("\n".join(lines) + "\n")
    return arm


def run(a, b, extra=()):
    """Returns (rc, flat) with flat whitespace-collapsed, so a phrase assertion
    does not fail merely because the script wrapped it across two lines."""
    r = subprocess.run([sys.executable, SCRIPT, "--arm-a", a, "--arm-b", b, *extra],
                       capture_output=True, text=True)
    return r.returncode, " ".join((r.stdout + r.stderr).split())


def main():
    tmp = tempfile.mkdtemp(prefix="endpoint_")
    TIDS = [(1, "0.0"), (2, "0.25"), (3, "0.5"), (4, "0.75"), (5, "1.0"),
            (6, "0.0"), (7, "0.5"), (8, "1.0")]

    print("test_endpoint_identity")

    # ---- A: the world as it should be ---------------------------------------
    root = os.path.join(tmp, "A"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "placebo", "random", TIDS)
    rc, out = run(a, b)
    check("A correct world exits 0", rc == 0, f"rc={rc}")
    check("A endpoints identical", "endpoints identical : YES" in out)
    check("A interior differs", "interior differs : YES" in out)
    check("A states the chord cancellation",
          "rate_t(mu) - rate_p(mu)" in out)
    check("A flags the quadrature SE bug", "adds in quadrature' is wrong" in out)

    # ---- B: one endpoint run differs ----------------------------------------
    root = os.path.join(tmp, "B"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "placebo", "random", TIDS)
    p = os.path.join(b, "task_1", "bankRunResults2.csv")
    ls = open(p).read().splitlines()
    f0 = ls[0].split(","); f0[2] = str(int(f0[2]) + 1); ls[0] = ",".join(f0)
    open(p, "w").write("\n".join(ls) + "\n")
    rc, out = run(a, b)
    check("B endpoint mismatch fails", rc != 0, f"rc={rc}")
    check("B endpoints reported NO", "endpoints identical : NO" in out)
    check("B prints the offending run", "seed1=" in out)

    # ---- C: an endpoint run missing from one arm ----------------------------
    root = os.path.join(tmp, "C"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "placebo", "random", TIDS, drop_in=1)
    rc, out = run(a, b)
    check("C unmatched endpoint seed fails", rc != 0, f"rc={rc}")

    # ---- D: interior identical => the intervention never fired --------------
    root = os.path.join(tmp, "D"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "placebo", "random", TIDS, interior_differs=False)
    rc, out = run(a, b)
    check("D no-op placebo fails", rc != 0, f"rc={rc}")
    check("D interior reported NO", "interior differs : NO" in out)
    check("D explains the no-op", "never reached the model" in out)

    # ---- E: different grids --------------------------------------------------
    root = os.path.join(tmp, "E"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "placebo", "random", TIDS, sha="deadbeefdeadbeef")
    rc, out = run(a, b)
    check("E params_sha mismatch is fatal", rc != 0 and "params_sha differs" in out)

    # ---- F: same rule in both arms ------------------------------------------
    root = os.path.join(tmp, "F"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "copy", "warmup", TIDS)
    rc, out = run(a, b)
    check("F identical assign_rule is fatal",
          rc != 0 and "same assign_rule" in out)

    # ---- G: paired cells disagree on a parameter ----------------------------
    root = os.path.join(tmp, "G"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "placebo", "random", TIDS, bad_param=3)
    rc, out = run(a, b)
    check("G parameter mismatch is fatal",
          rc != 0 and "disagree on a non-intervention parameter" in out)

    # ---- H: no endpoint cells ------------------------------------------------
    root = os.path.join(tmp, "H"); os.makedirs(root)
    mid = [(1, "0.25"), (2, "0.5"), (3, "0.75")]
    a = build_arm(root, "production", "warmup", mid)
    b = build_arm(root, "placebo", "random", mid)
    rc, out = run(a, b)
    check("H no endpoint cells is fatal",
          rc != 0 and "no endpoint cells found" in out)

    # ---- I: self-compare -----------------------------------------------------
    root = os.path.join(tmp, "I"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    rc, out = run(a, a)
    check("I self-compare is fatal", rc != 0 and "same directory" in out)

    # ---- J: correct world, positive control switched off --------------------
    root = os.path.join(tmp, "J"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "placebo", "random", TIDS)
    rc, out = run(a, b, extra=("--interior-cells", "0"))
    check("J no positive control does NOT pass", rc != 0, f"rc={rc}")
    check("J says why", "not yet meaningful" in out)

    # ---- agent-level check on the correct world ------------------------------
    root = os.path.join(tmp, "K"); os.makedirs(root)
    a = build_arm(root, "production", "warmup", TIDS)
    b = build_arm(root, "placebo", "random", TIDS)
    rc, out = run(a, b, extra=("--check-agents", "--agent-cells", "3"))
    check("K agent-level endpoints identical",
          rc == 0 and "endpoint agents identical: YES" in out)

    print(f"\n{_passed} PASS / {_failed} FAIL")
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
