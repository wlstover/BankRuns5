#!/usr/bin/env python3
"""Fixture tests for consolidate_results.py's checks (2026-10-21).

Each case builds a one-task synthetic arm in a temp dir (manifest, 16-column
init dump, fin ledger, results / vault / types / dock files and, where the
settings call for it, the per-run switch files functions4.jl writes) and runs
the consolidator as run_all.sh does.

  a  clean arm: exit 0, nothing dropped, 0 mismatches, rows and drainShare right
  b  a torn 3-field bankRunResults row is dropped and counted; that run has no outcome
  c  a short who-runs row and an unknown-key dock row are counted
  d  switch file disagrees with the manifest (private noise 2 vs 5): exit 1, named
  e  manifest says private_signal=shock, no bankRunPrivateParams: exit 1
  f  manifest at defaults, bankRunPrivateParams present (a stale-shell leak): exit 1
  g  no manifest and a 16-column dump: refused
  h  a manifest that predates the switch columns: no switch check, exit 0
  i  fire-sale arm: bankRunBalanceParams matches, balance rows gathered, exit 0
  j  bankRunBalanceParams disagrees with the manifest (d 0.5 vs 0.25): exit 1
  k  manifest says firesale, no bankRunBalanceParams: exit 1
  l  bankRunEpisodes rows of three generations in one file (before nJoined, before
     learnedMean/Sd, current): all kept, padded with 0 and NaN (late 2026-10-30)

Run:  python3 tests/test_consolidate.py
"""

import csv
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONSOLIDATE = os.path.join(ROOT, "consolidate_results.py")

_passed = _failed = 0


def check(name, cond, detail=""):
    global _passed, _failed
    if cond:
        _passed += 1
        print(f"  ok    {name}")
    else:
        _failed += 1
        print(f"  FAIL  {name}  {detail}")


MANIFEST_COLS = ["task_id", "reserve", "depq", "sigma", "k", "p", "alpha", "mu", "lambdaI",
                 "lambdaC", "arm_tag", "assign_rule", "mc_depth", "seed_offset", "params_sha",
                 "submitted_at"]
SWITCH_COLS = ["public_alpha", "public_bias", "public_rho", "weight_phi", "fix_double_count",
               "fresh_clone", "tiebreak", "belief", "belief_p0", "log", "git_commit",
               "public_mode", "public_refresh", "private_signal", "private_noise", "stay_return",
               "payoff", "balance", "fire_discount", "equity", "fundamental", "return_lo",
               "return_hi", "theta_noise"]
KEYS = ["T-111-1", "T-111-2"]


def write_rows(path, rows):
    with open(path, "w", newline="") as fh:
        csv.writer(fh).writerows(rows)


def build(d, switches=None, with_switch_cols=True, manifest=True, extra=None):
    """One task (task_1) with two runs. switches: manifest switch values (raw strings)."""
    t = os.path.join(d, "task_1")
    os.makedirs(t)
    sw = {"fix_double_count": "true", "fresh_clone": "true", "log": "summary",
          "git_commit": "abc1234"}
    sw.update(switches or {})
    if manifest:
        cols = MANIFEST_COLS + (SWITCH_COLS if with_switch_cols else [])
        row = {"task_id": 1, "reserve": "0.30", "depq": "0.0", "sigma": "2.0", "k": 6,
               "p": "0.05", "alpha": "0.1", "mu": "0.5", "lambdaI": "0.1", "lambdaC": "0.9",
               "arm_tag": "fixture", "assign_rule": "warmup", "mc_depth": 100,
               "seed_offset": 1000, "params_sha": "x", "submitted_at": "now"}
        if with_switch_cols:
            row.update({c: sw.get(c, "") for c in SWITCH_COLS})
        with open(os.path.join(d, "manifest.csv"), "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=cols)
            w.writeheader()
            w.writerow(row)
    # 16-column init dump: seed1, iteration, k, p, r, q, alpha, mu, lI, lC, seed2,
    # key, lognMu, lognSigma, assignRule, mcDepth
    write_rows(os.path.join(t, "bankRunParametersInit.csv"),
               [[111, 1, 6, 0.05, 0.3, 0.0, 0.1, 0.5, 0.1, 0.9, s, k, 0.0, 2.0, "warmup", 100]
                for s, k in zip((1, 2), KEYS)])
    write_rows(os.path.join(t, "bankRunParametersFin.csv"), [[k, 1, "true"] for k in KEYS])
    results = [[KEYS[0], "true", 17, 123.5], [KEYS[1], "false", 3, 9.0]]
    vault = [[KEYS[0], 100.0, -5.0, 0.0], [KEYS[1], 100.0, 80.0, 0.0]]
    types = [[k, ty] + [1] * 16 for k in KEYS for ty in ("I", "C")]
    dock = [[k, 2, 0.1, 0.3, 0.2, "NaN", "NaN", 3] for k in KEYS]
    x = extra or {}
    results = x.get("results", lambda r: r)(results)
    types = x.get("types", lambda r: r)(types)
    dock = x.get("dock", lambda r: r)(dock)
    write_rows(os.path.join(t, "bankRunResults1.csv"), results)
    write_rows(os.path.join(t, "bankRunVault1.csv"), vault)
    write_rows(os.path.join(t, "bankRunTypes1.csv"), types)
    write_rows(os.path.join(t, "bankRunDock1.csv"), dock)
    # PublicParams: written whenever fix_double_count is on (the default)
    if x.get("public_params", True):
        write_rows(os.path.join(t, "bankRunPublicParams1.csv"),
                   [[k, 0.0, 0.0, 1.0, 1.0, "true", "true"] for k in KEYS])
    if "private" in x:
        write_rows(os.path.join(t, "bankRunPrivateParams1.csv"),
                   [[k] + x["private"] + [2] for k in KEYS])
    if "episodes" in x:
        write_rows(os.path.join(t, "bankRunEpisodes1.csv"), x["episodes"])
    if "balance_params" in x:
        write_rows(os.path.join(t, "bankRunBalanceParams1.csv"),
                   [[k] + x["balance_params"] for k in KEYS])
        write_rows(os.path.join(t, "bankRunBalance1.csv"),
                   [[k, 0.4, 1.06, 30.0, 270.0, -1.0, 0.0, 0.0, 250.0, "false", "liquidity",
                     0.02, 0.05, "true"] for k in KEYS])
    return t


def run(d, manifest=True):
    cmd = [sys.executable, CONSOLIDATE, "--arm-dir", d, "--out",
           os.path.join(d, "consolidated_results.csv"), "--no-analyze"]
    cmd += ["--manifest", os.path.join(d, "manifest.csv")] if manifest else []
    p = subprocess.run(cmd, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def count(out, label):
    m = re.search(re.escape(label) + r"\s+(\d+)(?:\s*/\s*(\d+))?", out)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2))) if m.group(2) else int(m.group(1))


def results_rows(d):
    with open(os.path.join(d, "consolidated_results.csv"), newline="") as fh:
        return {r["key"]: r for r in csv.DictReader(fh)}


BASE = tempfile.TemporaryDirectory(prefix="consolidate_test_")


def case(label, **kw):
    d = os.path.join(BASE.name, label)
    os.makedirs(d)
    build(d, **{k: v for k, v in kw.items() if k != "run_manifest"})
    rc, out = run(d, manifest=kw.get("run_manifest", True))
    return d, rc, out


def main():
    print("a  clean arm")
    d, rc, out = case("a")
    rows = results_rows(d)
    check("exit 0", rc == 0, out[-400:])
    check("torn 0", count(out, "Torn bankRunResults rows dropped:") == 0)
    check("types dropped 0/0", count(out, "who-runs rows dropped (width/key):") == (0, 0))
    check("dock dropped 0/0", count(out, "dock rows dropped (width/key):") == (0, 0))
    check("0 mismatches", count(out, "Switch-file mismatches:") == 0)
    check("2 rows, outcomes", len(rows) == 2 and rows[KEYS[0]]["bankRun"] == "true"
          and rows[KEYS[0]]["nWithdrawn"] == "17" and rows[KEYS[1]]["bankRun"] == "false")
    check("drainShare 1.0 / 0.2", abs(float(rows[KEYS[0]]["drainShare"]) - 1.0) < 1e-12
          and abs(float(rows[KEYS[1]]["drainShare"]) - 0.2) < 1e-12)

    print("b  torn results row")
    d, rc, out = case("b", extra={"results": lambda r: [r[0], [KEYS[1], "true", 17]]})
    rows = results_rows(d)
    check("exit 0", rc == 0)
    check("torn 1", count(out, "Torn bankRunResults rows dropped:") == 1)
    check("torn run has no outcome", rows[KEYS[1]]["bankRun"] == "" and rows[KEYS[1]]["nWithdrawn"] == "")
    check("no outcome counted", count(out, "Init keys with no outcome record:") == 1)

    print("c  short who-runs row, unknown-key dock row")
    d, rc, out = case("c", extra={
        "types": lambda r: r[:-1] + [[KEYS[1], "C", 1, 2, 3]],
        "dock": lambda r: r + [["NOT-A-KEY", 2, 0.1, 0.3, 0.2, "NaN", "NaN", 3]]})
    check("types dropped 1/0", count(out, "who-runs rows dropped (width/key):") == (1, 0), out[-600:])
    check("dock dropped 0/1", count(out, "dock rows dropped (width/key):") == (0, 1))
    check("still exit 0", rc == 0)

    print("d  switch value disagrees with the manifest")
    d, rc, out = case("d", switches={"private_signal": "shock", "private_noise": "5"},
                      extra={"private": ["shock", 2.0]})
    check("exit 1", rc == 1, out[-400:])
    check("1 mismatch", count(out, "Switch-file mismatches:") == 1)
    check("names the field", "private_noise = '2.0'" in out)
    check("outputs still written", len(results_rows(d)) == 2)

    print("e  manifest implies a file that is missing")
    d, rc, out = case("e", switches={"private_signal": "shock", "private_noise": "5"})
    check("exit 1", rc == 1)
    check("names the file", "no bankRunPrivateParams*.csv" in out, out[-400:])

    print("f  file present though the manifest is at defaults (stale-shell leak)")
    d, rc, out = case("f", extra={"private": ["shock", 5.0]})
    check("exit 1", rc == 1)
    check("names the file", "bankRunPrivateParams*.csv present" in out, out[-400:])
    check("and the value", "private_signal = 'shock'" in out)

    print("g  no manifest, 16-column dump")
    d, rc, out = case("g", manifest=False, run_manifest=False)
    check("refused (exit 1)", rc == 1)
    check("says to pass --manifest", "pass --manifest" in out, out[-400:])

    print("h  manifest without switch columns")
    d, rc, out = case("h", with_switch_cols=False, extra={"private": ["shock", 2.0]})
    check("exit 0", rc == 0, out[-400:])
    check("0 mismatches", count(out, "Switch-file mismatches:") == 0)

    FIRE_SW = {"payoff": "recovery", "balance": "firesale"}
    FIRE_ROW = ["recovery", "firesale", 0.25, 0.1, "none", 0.9, 1.3, 0.1]

    print("i  fire-sale arm")
    d, rc, out = case("i", switches=FIRE_SW, extra={"balance_params": FIRE_ROW})
    check("exit 0", rc == 0, out[-400:])
    check("0 mismatches", count(out, "Switch-file mismatches:") == 0)
    check("balance rows 2", count(out, "balance rows:") == 2, out[-600:])
    check("balance dropped 0/0", count(out, "balance rows dropped (width/key):") == (0, 0))

    print("j  balance params disagree with the manifest")
    d, rc, out = case("j", switches=FIRE_SW, extra={"balance_params": FIRE_ROW[:2] + [0.5] + FIRE_ROW[3:]})
    check("exit 1", rc == 1, out[-400:])
    check("names the field", "fire_discount = '0.5'" in out, out[-400:])

    print("k  manifest says firesale, no balance params")
    d, rc, out = case("k", switches=FIRE_SW)
    check("exit 1", rc == 1)
    check("names the file", "no bankRunBalanceParams*.csv" in out, out[-400:])

    print("l  episode rows of three generations")
    # key type + episode seed2 theta failed n nExog nEndog depTotal depEndog lambdaMean
    # lambdaSd weightMean weightSd msexMean mseyMean | nJoined | learnedMean learnedSd
    core = [1, 2, 0.4, "false", 50, 1, 2, 100.0, 3.0, 0.1, 0.06, 0.2, 0.05, "NaN", "NaN"]
    eps = [[KEYS[0], "I"] + core,                                  # before nJoined
           [KEYS[0], "C"] + core + [4],                            # before learnedMean/Sd
           [KEYS[1], "I"] + core + [5, 0.3, 0.07]]                 # current
    d, rc, out = case("l", extra={"episodes": eps})
    check("exit 0", rc == 0, out[-400:])
    check("episodes rows 3", count(out, "episodes rows:") == 3, out[-800:])
    check("episodes dropped 0/0", count(out, "episodes rows dropped (width/key):") == (0, 0))
    with open(os.path.join(d, "consolidated_episodes.csv"), newline="") as fh:
        er = {(r["key"], r["type"]): r for r in csv.DictReader(fh)}
    check("old row: nJoined 0, learned NaN",
          er[(KEYS[0], "I")]["nJoined"] == "0" and er[(KEYS[0], "I")]["learnedMean"] == "NaN"
          and er[(KEYS[0], "I")]["learnedSd"] == "NaN")
    check("10-30 row: nJoined kept, learned NaN",
          er[(KEYS[0], "C")]["nJoined"] == "4" and er[(KEYS[0], "C")]["learnedSd"] == "NaN")
    check("current row kept as written",
          er[(KEYS[1], "I")]["nJoined"] == "5" and er[(KEYS[1], "I")]["learnedMean"] == "0.3"
          and er[(KEYS[1], "I")]["learnedSd"] == "0.07")

    BASE.cleanup()
    print(f"\n{_passed} passed, {_failed} failed")
    return 1 if _failed else 0


if __name__ == "__main__":
    sys.exit(main())
