#!/usr/bin/env python3
"""Extensive vs intensive margin of the Ch 2 (Celsius) end-balance effects (2026-10-20).

Lives here, not in bank_runs_celsius, because it answers an ABM design question:
whether the binary withdraw/stay choice is enough to dock with Ch 2. Answer
(2026-10-20): yes. Among users with a positive start balance, ~89% of the
individualism withdrawal effect is near-full exit (< 5% retained), so the
ABM's counterpart statistic is the near-full-exit LPM. Two by-products:
individualists also add funds more often (net_increase, an inflow margin the
ABM lacks), and the 10,113 zero-start users carry -0.137 of the published
-0.228 (see the vault To-Do, Chapter 2).

Usage (from the BankRuns5 root):
    python3 scripts/celsius_margin_decomposition.py [DTA] [all|positive_start] [EXIT_RET]
DTA defaults to ../bank_runs_celsius/data/user_level_collapsed_total.dta;
EXIT_RET (e.g. 0.05) also counts retention below it as full exit (default:
only end balance < $1).

Replicates 01_end_balance.do SPEC 1 (no interactions):
  ln(end+1) ~ ln(start+1) + biblical_name + individualism + female | origin FE, cluster origin
then splits the cultural coefficients exactly: with ln(start+1) as a regressor, the
coefficient on X for ln(end+1) equals the one for d = ln(end+1) - ln(start+1), and
d = sum_k 1[cat_k] * d, so regressing each 1[cat_k]*d on the same regressors gives
coefficients that sum to the total.
"""
import sys
import numpy as np
import pandas as pd

from pathlib import Path
DEFAULT_DTA = Path(__file__).resolve().parents[2] / "bank_runs_celsius" / "data" / "user_level_collapsed_total.dta"
path = sys.argv[1] if len(sys.argv) > 1 else str(DEFAULT_DTA)
cols = ["username", "balance_start", "balance_end", "individualism", "biblical_name",
        "name_gender_female", "probable_origin"]
df = pd.read_stata(path, columns=cols, convert_categoricals=False)
print("rows", len(df), "unique users", df.username.nunique())
df = df.dropna(subset=["individualism", "biblical_name", "name_gender_female", "balance_start", "balance_end"])
df["balance_end"] = df["balance_end"].clip(lower=0)
df["probable_origin"] = df["probable_origin"].fillna("UNKNOWN").replace("", "UNKNOWN")
if len(sys.argv) > 2 and sys.argv[2] == "positive_start":
    df = df[df.balance_start > 0].copy()
EXIT_RET = float(sys.argv[3]) if len(sys.argv) > 3 else None
print("estimation N", len(df))

s, e = df.balance_start.to_numpy(float), df.balance_end.to_numpy(float)
df["lstart"], df["lend"] = np.log1p(s), np.log1p(e)
d = df.lend - df.lstart

# Categories (prices constant within user, so changes are quantities)
ret = np.where(s > 0, e / np.where(s > 0, s, 1), np.nan)
cat = np.select(
    [s <= 0,
     (e < 1.0) | ((ret < EXIT_RET) if EXIT_RET else False),   # full exit: under $1 left (or retention < EXIT_RET)
     ret < 0.99,                    # partial withdrawal
     ret <= 1.01],                  # no material change
    ["zero_start", "full_exit", "partial", "unchanged"], default="net_increase")
df["cat"] = cat
print(df.cat.value_counts().to_string())

X = df[["lstart", "biblical_name", "individualism", "name_gender_female"]].astype(float)
g = df.probable_origin.astype(str)

def demean(a):
    return a - a.groupby(g).transform("mean")

Xd = demean(X).to_numpy()
XtX_inv = np.linalg.inv(Xd.T @ Xd)
codes = pd.factorize(g)[0]
G = codes.max() + 1
n, k = Xd.shape

def ols(y):
    yd = demean(pd.Series(np.asarray(y, float), index=df.index)).to_numpy()
    b = XtX_inv @ Xd.T @ yd
    u = yd - Xd @ b
    sc = np.zeros((G, k))
    np.add.at(sc, codes, Xd * u[:, None])
    V = XtX_inv @ (sc.T @ sc) @ XtX_inv * (G / (G - 1)) * ((n - 1) / (n - k - G))
    return b, np.sqrt(np.diag(V))

names = list(X.columns)
rows = []
def rep(label, y):
    b, se = ols(y)
    rows.append((label, *[f"{b[i]:+.4f} ({se[i]:.4f})" for i in (2, 1, 3)]))
    return b

total = rep("ln(end+1)  [SPEC 1, total]", df.lend)
parts = {}
for c in ["full_exit", "partial", "unchanged", "net_increase", "zero_start"]:
    parts[c] = rep(f"  part: {c}", (df.cat == c) * d)
print("sum of parts (individualism):", round(sum(p[2] for p in parts.values()), 5), "total:", round(total[2], 5))
for c in ["full_exit", "partial", "net_increase"]:
    rep(f"LPM 1[{c}]", (df.cat == c).astype(float))
rep("LPM 1[any reduction]", df.cat.isin(["full_exit", "partial"]).astype(float))
part = df.cat == "partial"
sub = df[part]
print("\npartial withdrawers:", part.sum(), " median retention", round(float(np.median(ret[part.to_numpy()])), 3))

w = max(len(r[0]) for r in rows)
print("\n" + "outcome".ljust(w), "individualism".rjust(20), "biblical".rjust(20), "female".rjust(20))
for r in rows:
    print(r[0].ljust(w), *[x.rjust(20) for x in r[1:]])
