#!/usr/bin/env Rscript
#
# analysis_p6b.R — a direct test of P6b, replacing the monotonicity flag.
#
# WHY THIS EXISTS
# ---------------
# analysis_p6.R §4 asked "is failRate non-monotonic in mu?" via
#     all(diff(failRate) >= 0)
# with no noise model. That question is wrong in both directions:
#
#   * A run of 5 values is monotonic by chance only 2/120 = 1.67% of the time,
#     so `non_monotonic = TRUE` fires on 98.3% of pure noise. The 2026-08-15
#     fixture's "6 of 6 non-monotonic on random data" is exactly what noise
#     predicts (90.4% likely), not a bug being caught.
#   * P6b does NOT predict a non-monotonic curve. It predicts a residual
#     interior hump ABOVE the P6a baseline. The channels are additive, so a
#     real P6b hump under a steeper P6a decline only flattens the curve — it
#     never reverses it, and the flag reports FALSE.
#
#   * Third, minor: all(diff(x) >= 0) on a length-1 vector is vacuously TRUE,
#     so a single-mu arm reports monotonic_increasing AND monotonic_decreasing
#     both TRUE, printed as non_monotonic = FALSE. Harmless on a smoke arm
#     (you know mu was fixed) and it does not occur in a full sweep — all 18
#     strata of the 2026-04 sweep carry all 5 mu levels — but "untestable"
#     must not print as "monotonic".
#
# WHAT THIS COMPUTES
# ------------------
# For each (lambdaGap, reserveRatio) stratum, the excess of the interior mu
# levels above the chord joining the two endpoint mu levels:
#
#     excess(mu) = failRate(mu) - [ failRate(mu_lo)
#                    + (failRate(mu_hi) - failRate(mu_lo)) * (mu - mu_lo)
#                                                          / (mu_hi - mu_lo) ]
#
# Positive excess = hump above a linear P6a baseline. Standard errors come
# from a cluster bootstrap over paramSeed, because runs sharing a paramSeed
# share the network, the warm-up, the lambda assignment and the deposit vector
# (functions4.jl:28,82,92) and differ only in the shock and cascade order. The
# independent unit is the initialisation, not the run. Ignoring this makes
# binomial-over-N standard errors roughly 3.8x too tight at the median design
# effect measured on the legacy sweep (ICC 0.274, DEFF 14.4).
#
# ⚠️ THE CHORD IS NOT A CLEAN P6a BASELINE — read this before quoting a number.
# It assumes P6a is LINEAR in mu, and paper_draft.md §6.4 reports that the P6a
# decline is "steepest in the interior and flatter at the boundaries". A
# concave P6a produces positive chord excess with no P6b hump whatsoever. So
# a positive within-arm excess is consistent with P6b but does not establish
# it, and no statistic computed on a single arm's mu curve can separate the
# two — the confound is in the baseline, not in the noise.
#
# THE IDENTIFICATION, which is why this script takes two arms
# -----------------------------------------------------------
# P6a is a COMPOSITION effect: it depends only on how many agents carry
# lambda_I rather than lambda_C. P6b is a POSITION effect: it needs
# individualists to ignite cascades that reach collectivists, which depends on
# where they sit in the network.
#
# The warm-up placebo (--assignment random) holds composition exactly fixed —
# same count of each type, same lambda distributions, same network, same
# deposits, same shock — and destroys only the correlation between cultural
# type and network position. So P6a survives it and P6b should not. The
# contrast
#
#     excess(treatment) - excess(placebo)
#
# differences out the P6a curvature confound, because P6a's shape is identical
# in both arms by construction. That contrast is the headline number; the
# within-arm excesses are diagnostics for it.
#
# The assumption behind the contrast is that random assignment leaves P6a
# untouched. It is checkable and this script checks it: at mu = 0 and mu = 1
# there is only one type present, P6b is zero by construction, and any
# between-arm gap at the endpoints is P6a contamination. Reported as
# `endpoint_contamination.csv` — read it before trusting the contrast.
#
# USAGE
#   # single arm
#   BANKRUN_ARM_DIR=outputs/production Rscript scripts/analysis_p6b.R
#
#   # treatment vs placebo — the actual test
#   BANKRUN_ARM_DIR=outputs/production \
#   BANKRUN_COMPARE_DIR=outputs/placebo \
#   Rscript scripts/analysis_p6b.R
#
#   BANKRUN_BOOT=2000    # bootstrap replicates, default 2000
#
# Requires the post-2026-08-13 consolidated schema (paramSeed, k, p,
# reserveRatio, depQuantile, sigma, mu, lambdaI, lambdaC). It refuses to run on
# the legacy positional schema rather than silently reading the wrong axes.

# ── Package preflight (see analysis_p6.R for why this is explicit) ───────────
required_pkgs <- c("data.table", "ggplot2", "scales")
missing_pkgs  <- required_pkgs[
    !vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
    cat("\nERROR: missing R packages:", paste(missing_pkgs, collapse = ", "), "\n")
    cat("R:        ", R.version.string, "\n")
    cat("libPaths: ", paste(.libPaths(), collapse = "\n           "), "\n\n")
    cat("On hopper, install them once: ./scripts/bootstrap_r_libs.sh\n\n")
    stop("missing R packages: ", paste(missing_pkgs, collapse = ", "), call. = FALSE)
}
suppressPackageStartupMessages({
    library(data.table)
    library(ggplot2)
})

set.seed(20260816)   # fixed: the bootstrap must not move between runs

# ── Paths (same derivation as analysis_p6.R; no %||%, no sys.frame) ──────────
project_root <- Sys.getenv("BANKRUN_PROJECT_ROOT", unset = "")
if (!nzchar(project_root)) {
    file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
    project_root <- if (length(file_arg) > 0) {
        normalizePath(file.path(dirname(sub("^--file=", "", file_arg[1])), ".."),
                      mustWork = FALSE)
    } else getwd()
}
if (!dir.exists(project_root)) project_root <- getwd()

arm_dir     <- Sys.getenv("BANKRUN_ARM_DIR", unset = file.path(project_root, "outputs"))
compare_dir <- Sys.getenv("BANKRUN_COMPARE_DIR", unset = "")
n_boot      <- as.integer(Sys.getenv("BANKRUN_BOOT", unset = "2000"))
out_dir     <- file.path(arm_dir, "analysis")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

cat("arm_dir:     ", arm_dir, "\n")
cat("compare_dir: ", if (nzchar(compare_dir)) compare_dir else "(none — within-arm only)", "\n")
cat("out_dir:     ", out_dir, "\n")
cat("bootstrap:   ", n_boot, "replicates, clustered on paramSeed\n\n")

# ── Load ────────────────────────────────────────────────────────────────────
as_flag <- function(x) {
    if (is.logical(x)) return(!is.na(x) & x)
    tolower(trimws(as.character(x))) %in% c("true", "t", "1")
}

# ⚠️ Checking for `reserveRatio` is NOT enough to detect the legacy schema — the
# legacy CSV HAS a column of that name, it just holds the Watts-Strogatz
# rewiring probability p instead of the reserve ratio. A fixture built from the
# real legacy file sailed through an earlier version of this check and produced
# a complete, plausible figure set off the wrong axis. Discriminate on columns
# that exist only in the corrected schema, and reject the legacy names outright.
REQUIRED_COLS <- c("paramSeed", "reserveRatio", "mu", "lambdaI", "lambdaC",
                   "completed", "bankRun",
                   "k", "p", "sigma", "depQuantile", "assignRule", "mcDepth")
LEGACY_ONLY_COLS <- c("agtCnt", "depositInsurance", "exogProb")

load_arm <- function(dir, label) {
    f <- file.path(dir, "consolidated_results.csv")
    if (!file.exists(f)) stop("no consolidated_results.csv in ", dir, call. = FALSE)
    dt <- fread(f)
    legacy <- intersect(LEGACY_ONLY_COLS, names(dt))
    if (length(legacy) > 0) {
        stop(label, ": this is the LEGACY positional schema (found ",
             paste(legacy, collapse = ", "), ").\nIts `reserveRatio` column holds ",
             "the rewiring probability p, and its `depositInsurance` column holds ",
             "the reserve ratio. Reading it here would silently produce a complete, ",
             "plausible figure set off the wrong axis. Re-consolidate with the ",
             "post-2026-08-13 consolidate_results.py first.", call. = FALSE)
    }
    absent <- setdiff(REQUIRED_COLS, names(dt))
    if (length(absent) > 0) {
        stop(label, ": consolidated CSV is missing ", paste(absent, collapse = ", "),
             ".\nThis script requires the post-2026-08-13 schema. The legacy CSV names ",
             "the parameter columns positionally AND the positions are wrong (what it ",
             "calls reserveRatio is the network rewiring probability p). Re-consolidate ",
             "before using it.", call. = FALSE)
    }
    dt[, bankRun   := as_flag(bankRun)]
    dt[, completed := as_flag(completed)]
    dt <- dt[completed == TRUE]
    if (nrow(dt) == 0) stop(label, ": no completed runs.", call. = FALSE)
    # set() not [[<- : the base assignment forces a shallow copy and data.table
    # emits a warning about it on every load, which is noise in a SLURM .out.
    for (cc in c("reserveRatio", "mu", "lambdaI", "lambdaC"))
        set(dt, j = cc, value = as.numeric(dt[[cc]]))
    dt[, lambdaGap := round(lambdaC - lambdaI, 4)]
    dt[, arm := label]
    cat(sprintf("%-10s %s rows, %d strata, %d mu levels, %d paramSeeds\n",
                label, format(nrow(dt), big.mark = ","),
                nrow(unique(dt[, .(lambdaGap, reserveRatio)])),
                uniqueN(dt$mu), uniqueN(dt$paramSeed)))
    dt
}

dt_t <- load_arm(arm_dir, "treatment")
dt_p <- if (nzchar(compare_dir)) load_arm(compare_dir, "placebo") else NULL

# ── Cluster table: one row per (stratum, mu, paramSeed) ─────────────────────
# The bootstrap resamples paramSeeds, so collapse to that grain once and then
# every replicate is a fast sum over a small table.
clusters <- function(dt) {
    dt[, .(n = .N, k = sum(bankRun)),
       by = .(lambdaGap, reserveRatio, mu, paramSeed)]
}

# ── The statistic ───────────────────────────────────────────────────────────
# excess of each interior mu above the endpoint chord, for one stratum.
excess_of <- function(mu, rate) {
    o <- order(mu); mu <- mu[o]; rate <- rate[o]
    if (length(mu) < 3) return(NULL)
    lo <- 1L; hi <- length(mu)
    chord <- rate[lo] + (rate[hi] - rate[lo]) * (mu - mu[lo]) / (mu[hi] - mu[lo])
    data.table(mu = mu[-c(lo, hi)], excess = (rate - chord)[-c(lo, hi)])
}

# Point estimates and a cluster bootstrap, per stratum.
excess_table <- function(cl, n_boot) {
    strata <- unique(cl[, .(lambdaGap, reserveRatio)])
    out <- vector("list", nrow(strata))
    for (i in seq_len(nrow(strata))) {
        g <- strata$lambdaGap[i]; r <- strata$reserveRatio[i]
        sub <- cl[lambdaGap == g & reserveRatio == r]
        mu_levels <- sort(unique(sub$mu))

        # Refuse to report rather than report vacuously. An interior peak needs
        # at least three mu levels to exist at all.
        if (length(mu_levels) < 3) {
            out[[i]] <- data.table(lambdaGap = g, reserveRatio = r, mu = NA_real_,
                                   nMuLevels = length(mu_levels), excess = NA_real_,
                                   se = NA_real_, ci_lo = NA_real_, ci_hi = NA_real_,
                                   nSeeds = uniqueN(sub$paramSeed), nRuns = sum(sub$n),
                                   testable = FALSE)
            next
        }

        point <- sub[, .(rate = sum(k) / sum(n)), by = mu]
        est   <- excess_of(point$mu, point$rate)

        # Cluster bootstrap: resample paramSeeds WITH replacement, independently
        # within each mu (a paramSeed belongs to exactly one cell, so clusters
        # are nested within (stratum, mu)).
        boot <- matrix(NA_real_, nrow = n_boot, ncol = nrow(est))
        by_mu <- split(sub, sub$mu)
        for (b in seq_len(n_boot)) {
            rates <- vapply(by_mu, function(d) {
                idx <- sample.int(nrow(d), nrow(d), replace = TRUE)
                sum(d$k[idx]) / sum(d$n[idx])
            }, numeric(1))
            e <- excess_of(as.numeric(names(by_mu)), unname(rates))
            boot[b, ] <- e$excess
        }
        out[[i]] <- data.table(
            lambdaGap = g, reserveRatio = r, mu = est$mu,
            nMuLevels = length(mu_levels), excess = est$excess,
            se    = apply(boot, 2, sd),
            ci_lo = apply(boot, 2, quantile, 0.025, names = FALSE),
            ci_hi = apply(boot, 2, quantile, 0.975, names = FALSE),
            nSeeds = uniqueN(sub$paramSeed), nRuns = sum(sub$n), testable = TRUE)
    }
    rbindlist(out)
}

cl_t <- clusters(dt_t)
cat("\nBootstrapping treatment arm...\n")
ex_t <- excess_table(cl_t, n_boot)
ex_t[, arm := "treatment"]

untestable <- ex_t[testable == FALSE]
if (nrow(untestable) > 0) {
    cat("\n⚠️", nrow(untestable), "stratum/strata have fewer than 3 mu levels — an interior\n")
    cat("   peak cannot exist there. Reported as NA (untestable), NOT as monotonic.\n")
}

res <- ex_t
if (!is.null(dt_p)) {
    cat("Bootstrapping placebo arm...\n")
    ex_p <- excess_table(clusters(dt_p), n_boot)
    ex_p[, arm := "placebo"]
    res <- rbind(ex_t, ex_p)

    # ── The headline contrast ────────────────────────────────────────────────
    # Independent arms, so the difference's SE adds in quadrature.
    d <- merge(ex_t[testable == TRUE, .(lambdaGap, reserveRatio, mu,
                                        ex_t = excess, se_t = se)],
               ex_p[testable == TRUE, .(lambdaGap, reserveRatio, mu,
                                        ex_p = excess, se_p = se)],
               by = c("lambdaGap", "reserveRatio", "mu"))
    d[, diff := ex_t - ex_p]
    d[, se   := sqrt(se_t^2 + se_p^2)]
    d[, z    := diff / se]
    setorder(d, -diff)
    fwrite(d, file.path(out_dir, "p6b_treatment_minus_placebo.csv"))

    cat("\n=== P6b: excess(treatment) - excess(placebo) ===\n")
    cat("Positive = hump present under warm-up assignment and absent when\n")
    cat("cultural type is decoupled from network position. That is P6b.\n\n")
    print(d[, .(lambdaGap, reserveRatio, mu,
                excess_treat = round(100 * ex_t, 2),
                excess_placebo = round(100 * ex_p, 2),
                diff_pp = round(100 * diff, 2),
                se_pp = round(100 * se, 2), z = round(z, 2))])
    cat(sprintf("\nPooled: mean diff %+.2f pp over %d stratum-mu points; %d of %d positive.\n",
                100 * mean(d$diff), nrow(d), sum(d$diff > 0), nrow(d)))

    # ── Assumption check: P6a must be untouched at the endpoints ─────────────
    # At mu = 0 and mu = 1 only one type is present, so P6b is zero by
    # construction. Any between-arm gap there is P6a contamination and the
    # contrast above is not clean.
    ends <- function(cl, label) {
        mus <- sort(unique(cl$mu))
        cl[mu %in% c(mus[1], mus[length(mus)]),
           .(rate = sum(k) / sum(n), nRuns = sum(n)),
           by = .(lambdaGap, reserveRatio, mu)][, arm := label][]
    }
    ec <- merge(ends(cl_t, "treatment")[, .(lambdaGap, reserveRatio, mu, rate_t = rate)],
                ends(clusters(dt_p), "placebo")[, .(lambdaGap, reserveRatio, mu, rate_p = rate)],
                by = c("lambdaGap", "reserveRatio", "mu"))
    ec[, gap_pp := 100 * (rate_t - rate_p)]
    fwrite(ec, file.path(out_dir, "endpoint_contamination.csv"))
    cat("\n=== Assumption check: P6a unchanged at the endpoints ===\n")
    cat(sprintf("mean |gap| at mu endpoints: %.2f pp   max |gap|: %.2f pp\n",
                mean(abs(ec$gap_pp)), max(abs(ec$gap_pp))))
    cat("Large gaps here mean random assignment moved P6a too, and the contrast\n")
    cat("above is not clean. See endpoint_contamination.csv.\n")
}

fwrite(res, file.path(out_dir, "p6b_excess_above_chord.csv"))

cat("\n=== Within-arm excess above the endpoint chord ===\n")
cat("⚠️ Confounded with P6a curvature — see the header. Diagnostic, not a result.\n\n")
print(res[testable == TRUE,
          .(arm, lambdaGap, reserveRatio, mu, nMuLevels,
            excess_pp = round(100 * excess, 2),
            ci = sprintf("[%+.2f, %+.2f]", 100 * ci_lo, 100 * ci_hi),
            nSeeds)][order(arm, lambdaGap, reserveRatio, mu)])

# ── Figure ──────────────────────────────────────────────────────────────────
plot_dt <- res[testable == TRUE]
if (nrow(plot_dt) > 0) {
    p <- ggplot(plot_dt, aes(x = factor(mu), y = 100 * excess,
                             ymin = 100 * ci_lo, ymax = 100 * ci_hi,
                             color = arm, group = arm)) +
        geom_hline(yintercept = 0, linewidth = 0.4, color = "grey40") +
        geom_pointrange(position = position_dodge(width = 0.4), size = 0.35) +
        facet_grid(sprintf("λ-gap %.1f", lambdaGap) ~ sprintf("r = %.2f", reserveRatio)) +
        labs(title = "P6b: excess run probability above the endpoint chord",
             subtitle = paste0("Cluster bootstrap on paramSeed (", n_boot,
                               " reps). Positive = interior hump above a linear P6a baseline."),
             x = expression("Individualist share " * mu),
             y = "Excess (percentage points)", color = NULL) +
        theme_minimal(base_size = 10) +
        theme(legend.position = "bottom", panel.grid.minor = element_blank())
    ggsave(file.path(out_dir, "p6b_excess.png"), p,
           width = 11, height = 6, dpi = 200)
    cat("\nWrote p6b_excess.png\n")
}

cat("\nDone. Outputs in:", out_dir, "\n")
