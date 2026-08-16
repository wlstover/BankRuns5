#!/usr/bin/env Rscript
#
# analysis_p6.R — Headline analysis for Chapter 3 §6.6 / dissertation slide 20.
#
# Reads outputs/consolidated_results.csv (one row per simulation run, all
# parameters + bankRun outcome flag) and produces the central P6 figure:
# bank-run probability as a function of cultural composition mu, stratified
# by the lambda gap (lambda_C - lambda_I), faceted by reserve ratio.
#
# Also produces marginal failure rates by each parameter (reserve ratio,
# deposit insurance, sigma, k, p, alpha, mu, lambdaI, lambdaC) for sanity
# checks against the directional predictions in §1.5.
#
# All outputs land in outputs/analysis/ (PNGs + summary CSVs) — small enough
# that the whole directory can be rsync'd back to local for the deck and
# Ch 3 §6 results writeup.
#
# Usage (HPC):
#     module load gnu10/10.3.0-ya
#     module load R/4.2.0-hb     # or whatever R module hopper has
#     cd /projects/tstratma/BankRuns5
#     Rscript scripts/analysis_p6.R
#
# Usage (local, for testing on rsync'd consolidated_results.csv):
#     cd ~/Projects/bank_run_dissertation/BankRuns5
#     Rscript scripts/analysis_p6.R
#
# Path resolution: uses BANKRUN_PROJECT_ROOT env var if set, otherwise
# defaults to the script's parent directory's parent (BankRuns5/).

# ⚠️ COLUMN SEMANTICS CHANGED 2026-08-13 — read before touching this file.
# consolidate_results.py used to name the parameter columns positionally, and
# the positions were wrong: what it called `reserveRatio` was the Watts-Strogatz
# rewiring probability p, and what it called `depositInsurance` was the reserve
# ratio. Every figure this script produced inherited that mislabelling — the
# "reserve null" in the chapter is a p-null (1.6 pp), while the true reserve
# axis spans 99.5% -> 46.8% failure.
#
# The consolidated CSV now carries corrected names: `reserveRatio` genuinely
# holds the reserve ratio, `p` and `k` are their own columns, `depositInsurance`
# is now `depQuantile`, and `sigma` exists. Any figure regenerated before this
# date is mislabelled at the axis level and must be redrawn, not relabelled.

# ── Package preflight ────────────────────────────────────────────────────────
# ⚠️ 2026-08-16: this stage had never executed on HPC, and the reason was not in
# this file. Hopper's `module load r` resolves to R 4.3.1 whose site library has
# **no data.table at all**, so `library(data.table)` aborted before line 1 of the
# analysis. It surfaced as a bare R error buried under Lmod module chatter in the
# .err with an empty .out — visually identical to the path-setup abort fixed on
# 2026-08-15, and to the 9-second FAILED that preceded it.
#
# Name every missing package at once and say how to install it, so this class of
# failure is legible from the .out rather than requiring the .err to be read.
#
# dplyr and tidyr used to be loaded here and are **not used anywhere in this
# file** — no pipes, no verbs; the script is data.table + ggplot2 throughout.
# They were two more chances to abort for no benefit and are dropped.
required_pkgs <- c("data.table", "ggplot2", "scales")
missing_pkgs  <- required_pkgs[
    !vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
    cat("\nERROR: missing R packages:", paste(missing_pkgs, collapse = ", "), "\n")
    cat("R:        ", R.version.string, "\n")
    cat("libPaths: ", paste(.libPaths(), collapse = "\n           "), "\n\n")
    cat("On hopper, install them once into the project library:\n")
    cat("    ./scripts/bootstrap_r_libs.sh\n\n")
    stop("missing R packages: ", paste(missing_pkgs, collapse = ", "), call. = FALSE)
}

suppressPackageStartupMessages({
    library(data.table)
    library(ggplot2)
})

# ── Path setup ───────────────────────────────────────────────────────────────
# ⚠️ This block used to be a one-liner and it never once executed. It read
#     Sys.getenv("BANKRUN_PROJECT_ROOT",
#                unset = normalizePath(file.path(dirname(sys.frame(1)$ofile %||% "."), "..")))
# which is fatal for two independent reasons, both of which abort the script
# before the first cat() — which is why the SLURM .out ends at the banner:
#   1. Sys.getenv() forces `unset` even when the variable IS set (it calls
#      as.character(unset) unconditionally), and sys.frame(1) under Rscript at
#      top level raises "not that many frames on the stack". Every R version.
#   2. `%||%` only entered base R in 4.4.0. Hopper runs R 4.3.1, so it is also
#      "could not find function" there. Masked on any local R >= 4.4.
# Derive the path without either construct.
project_root <- Sys.getenv("BANKRUN_PROJECT_ROOT", unset = "")
if (!nzchar(project_root)) {
    file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
    project_root <- if (length(file_arg) > 0) {
        normalizePath(file.path(dirname(sub("^--file=", "", file_arg[1])), ".."),
                      mustWork = FALSE)
    } else {
        getwd()
    }
}
if (!dir.exists(project_root)) {
    # Fallback: use current working directory
    project_root <- getwd()
}

# Arm-aware: run_all.sh exports BANKRUN_ARM_DIR so each arm's figures land
# beside that arm's data instead of overwriting the previous arm's. Falls back
# to outputs/ so the legacy 2026-04 sweep still resolves.
arm_dir <- Sys.getenv("BANKRUN_ARM_DIR", unset = file.path(project_root, "outputs"))

input_csv <- file.path(arm_dir, "consolidated_results.csv")
out_dir   <- file.path(arm_dir, "analysis")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

cat("project_root:", project_root, "\n")
cat("arm_dir:     ", arm_dir, "\n")
cat("input_csv:   ", input_csv, "\n")
cat("out_dir:     ", out_dir, "\n\n")

if (!file.exists(input_csv)) {
    stop("consolidated_results.csv not found at ", input_csv,
         " — run ./scripts/run_all.sh --consolidate --tag <arm> first.")
}

# ── Load + clean ─────────────────────────────────────────────────────────────
dt <- fread(input_csv)
cat("Loaded", nrow(dt), "rows.\n")

# Coerce the relevant columns. consolidate_results.py writes them as strings.
# k, p and sigma are real columns in the corrected schema and the header above
# promises marginals for them; they were omitted from both lists.
numeric_cols <- c("reserveRatio", "depQuantile", "sigma", "k", "p",
                  "warmupAlpha", "mu", "lambdaI", "lambdaC")
for (c in numeric_cols) dt[[c]] <- as.numeric(dt[[c]])
# ⚠️ NOT `bankRun == "true"`. fread type-detects a column of "true"/"false" as
# LOGICAL, so comparing it to the string "true" is TRUE for zero rows — silently,
# with no error: every failure rate comes out 0 and `completed` empties dt_c.
# Verified on the real 21-column schema: 0 of 250 matched where 247 were true.
# But consolidate_results.py:236 writes `completed` as "true"/"" and blanks the
# outcome fields of an unfinished run, so a mixed column can still arrive as
# character. Handle both, and treat NA/blank as FALSE.
as_flag <- function(x) {
    if (is.logical(x)) return(!is.na(x) & x)
    tolower(trimws(as.character(x))) %in% c("true", "t", "1")
}
dt[, bankRun := as_flag(bankRun)]
dt[, completed := as_flag(completed)]

# Sample check: print completion / failure rate summary.
cat("\n=== Completion + failure summary ===\n")
print(dt[, .(N = .N,
             completed = sum(completed),
             bankRun  = sum(bankRun),
             failRate = mean(bankRun))])

# Restrict to completed runs only for failure-rate calculations.
dt_c <- dt[completed == TRUE]
cat("\n", nrow(dt_c), " completed runs.\n", sep = "")

# Fail loudly rather than emitting an all-zero figure set. The coercion bug
# above did exactly this: every downstream aggregate stayed well-formed and
# every failure rate was 0, which is indistinguishable from a real result.
if (nrow(dt_c) == 0) {
    stop("no completed runs after coercion — ", nrow(dt), " rows read but 0 usable. ",
         "Check the `completed`/`bankRun` column types in ", input_csv)
}
if (sum(dt_c$bankRun) == 0) {
    warning("zero bankRun==TRUE among ", nrow(dt_c), " completed runs. ",
            "Possible if the arm is entirely in the survival regime; ",
            "otherwise suspect the outcome-column coercion.")
}

# Derive lambda gap.
dt_c[, lambdaGap := lambdaC - lambdaI]

# ── 1. P6 headline figure: P(run) ~ mu × (lambdaC - lambdaI), faceted ───────
agg_p6 <- dt_c[, .(failRate = mean(bankRun), N = .N),
               by = .(mu, lambdaGap, reserveRatio)]
agg_p6[, lambdaGapLabel := factor(sprintf("λ_C − λ_I = %.1f", lambdaGap),
                                  levels = sprintf("λ_C − λ_I = %.1f",
                                                   sort(unique(agg_p6$lambdaGap))))]

p_p6 <- ggplot(agg_p6, aes(x = mu, y = failRate, color = lambdaGapLabel,
                            group = lambdaGapLabel)) +
    geom_line(linewidth = 0.8) +
    geom_point(size = 1.4) +
    facet_wrap(~ paste0("Reserve ratio = ", reserveRatio), nrow = 1) +
    labs(title = "Bank-run probability by cultural composition (P6 test)",
         subtitle = "Faceted by reserve ratio; line color = λ-gap (collectivist − individualist signal weighting)",
         x = expression("Fraction individualist " * mu),
         y = "P(bank run)",
         color = NULL) +
    scale_x_continuous(breaks = c(0, 0.25, 0.5, 0.75, 1.0)) +
    scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
    theme_minimal(base_size = 11) +
    theme(legend.position = "bottom",
          panel.grid.minor = element_blank())

ggsave(file.path(out_dir, "p6_mu_lambdagap.png"),
       p_p6, width = 11, height = 5, dpi = 200)
fwrite(agg_p6, file.path(out_dir, "p6_mu_lambdagap.csv"))
cat("\nWrote p6_mu_lambdagap.png + .csv\n")

# ── 2. Marginal failure rates by each baseline parameter ────────────────────
for (param in c("reserveRatio", "depQuantile", "sigma", "k", "p",
                "warmupAlpha", "mu", "lambdaI", "lambdaC")) {
    agg <- dt_c[, .(failRate = mean(bankRun), N = .N), by = param]
    setnames(agg, param, "param_value")
    agg[, parameter := param]

    p <- ggplot(agg, aes(x = factor(param_value), y = failRate)) +
        geom_col(fill = "#2E86C1") +
        geom_text(aes(label = sprintf("%.1f%%", 100 * failRate)),
                  vjust = -0.3, size = 3) +
        labs(title = paste("Marginal failure rate by", param),
             x = param, y = "P(bank run)") +
        scale_y_continuous(labels = scales::percent_format(accuracy = 1),
                           expand = expansion(mult = c(0, 0.1))) +
        theme_minimal(base_size = 11)

    ggsave(file.path(out_dir, sprintf("marginal_%s.png", param)),
           p, width = 6, height = 4, dpi = 150)
}
cat("Wrote marginal_*.png for 9 parameters.\n")

# ── 3. Summary CSV: failure rate by every (mu, lambdaI, lambdaC, reserve)  ──
# ⚠️ `by` used to carry `graphParams1 = NA, graphParams2 = NA` — stale names from
# the pre-2026-08-13 schema, and length-1 constants, which data.table rejects
# outright ("items in the 'by' list have lengths [...] 1, 1"). The network axes
# are now their own columns, k and p, so group on the real cell definition.
cell_summary <- dt_c[, .(N = .N,
                          bankRuns = sum(bankRun),
                          failRate = mean(bankRun)),
                      by = .(reserveRatio, depQuantile, sigma, k, p,
                             warmupAlpha, mu, lambdaI, lambdaC)]
fwrite(cell_summary, file.path(out_dir, "cell_failure_rates.csv"))
cat("Wrote cell_failure_rates.csv (", nrow(cell_summary), " parameter cells)\n", sep = "")

# ── 4. Quick non-monotonicity diagnostic ────────────────────────────────────
cat("\n=== P6 NON-MONOTONICITY CHECK ===\n")
cat("For each (lambdaGap, reserveRatio) combination, identify if failRate\n")
cat("is non-monotonic in mu (i.e., interior maximum).\n\n")
nm_check <- agg_p6[order(lambdaGap, reserveRatio, mu),
                    .(failRates = list(failRate),
                      muLevels = list(mu)),
                    by = .(lambdaGap, reserveRatio)]
nm_check[, peak_mu := sapply(seq_len(.N), function(i) {
    fr <- failRates[[i]]
    mu_vals <- muLevels[[i]]
    mu_vals[which.max(fr)]
})]
# ⚠️ THIS IS A DESCRIPTIVE SUMMARY, NOT A TEST OF P6b. Retained because the
# shape of the mu curve is worth eyeballing; do not quote it as evidence.
# Two reasons, both established 2026-08-16:
#   1. A 5-value sequence is monotonic by chance only 2/120 = 1.67% of the time,
#      so `non_monotonic = TRUE` fires on 98.3% of pure noise. It carries almost
#      no information. (The 08-15 fixture's "6 of 6 non-monotonic on random
#      data" is what noise predicts at 90.4%, not a bug being caught.)
#   2. P6b predicts an interior hump ABOVE the P6a baseline, not a non-monotonic
#      curve. A real hump under a steeper P6a decline flattens the curve without
#      reversing it, and this flag reports FALSE.
# The actual test is scripts/analysis_p6b.R, which measures excess above the
# endpoint chord with paramSeed-clustered standard errors and identifies P6b
# off the treatment-vs-placebo contrast.
nm_check[, nMuLevels := sapply(muLevels, length)]
# An interior peak needs >= 3 mu levels to exist. all(diff(x) >= 0) on a
# length-1 vector is vacuously TRUE in BOTH directions, which printed as
# non_monotonic = FALSE — "untestable" masquerading as "monotonic".
nm_check[, monotonic_increasing := ifelse(nMuLevels < 3, NA,
             sapply(failRates, function(fr) all(diff(fr) >= 0)))]
nm_check[, monotonic_decreasing := ifelse(nMuLevels < 3, NA,
             sapply(failRates, function(fr) all(diff(fr) <= 0)))]
nm_check[, non_monotonic := !monotonic_increasing & !monotonic_decreasing]
print(nm_check[, .(lambdaGap, reserveRatio, nMuLevels, peak_mu, non_monotonic)])

n_untestable <- sum(nm_check$nMuLevels < 3)
if (n_untestable > 0) {
    cat("\n", n_untestable, " stratum/strata have < 3 mu levels — reported as NA",
        " (untestable), not as monotonic.\n", sep = "")
}
cat("\nNon-monotonic cases:", sum(nm_check$non_monotonic, na.rm = TRUE), "/",
    sum(!is.na(nm_check$non_monotonic)), "testable strata")
cat("  <- descriptive only; see analysis_p6b.R for the test of P6b.\n")
fwrite(nm_check[, .(lambdaGap, reserveRatio, nMuLevels, peak_mu,
                    monotonic_increasing, monotonic_decreasing, non_monotonic)],
       file.path(out_dir, "p6_nonmonotonicity_check.csv"))

cat("\nDone. All outputs in:", out_dir, "\n")
