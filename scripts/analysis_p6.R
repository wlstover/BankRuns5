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

suppressPackageStartupMessages({
    library(data.table)
    library(ggplot2)
    library(dplyr)
    library(tidyr)
})

# ── Path setup ───────────────────────────────────────────────────────────────
project_root <- Sys.getenv("BANKRUN_PROJECT_ROOT",
                          unset = normalizePath(file.path(dirname(sys.frame(1)$ofile %||% "."), "..")))
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
numeric_cols <- c("reserveRatio", "depQuantile", "warmupAlpha",
                  "mu", "lambdaI", "lambdaC")
for (c in numeric_cols) dt[[c]] <- as.numeric(dt[[c]])
dt[, bankRun := bankRun == "true"]
dt[, completed := completed == "true"]

# Sample check: print completion / failure rate summary.
cat("\n=== Completion + failure summary ===\n")
print(dt[, .(N = .N,
             completed = sum(completed),
             bankRun  = sum(bankRun),
             failRate = mean(bankRun))])

# Restrict to completed runs only for failure-rate calculations.
dt_c <- dt[completed == TRUE]
cat("\n", nrow(dt_c), "completed runs.\n", sep = "")

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
for (param in c("reserveRatio", "depQuantile", "warmupAlpha",
                "mu", "lambdaI", "lambdaC")) {
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
cat("Wrote marginal_*.png for 6 parameters.\n")

# ── 3. Summary CSV: failure rate by every (mu, lambdaI, lambdaC, reserve)  ──
cell_summary <- dt_c[, .(N = .N,
                          bankRuns = sum(bankRun),
                          failRate = mean(bankRun)),
                      by = .(reserveRatio, depQuantile, mu, lambdaI, lambdaC,
                             warmupAlpha, graphParams1 = NA, graphParams2 = NA)][
                       , .(reserveRatio, depQuantile, mu, lambdaI, lambdaC,
                           warmupAlpha, N, bankRuns, failRate)]
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
nm_check[, monotonic_increasing := sapply(failRates, function(fr) all(diff(fr) >= 0))]
nm_check[, monotonic_decreasing := sapply(failRates, function(fr) all(diff(fr) <= 0))]
nm_check[, non_monotonic := !monotonic_increasing & !monotonic_decreasing]
print(nm_check[, .(lambdaGap, reserveRatio, peak_mu, non_monotonic)])

cat("\nNon-monotonic cases (interior peak):",
    sum(nm_check$non_monotonic), "/", nrow(nm_check), "\n")
fwrite(nm_check[, .(lambdaGap, reserveRatio, peak_mu,
                    monotonic_increasing, monotonic_decreasing, non_monotonic)],
       file.path(out_dir, "p6_nonmonotonicity_check.csv"))

cat("\nDone. All outputs in:", out_dir, "\n")
