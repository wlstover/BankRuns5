# legacy/

Dead code, kept for provenance. **Nothing in the pipeline references any of these.**

Verified 2026-08-19 by grepping every `*.md`, `*.sh`, `*.py`, `*.jl`, `*.R` and `*.slurm`
in the repository: the only hits outside this directory were `REPOSITORY_REVIEW.md`'s
file-by-file documentation. If you are about to check that again, you don't have to.

| File | Superseded by / why it is here |
|---|---|
| `analysis.R` | early exploratory R over the raw sweep output |
| `analysis2.R` | ditto, with `ggExtra` marginal plots |
| `workingAnalysis.R` | ditto — vault percentages and run histories |
| `finAnalysis.R` | **a different project entirely.** Its header reads "Final Analysis Code / Anti-Trust Model / June 2024". It has never had anything to do with bank runs |
| `dataTools.jl` | four lines that `@load` a hardcoded `data.jld2` that no longer exists |
| `jld2CSV.jl` | jld2 → CSV bridge so R could read the extra columns. `consolidate_results.py` replaced this and never touches jld2 |
| `modelStep.jl` | a scratch stub: three non-comment lines calling `modelRun(mod)` on an undefined `mod` |

The three R analysis files are superseded by `scripts/analysis_p6.R` and
`scripts/analysis_p6b.R`. ⚠️ Do not mine them for numbers: they read the **pre-2026-08-13**
consolidated schema, whose column names were assigned positionally and were wrong — `k`
was labelled `agtCnt`, `p` was labelled `reserveRatio`, `r` was labelled `depositInsurance`
and `q` was labelled `exogProb`. That mislabelling is the origin of the paper's "reserve
null". Anything these scripts printed about a reserve axis was actually about the
Newman–Watts rewiring probability. See the header of `consolidate_results.py`.

## What is NOT here, and deliberately so

Files that look legacy at a glance but are live:

- **`sysImage.jl`** (repo root) — builds `sysimage.so`, which `finMain0001.jl:11` and
  `model3_ws_homogeneous.jl:43` load opportunistically for faster worker startup. Its
  `sysimage_path` is relative, so it must be run from the repo root.
- **`model3_ws_homogeneous.jl`** (repo root) — the homogeneous-agent variant. It lacks the
  cultural machinery, but `next_steps.md` cites it as the clean `pmap` pattern to copy if
  Level-2 parallelism is ever revisited.
- **`sweep.slurm`, `pattern.sh`, `params_focused.txt`** (repo root) — the 2026-04 sweep's
  launcher, its TIMEOUT forensics, and its parameter grid. Marked deprecated but
  **load-bearing**: `next_steps.md` item 3 reconstructs the legacy manifest from
  `task_N` ↔ line N of `params_focused.txt`, which is what makes σ recoverable and
  resurrects Experiment 3 from data already paid for. **Do not delete.**
