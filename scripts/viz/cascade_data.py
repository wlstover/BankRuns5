"""cascade_data.py — readers for per-run BankRuns5 cascade output.

Everything downstream of this file is plotting. This file is the part that can
be silently wrong, so it is deliberately paranoid and it reports what it drops.

WHY THE PARANOIA: THE FILES ARE TORN
------------------------------------
`bankRunEndogenous*.csv` is appended by 15 worker processes with no
coordination, so lines interleave and tear. Measured on real output
(outputs/test_run/bankRunEndogenous1.csv, 2026-08-17):

    fields   rows      what
    8        428,563   real records
    0          3,656   blank
    1          3,652   truncated
    2             63   truncated

1.7% malformed. A reader that lets pandas pad short rows with NaN and carries
on would silently plot a picture of a torn file. This one filters on the exact
field count, counts what it dropped, prints it every time, and refuses outright
above a threshold.

⚠️ If bankRunResults*.csv tears the same way, a torn result line reads as a
missing run — which is the "finished one run short, 249/250" signature seen on
five production cells on 2026-08-17. Worth checking directly; see
check_torn_rows() below, which works on any of these files.

TWO KEY SCHEMAS
---------------
Production keys are integers (parameterGen.jl). Older arms use descriptive
strings, e.g. `test_mu0.25_lI0.1_lC0.9_r11`. The key is treated as OPAQUE
throughout — never parsed for parameters, because a key that encodes mu is
exactly the kind of thing that drifts out of sync with the manifest. Read
parameters from the manifest or the params dump instead.

N IS NOT 1000
-------------
Agent count is derived per key from agents*.csv, never hardcoded.

⚠️ THE KEY DOES NOT ALWAYS IDENTIFY A RUN
-----------------------------------------
Production keys are `<timestamp>-<seed1>-<seed2>` (parameterGen.jl:128) with
seed2 sampled WITHOUT replacement per row (line 127), so they are unique per
run. Good.

But outputs/test_run/ was written by test_run.jl, which builds its own key
(`test_mu0.25_lI0.1_lC0.9_r1`) and REUSES it across seed combinations. There,
one key covers six runs of 200 agents: 1,200 agent rows with idx 1..200
repeated six times, and the SAME idx carries a different type, deposit and
lambda in each. Naively treating that as one run of 1,200 agents would silently
average six cascades and mis-attribute agent types.

So load_run REFUSES a pooled key. Splitting was attempted and abandoned: run
boundaries recovered from idx resets (agents), tick resets (endogenous) and
vault rises (exogenous) give 6, 2 and 3 blocks respectively for the same key.
They disagree, so a decision cannot be attributed to a run, and a guess would
produce a plausible picture of the wrong thing.
"""

from __future__ import annotations

import csv
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

# ── Column contracts, from inspection of real output ────────────────────────
AGENT_COLS = ["key", "idx", "deposit", "individualism", "warmupLambda", "agentType"]
DECISION_COLS = ["key", "idx", "withdrew", "deposit", "tick", "vault",
                 "wdProb", "stayProb"]

# ⚠️ The exogenous file has SIX columns, not eight — no wdProb/stayProb.
# That is correct rather than a defect: exogenous withdrawals are the seeded
# shock, forced rather than decided, so there is no Monte Carlo comparison to
# record. Discovered 2026-08-17 when the strict reader rejected 100% of the
# file, which is precisely the outcome a padding reader would have hidden.
EXOGENOUS_COLS = ["key", "idx", "withdrew", "deposit", "tick", "vault"]

# Above this fraction of malformed rows, refuse rather than plot.
MALFORMED_ABORT_FRACTION = 0.05

TRUE_TOKENS = {"true", "t", "1", "yes"}


class CascadeDataError(RuntimeError):
    """Raised when the data cannot be trusted, as opposed to merely being messy."""


# ── Low-level: field-count-exact CSV reading ────────────────────────────────

def _read_exact(path: Path, cols: list[str], label: str,
                verbose: bool = True) -> tuple[pd.DataFrame, dict]:
    """Read a headerless CSV keeping ONLY rows with exactly len(cols) fields.

    Returns (frame, stats). Deliberately does not use pandas' own parser: a
    short row must be *dropped*, not padded with NaN, and we want an exact
    count of what went missing rather than a warning we might not read.
    """
    n_want = len(cols)
    rows, counts = [], {}
    with open(path, newline="") as fh:
        for rec in csv.reader(fh):
            counts[len(rec)] = counts.get(len(rec), 0) + 1
            if len(rec) == n_want:
                rows.append(rec)

    total = sum(counts.values())
    kept = len(rows)
    dropped = total - kept
    frac = (dropped / total) if total else 0.0

    if verbose:
        print(f"  {label}: {kept:,} of {total:,} rows kept", end="")
        if dropped:
            other = ", ".join(f"{k} fields x{v:,}"
                              for k, v in sorted(counts.items()) if k != n_want)
            print(f"  — DROPPED {dropped:,} malformed ({100*frac:.2f}%): {other}")
        else:
            print("  — no malformed rows")

    if frac > MALFORMED_ABORT_FRACTION:
        raise CascadeDataError(
            f"{path}: {100*frac:.1f}% of rows are malformed, above the "
            f"{100*MALFORMED_ABORT_FRACTION:.0f}% limit. These files are appended "
            f"by 15 workers with no coordination and this one looks badly torn. "
            f"Plotting it would produce a picture of the corruption, not of the "
            f"model. Investigate before using this arm."
        )
    if kept == 0:
        raise CascadeDataError(f"{path}: no well-formed rows at all.")

    return pd.DataFrame(rows, columns=cols), {
        "total": total, "kept": kept, "dropped": dropped, "fraction": frac,
        "field_counts": counts,
    }


def _to_bool(s: pd.Series) -> pd.Series:
    return s.astype(str).str.strip().str.lower().isin(TRUE_TOKENS)


def _numeric(df: pd.DataFrame, cols: list[str], label: str,
             verbose: bool = True) -> pd.DataFrame:
    """Coerce to numeric and drop rows that fail. A row can carry the right
    field count and still be garbage if two partial lines happened to merge."""
    before = len(df)
    for c in cols:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=cols)
    lost = before - len(df)
    if lost and verbose:
        print(f"  {label}: dropped a further {lost:,} rows with "
              f"non-numeric values in {', '.join(cols)}")
    return df


# ── Public: torn-row audit, usable on ANY of these files ────────────────────

def check_torn_rows(path: Path, expected_fields: int) -> dict:
    """Field-count histogram for one file. Use on bankRunResults*.csv to test
    whether the 249/250 shortfall is torn writes rather than lost runs."""
    counts = {}
    with open(path, newline="") as fh:
        for rec in csv.reader(fh):
            counts[len(rec)] = counts.get(len(rec), 0) + 1
    total = sum(counts.values())
    good = counts.get(expected_fields, 0)
    return {"path": str(path), "total": total, "wellformed": good,
            "malformed": total - good,
            "fraction": (total - good) / total if total else 0.0,
            "field_counts": dict(sorted(counts.items()))}


# ── Loaders ─────────────────────────────────────────────────────────────────

def _glob_one_or_more(task_dir: Path, pattern: str) -> list[Path]:
    hits = sorted(task_dir.glob(pattern))
    if not hits:
        raise CascadeDataError(f"{task_dir}: no files matching {pattern}")
    return hits


def load_agents(task_dir: Path, verbose: bool = True) -> pd.DataFrame:
    frames = []
    for p in _glob_one_or_more(task_dir, "agents*.csv"):
        df, _ = _read_exact(p, AGENT_COLS, p.name, verbose)
        frames.append(df)
    df = pd.concat(frames, ignore_index=True)
    df = _numeric(df, ["idx", "deposit", "individualism", "warmupLambda"],
                  "agents", verbose)
    df["idx"] = df["idx"].astype(int)
    df["agentType"] = df["agentType"].astype(str).str.strip()
    return df


def load_decisions(task_dir: Path, verbose: bool = True) -> pd.DataFrame:
    """Endogenous decisions plus the tick-0 exogenous shock, in one frame.

    `source` distinguishes them: the exogenous rows are the seeded shock that
    starts the cascade, not agent decisions, and view 3 needs them separately
    as the origin set for the distance calculation.
    """
    frames = []
    for pattern, source, cols in (("bankRunEndogenous*.csv", "endogenous", DECISION_COLS),
                                  ("bankRunExogenous*.csv", "exogenous", EXOGENOUS_COLS)):
        try:
            paths = _glob_one_or_more(task_dir, pattern)
        except CascadeDataError:
            if source == "endogenous":
                raise
            if verbose:
                print(f"  (no {pattern} — cascade origin unavailable)")
            continue
        for p in paths:
            df, _ = _read_exact(p, cols, p.name, verbose)
            df["source"] = source
            for missing in set(DECISION_COLS) - set(cols):
                df[missing] = np.nan      # exogenous rows have no MC probabilities
            frames.append(df[DECISION_COLS + ["source"]])

    df = pd.concat(frames, ignore_index=True)
    df["withdrew"] = _to_bool(df["withdrew"])
    # wdProb/stayProb are legitimately absent on exogenous rows, so they are
    # coerced but must NOT gate the row drop, or the entire shock is discarded.
    for c in ("wdProb", "stayProb"):
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = _numeric(df, ["idx", "deposit", "tick", "vault"], "decisions", verbose)
    df["idx"] = df["idx"].astype(int)
    df["tick"] = df["tick"].astype(int)
    return df


# ── One run, assembled ──────────────────────────────────────────────────────

@dataclass
class CascadeRun:
    key: str
    agents: pd.DataFrame        # idx, deposit, individualism, warmupLambda, agentType
    decisions: pd.DataFrame     # idx, withdrew, tick, vault, wdProb, stayProb, source
    n_agents: int
    mu_observed: float          # realised individualist share, from agentType
    ticks: list[int]

    @property
    def single_type(self) -> bool:
        """mu = 0 or mu = 1: the I-vs-C views are vacuous and must say so."""
        return self.agents["agentType"].nunique() < 2

    @property
    def origin_idx(self) -> list[int]:
        """Agents withdrawn by the exogenous shock — the cascade's origin set."""
        ex = self.decisions[(self.decisions["source"] == "exogenous")
                            & self.decisions["withdrew"]]
        return sorted(ex["idx"].unique().tolist())

    def withdrawals(self) -> pd.DataFrame:
        """One row per agent that ever withdrew, at the tick they did so."""
        w = self.decisions[self.decisions["withdrew"]]
        first = w.groupby("idx", as_index=False)["tick"].min()
        return first.merge(self.agents[["idx", "agentType", "deposit"]],
                           on="idx", how="left")


def list_keys(task_dir: Path, verbose: bool = False) -> pd.DataFrame:
    """Summarise the runs available in a task directory, so the CLI can pick a
    sensible default and warn about single-type keys."""
    agents = load_agents(task_dir, verbose=verbose)
    g = agents.groupby("key")
    out = pd.DataFrame({
        "n_agents": g.size(),
        "n_types": g["agentType"].nunique(),
        "mu_observed": g["agentType"].apply(lambda s: (s == "I").mean()),
    }).reset_index()
    return out.sort_values("key").reset_index(drop=True)


def _blocks(series: pd.Series, reset_on_rise: bool = False) -> pd.Series:
    """Block id for a column that restarts at each new run.

    Two rules, because the files carry different monotone signals:
      * idx (agents) and tick (endogenous) INCREASE within a run, so a run
        boundary is where the value falls  -> reset_on_rise=False
      * vault (exogenous) DECREASES within a run as the shock drains it, and
        every exogenous row is tick 0, so the boundary is where it rises
        -> reset_on_rise=True
    """
    prev = series.shift(1)
    hit = (series > prev) if reset_on_rise else (series < prev)
    return hit.fillna(False).cumsum()


def load_run(task_dir: Path, key: str | None = None,
             verbose: bool = True) -> CascadeRun:
    task_dir = Path(task_dir)
    agents = load_agents(task_dir, verbose)
    decisions = load_decisions(task_dir, verbose)

    keys = sorted(set(agents["key"].unique()) & set(decisions["key"].unique()),
                  key=str)
    if not keys:
        raise CascadeDataError(
            f"{task_dir}: no key appears in BOTH agents and decision files. "
            f"agents has {agents['key'].nunique()}, decisions has "
            f"{decisions['key'].nunique()}.")

    if key is None:
        # Prefer a mixed-type key: single-type runs cannot show the mechanism.
        mixed = [k for k in keys
                 if agents.loc[agents["key"] == k, "agentType"].nunique() > 1]
        key = mixed[0] if mixed else keys[0]
        if verbose:
            print(f"  key not given; using {key!r}"
                  + ("" if mixed else "  ⚠️ (no mixed-type key available)"))
    key = str(key)
    if key not in {str(k) for k in keys}:
        raise CascadeDataError(
            f"key {key!r} not found. {len(keys)} available, e.g. "
            f"{[str(k) for k in keys[:3]]}")

    a = agents[agents["key"].astype(str) == key].copy().reset_index(drop=True)
    d = decisions[decisions["key"].astype(str) == key].copy().reset_index(drop=True)

    # ── Is this key actually one run? ───────────────────────────────────────
    if a["idx"].duplicated().any():
        n_unique = a["idx"].nunique()
        n_runs = len(a) // n_unique if n_unique else 0
        raise CascadeDataError(
            f"key {key!r} is NOT one run: {len(a):,} agent rows covering only "
            f"{n_unique} distinct agents — roughly {n_runs} runs pooled under a "
            f"single key.\n\n"
            f"This is test_run.jl-shaped output. It builds a descriptive key "
            f"(test_mu0.25_lI0.1_lC0.9_r1) and reuses it across seed "
            f"combinations, so the SAME idx carries a different type, deposit "
            f"and lambda in each run. Pooling would average several cascades and "
            f"mis-attribute agent types.\n\n"
            f"It cannot be split: run boundaries were checked against idx resets "
            f"(agents), tick resets (endogenous) and vault rises (exogenous), and "
            f"the three disagree, so a decision cannot be attributed to a run. "
            f"Guessing here would produce a plausible picture of the wrong thing.\n\n"
            f"Production output does not have this problem — parameterGen.jl:127-128 "
            f"keys each run <timestamp>-<seed1>-<seed2> with seed2 sampled without "
            f"replacement. Use a production task dir, or the fixtures in "
            f"test/test_cascade_reader.py."
        )

    mu_obs = float((a["agentType"] == "I").mean())

    if verbose:
        print(f"  run {key!r}: N={len(a)}, mu_observed={mu_obs:.3f}, "
              f"{len(d):,} decisions over ticks "
              f"{d['tick'].min()}-{d['tick'].max()}")

    return CascadeRun(
        key=key, agents=a, decisions=d, n_agents=len(a),
        mu_observed=mu_obs,
        ticks=sorted(d["tick"].unique().tolist()),
    )


def load_network(edges_csv: Path) -> "networkx.Graph":  # noqa: F821
    """Edge list produced by scripts/dump_network.jl.

    ⚠️ This is a REGENERATION of the model's network, not a record of it. It is
    exact only if the Julia RNG stream matches the sweep's (same Julia version,
    same pinned Manifest, same genSeed). Verified deterministic and structurally
    correct; NOT verified byte-identical to what the sweep used, which would
    need the model to emit an edge hash per task. Say so in captions.
    """
    import networkx as nx
    df = pd.read_csv(edges_csv)
    missing = {"src", "dst"} - set(df.columns)
    if missing:
        raise CascadeDataError(f"{edges_csv}: missing columns {missing}")
    g = nx.Graph()
    g.add_edges_from(df[["src", "dst"]].itertuples(index=False, name=None))
    return g


if __name__ == "__main__":  # tiny CLI for the torn-row audit
    if len(sys.argv) < 3:
        print("usage: cascade_data.py <file.csv> <expected_fields>")
        raise SystemExit(2)
    st = check_torn_rows(Path(sys.argv[1]), int(sys.argv[2]))
    print(f"{st['path']}\n  total {st['total']:,}  wellformed {st['wellformed']:,}"
          f"  malformed {st['malformed']:,} ({100*st['fraction']:.2f}%)")
    for k, v in st["field_counts"].items():
        print(f"    {k:>3} fields  {v:,}")
