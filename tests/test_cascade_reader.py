#!/usr/bin/env python3
"""test_cascade_reader.py — ground-truth fixtures for the cascade viz module.

Production-shaped synthetic output with KNOWN answers, in the style of
tests/test_p6b_continuous.R. Each fixture exercises a way the reader could be
silently wrong.

  A  clean production-shaped run       -> loads, N and mu correct
  B  torn rows (0/1/2 fields)          -> dropped AND counted, not padded
  C  catastrophically torn (>5%)       -> REFUSES rather than plotting garbage
  D  pooled key (test_run.jl shape)    -> REFUSES; cannot attribute a decision
  E  exogenous 6-col vs endogenous 8   -> both parse, shock is not discarded
  F  single-type run (mu = 0)          -> type views refuse with a clear reason
  G  end to end                        -> all four views render from a fixture

Fixture C is the important one. The endogenous files really are torn — 1.7% of
rows in outputs/test_run/bankRunEndogenous1.csv have 0, 1 or 2 fields instead of
8, because 15 workers append with no coordination. A reader that lets pandas pad
short rows with NaN would draw a picture of the corruption and nothing would
look wrong.

Usage:  python3 tests/test_cascade_reader.py
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from viz import cascade_data as cd        # noqa: E402
from viz import cascade_views as cv       # noqa: E402

PASS = FAIL = 0


def ok(cond, msg):
    global PASS, FAIL
    if cond:
        PASS += 1; print(f"  PASS   {msg}")
    else:
        FAIL += 1; print(f"  FAIL   {msg}")


def prod_key(seed1, seed2):
    """Production key shape: parameterGen.jl:128."""
    return f"2026-08-17T09:00:00.000-{seed1}-{seed2}"


def make_task_dir(root: Path, *, n=120, mu=0.25, n_ticks=5, n_runs=2,
                  torn=0, pooled=False, seed=7, graph=None) -> Path:
    """Write a production-shaped task directory.

    Cascade construction is deliberate, not random: individualists withdraw
    EARLIER (P2), so the timeline view has a known right answer, and later
    withdrawals are drawn from progressively larger idx so distance-from-origin
    grows with tick when the graph is a ring-like small world.
    """
    rng = np.random.default_rng(seed)
    root.mkdir(parents=True, exist_ok=True)
    agents_rows, endo_rows, exo_rows = [], [], []

    n_indiv = int(round(mu * n))
    types = np.array(["I"] * n_indiv + ["C"] * (n - n_indiv))
    rng.shuffle(types)

    for r in range(n_runs):
        key = "pooled_key" if pooled else prod_key(1000 + r, 5000 + r)
        deposits = rng.lognormal(0.0, 1.2, n)
        for i in range(n):
            agents_rows.append(
                f"{key},{i+1},{deposits[i]:.6f},{rng.random():.6f},"
                f"{rng.random():.3f},{types[i]}")

        vault = float(deposits.sum() * 0.25)
        origin = rng.choice(np.arange(1, 9), size=4, replace=False)
        for a in origin:                                  # tick 0, SIX columns
            vault -= deposits[a - 1]
            exo_rows.append(f"{key},{a},true,{deposits[a-1]:.6f},0,{vault:.6f}")

        fallen = set(int(a) for a in origin)
        for t in range(1, n_ticks + 1):
            # Individualists move first: their hazard peaks early, C peaks late.
            for i in range(1, n + 1):
                if i in fallen:
                    continue
                ty = types[i - 1]
                pr = (0.45 if t <= 2 else 0.06) if ty == "I" else \
                     (0.03 if t <= 2 else 0.30)
                if graph is not None:
                    # SPATIAL variant: withdrawal requires a fallen neighbour, so
                    # the cascade can only advance one hop per tick and distance
                    # from the shock must grow with tick.
                    nbrs = set(graph.neighbors(i)) if i in graph else set()
                    pr = 0.75 if (nbrs & fallen) else 0.0
                wd = rng.random() < pr
                if wd:
                    fallen.add(i); vault -= deposits[i - 1]
                endo_rows.append(
                    f"{key},{i},{str(wd).lower()},{deposits[i-1]:.6f},{t},"
                    f"{vault:.6f},{rng.random():.3f},{rng.random():.3f}")

    def tear(rows, frac):
        """Interleaved-append corruption: blank, 1-field and 2-field lines."""
        if not frac:
            return rows
        out = list(rows)
        k = int(len(out) * frac)
        for pos in rng.choice(len(out), size=k, replace=False):
            style = rng.integers(0, 3)
            out[pos] = "" if style == 0 else \
                       out[pos].split(",")[0] if style == 1 else \
                       ",".join(out[pos].split(",")[:2])
        return out

    (root / "agents1.csv").write_text("\n".join(agents_rows) + "\n")
    (root / "bankRunEndogenous1.csv").write_text("\n".join(tear(endo_rows, torn)) + "\n")
    (root / "bankRunExogenous1.csv").write_text("\n".join(exo_rows) + "\n")
    return root


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="cascade_fix_"))
    try:
        # ═══ A. clean production-shaped run ═══════════════════════════════
        print("\n=== Fixture A: clean production-shaped run ===")
        d = make_task_dir(tmp / "A", n=120, mu=0.25, n_runs=2)
        run = cd.load_run(d, verbose=False)
        ok(run.n_agents == 120, f"N derived from data = {run.n_agents} (not hardcoded)")
        ok(abs(run.mu_observed - 0.25) < 1e-9, f"mu_observed = {run.mu_observed}")
        ok(not run.single_type, "run has both types")
        ok(len(run.origin_idx) == 4, f"origin set recovered ({len(run.origin_idx)} agents)")
        keys = cd.list_keys(d)
        ok(len(keys) == 2, f"both runs visible as separate keys ({len(keys)})")

        # ═══ B. torn rows dropped AND counted ═════════════════════════════
        print("\n=== Fixture B: torn rows (2%) ===")
        d = make_task_dir(tmp / "B", n=120, torn=0.02)
        st = cd.check_torn_rows(d / "bankRunEndogenous1.csv", 8)
        ok(st["malformed"] > 0, f"audit sees {st['malformed']} malformed rows")
        run = cd.load_run(d, verbose=False)
        ok(run.n_agents == 120, "still loads with torn rows present")
        bad_ticks = set(run.decisions["tick"]) - set(range(0, 99))
        ok(not bad_ticks, "no garbage ticks leaked through as NaN-padded rows")

        # ═══ C. catastrophic tearing must REFUSE ═════════════════════════
        print("\n=== Fixture C: 30% torn ===")
        d = make_task_dir(tmp / "C", n=120, torn=0.30)
        try:
            cd.load_run(d, verbose=False)
            ok(False, "should have refused a 30%-torn file")
        except cd.CascadeDataError as e:
            ok("malformed" in str(e), "REFUSES rather than plotting corruption")

        # ═══ D. pooled key must REFUSE ═══════════════════════════════════
        print("\n=== Fixture D: pooled key (test_run.jl shape) ===")
        d = make_task_dir(tmp / "D", n=120, n_runs=3, pooled=True)
        try:
            cd.load_run(d, verbose=False)
            ok(False, "should have refused a pooled key")
        except cd.CascadeDataError as e:
            ok("NOT one run" in str(e), "REFUSES: key does not identify a run")
            ok("seed2" in str(e), "error points at the production key shape")

        # ═══ E. 6-col exogenous vs 8-col endogenous ══════════════════════
        print("\n=== Fixture E: mixed column counts across files ===")
        d = make_task_dir(tmp / "E", n=120)
        dec = cd.load_decisions(d, verbose=False)
        n_exo = int((dec["source"] == "exogenous").sum())
        ok(n_exo == 8, f"exogenous rows survive the 8-column contract ({n_exo})")
        ok(dec.loc[dec["source"] == "exogenous", "wdProb"].isna().all(),
           "exogenous rows carry NaN probabilities, not fabricated ones")
        ok(dec.loc[dec["source"] == "endogenous", "wdProb"].notna().all(),
           "endogenous probabilities preserved")

        # ═══ F. single-type run ══════════════════════════════════════════
        print("\n=== Fixture F: single-type run (mu = 0) ===")
        d = make_task_dir(tmp / "F", n=120, mu=0.0)
        run = cd.load_run(d, verbose=False)
        ok(run.single_type, "single_type detected")
        try:
            cv.timeline_by_type(run)
            ok(False, "type view should refuse a single-type run")
        except ValueError as e:
            ok("both agent types" in str(e), "type view refuses with a clear reason")

        # ═══ G. end to end: all four views render ════════════════════════
        print("\n=== Fixture G: all four views render ===")
        import matplotlib.pyplot as plt
        import networkx as nx
        d = make_task_dir(tmp / "G", n=200, mu=0.3, n_ticks=6)
        run = cd.load_run(d, verbose=False)
        g = nx.newman_watts_strogatz_graph(200, 6, 0.05, seed=3)
        g = nx.relabel_nodes(g, {i: i + 1 for i in g.nodes})
        out = tmp / "G" / "viz"; out.mkdir(exist_ok=True)

        fig, ax = plt.subplots(); cv.timeline_by_type(run, ax)
        fig.savefig(out / "timeline.png", dpi=90); plt.close(fig)
        ok((out / "timeline.png").exists(), "timeline renders")

        fig, ax = plt.subplots(); cv.vault_depletion(run, ax, reserve_ratio=0.25)
        fig.savefig(out / "vault.png", dpi=90); plt.close(fig)
        ok((out / "vault.png").exists(), "vault renders")

        fig, ax = plt.subplots(); _, summary = cv.propagation_distance(run, g, ax)
        fig.savefig(out / "distance.png", dpi=90); plt.close(fig)
        ok((out / "distance.png").exists(), "distance renders")
        ok({"tick", "median_distance", "spearman_rho"} <= set(summary.columns),
           "distance returns a numeric summary, not just a picture")

        fig = cv.network_frames(run, g, ticks=run.ticks[:4])
        fig.savefig(out / "network.png", dpi=90); plt.close(fig)
        ok((out / "network.png").exists(), "network snapshots render")

        gif = cv.animate_cascade(run, g, out / "cascade.gif", fps=2, dpi=70)
        ok(Path(gif).exists() and Path(gif).stat().st_size > 0, "animation writes")

        # The fixture builds I-before-C by construction; the view must show it.
        w = run.withdrawals()
        med_i = w.loc[w.agentType == "I", "tick"].median()
        med_c = w.loc[w.agentType == "C", "tick"].median()
        ok(med_i < med_c,
           f"P2 recovered from the fixture: median tick I={med_i} < C={med_c}")

        # ═══ H. the distance diagnostic must discriminate, both ways ═════
        # G's cascade is an i.i.d. hazard with no network term, so it IS
        # mean-field and the diagnostic must say so. Without a positive control
        # that is not a test — a broken diagnostic that always says
        # "mean-field" would pass. So build a genuinely spatial cascade and
        # require the opposite verdict from the same code.
        print("\n=== Fixture H: distance diagnostic, two-sided ===")
        _, summ_flat = cv.propagation_distance(run, g, plt.subplots()[1])
        plt.close("all")
        ok(not bool(summ_flat["spatial"].iloc[0]),
           f"non-spatial cascade -> reports mean-field "
           f"(rho={summ_flat['spearman_rho'].iloc[0]:+.3f})")

        g2 = nx.newman_watts_strogatz_graph(200, 4, 0.02, seed=11)
        g2 = nx.relabel_nodes(g2, {i: i + 1 for i in g2.nodes})
        d_sp = make_task_dir(tmp / "H", n=200, mu=0.3, n_ticks=8, n_runs=1,
                             graph=g2, seed=5)
        run_sp = cd.load_run(d_sp, verbose=False)
        _, summ_sp = cv.propagation_distance(run_sp, g2, plt.subplots()[1])
        plt.close("all")
        ok(bool(summ_sp["spatial"].iloc[0]),
           f"neighbour-driven cascade -> reports spatial "
           f"(rho={summ_sp['spearman_rho'].iloc[0]:+.3f})")
        # NB: not monotonic. A neighbour-driven cascade saturates the near
        # shell and then picks up stragglers, so an intermediate median can dip.
        # The defensible claim is that the front MOVES OUT overall, which is
        # what the Spearman statistic tests and what this checks end to end.
        # ═══ I. the SURVEY: many runs, and untestable != mean-field ══════
        # 2026-08-19: task_1147 returned rho = +0.606 and task_817 returned NaN,
        # one run each. The NaN was a run whose cascade finished in a single
        # endogenous tick, so tick was constant — UNTESTABLE, not mean-field.
        # If a survey folded those in as zeros it would drag the distribution
        # toward mean-field and manufacture the conclusion under test. Both
        # directions are pinned here, plus the all-untestable cell.
        print("\n=== Fixture I: propagation survey over many runs ===")
        import subprocess, sys as _sys
        VIZ = str(Path(__file__).resolve().parent.parent / "scripts" / "viz_cascade.py")

        def edges_csv(g, path):
            with open(path, "w") as fh:
                fh.write("src,dst\n")
                for u, v in g.edges:
                    fh.write(f"{u},{v}\n")
            return str(path)

        def run_survey(task_dir, g):
            e = edges_csv(g, Path(task_dir).parent / f"{Path(task_dir).name}_edges.csv")
            r = subprocess.run([_sys.executable, VIZ, "--task-dir", str(task_dir),
                                "--network", e, "--survey"],
                               capture_output=True, text=True)
            return r.returncode, " ".join((r.stdout + r.stderr).split())

        d_many = make_task_dir(tmp / "I_spatial", n=200, mu=0.3, n_ticks=8,
                               n_runs=6, graph=g2, seed=17)
        rc, out = run_survey(d_many, g2)
        ok(rc == 0, f"survey exits 0 on a spatial cell (rc={rc})")
        ok("SPATIAL" in out and "MEAN-FIELD" not in out,
           "survey verdict on a neighbour-driven cell is SPATIAL")
        ok("testable runs : 6 / 6" in out, "survey counts every run as testable")

        # every cascade finishes in one endogenous tick -> nothing to correlate
        # n_ticks=1 leaves a single endogenous tick after tick 0 is dropped as
        # the origin — exactly what task_817 hit on 2026-08-19.
        d_one = make_task_dir(tmp / "I_onetick", n=200, mu=0.3, n_ticks=1,
                              n_runs=4, graph=g2, seed=23)
        rc1, out1 = run_survey(d_one, g2)
        ok("UNTESTABLE runs : 4" in out1 and "testable runs : 0 / 4" in out1,
           "single-tick cascades are counted UNTESTABLE, not scored as zero")
        ok("cascade finished in one endogenous tick" in out1,
           "survey names why they are untestable")
        ok("run '20" not in out1,
           "reason labels are not split on the timestamp's colons")
        ok(rc1 != 0, f"an unanswerable cell exits non-zero (rc={rc1})")
        ok("MEAN-FIELD" not in out1,
           "an all-untestable cell does NOT return a mean-field verdict")

        first = summ_sp["median_distance"].iloc[0]
        last = summ_sp["median_distance"].iloc[-1]
        ok(last > first,
           f"spatial front moves outward: median distance {first} -> {last}")

    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n" + "=" * 60)
    print(f"{PASS} PASS / {FAIL} FAIL")
    print("=" * 60)
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
