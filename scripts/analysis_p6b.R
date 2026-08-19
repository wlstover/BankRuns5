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
# ── THE OUTCOME IS CASCADE SIZE |S*|, NOT P(run). Added 2026-08-17. ──────────
# P6b is a claim about how BIG a cascade gets, and `bankRun` is that quantity
# passed through a threshold whose height is set by the reserve ratio r: the
# vault is r x total deposits, so r fixes the cluster size that counts as
# failure. A threshold indicator is maximally sensitive only when the threshold
# sits in the bulk of the distribution, so measuring P6b through `bankRun`
# makes sensitivity vary systematically with r — one of the axes being
# stratified on. At r = 0.15 nearly every cascade qualifies (~99%, flat in mu:
# a ceiling that censors P6b); at r = 0.40 only near-spanning ones do.
#
# So the primary outcome here is `nWithdrawn` — the realised withdrawal set
# size |S*|, instrumented 2026-08-13 and confirmed populated by the 2026-08-15
# smoke run. `bankRun` is retained as a SECONDARY outcome so the binary result
# stays comparable to the legacy headline.
#
# 📌 This also connects to Chapter 2. A(theta) — "the proportion of depositors
# withdrawing at period 1", chapter2.tex:571 — IS nWithdrawn/N. The 2026-08-16
# result that the heterogeneous-lambda global game admits partial runs makes
# cascade size an object of the analytics, not an ABM-only consolation.
#
# ⚠️ A TESTABLE IMPLICATION OF THE SWITCH. Under `bankRun`, r doubles as the
# measuring instrument, which is why P6b appeared only at r = 0.25-0.30 and the
# regime looked "saturated" elsewhere. Under |S*| r is no longer the
# instrument, so P6b should become detectable across the whole r range. If the
# excess stays humped at 0.25-0.30 and flat elsewhere, the threshold
# explanation was wrong and something else is going on.
#
# WHAT THIS COMPUTES
# ------------------
# For each stratum, the excess of the interior mu levels above the chord
# joining the two endpoint mu levels:
#
#     excess(mu) = y(mu) - [ y(mu_lo)
#                    + (y(mu_hi) - y(mu_lo)) * (mu - mu_lo) / (mu_hi - mu_lo) ]
#
# where y is the mean outcome. Positive excess = hump above a linear P6a
# baseline. Standard errors come from a cluster bootstrap over paramSeed,
# because runs sharing a paramSeed share the network, the warm-up, the lambda
# assignment and the deposit vector (functions4.jl:28,82,92) and differ only in
# the shock and cascade order. The independent unit is the initialisation, not
# the run. Ignoring this makes naive-over-N standard errors roughly 3.8x too
# tight at the median design effect measured on the legacy sweep (ICC 0.274,
# DEFF 14.4).
#
# Note the estimator is a ratio of sums either way — sum(k)/sum(n) for a
# proportion, sum(s)/sum(n) for a mean — so the bootstrap machinery is
# identical for both outcomes.
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
# `endpoint_contamination__*.csv` — read it before trusting the contrast.
#
# ── THE INSURANCE INTERACTION. Added 2026-08-17. ────────────────────────────
# The focused grid crosses depQuantile (0.0, 0.2, 0.5) with the lambda-gap
# (0.8, 0.6, 0.2) — a fully crossed 3x3 that has never been estimated. Since
# lambda IS the weight an agent places on the social signal, depQuantile x
# lambdaGap asks directly: does a deposit-insurance backstop reduce how much
# social-signal weighting matters? That is the reduced form of the committee's
# question about social learning and the FDIC.
#
# ⚠️ Reduced form, not structural: lambda is assigned exogenously at warm-up
# and never learned. The structural version (lambda responding to own coverage)
# is future_work.md item 1. Do not describe this as a test of learning.
#
# ⚠️ depQuantile is a QUANTILE of the deposit distribution, so it is the share
# of depositors covered BY COUNT, not by value. At sigma = 3.0, q = 0.5 insures
# only ~0.7% of deposit VALUE. The swept levels are all low-insurance regimes;
# do not read them as "half insured".
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
#   BANKRUN_BOOT=2000        # bootstrap replicates, default 2000
#   BANKRUN_NAGENTS=1000     # if set, |S*| is reported as a share of N
#   BANKRUN_SKIP_INTERACTION=1   # skip the depQuantile stratification
#
# Requires the post-2026-08-13 consolidated schema (paramSeed, k, p,
# reserveRatio, depQuantile, sigma, mu, lambdaI, lambdaC) plus nWithdrawn. It
# refuses to run on the legacy positional schema rather than silently reading
# the wrong axes.

# ── Package preflight (see analysis_p6.R for why this is explicit) ───────────
# Split deliberately. data.table is load-bearing — no numbers without it. But
# ggplot2/scales only draw an optional PNG, and on 2026-08-16 the entire
# analysis stage aborted before line 1 because a *plotting* library was absent
# from hopper's site library. Losing every number because a figure cannot be
# drawn is the wrong failure. Numbers now survive a missing plotting stack; the
# figure degrades to a warning.
if (!requireNamespace("data.table", quietly = TRUE)) {
    cat("\nERROR: missing required R package: data.table\n")
    cat("R:        ", R.version.string, "\n")
    cat("libPaths: ", paste(.libPaths(), collapse = "\n           "), "\n\n")
    cat("On hopper, install it once: ./scripts/bootstrap_r_libs.sh\n\n")
    stop("missing R package: data.table", call. = FALSE)
}
suppressPackageStartupMessages(library(data.table))

plot_pkgs    <- c("ggplot2", "scales")
missing_plot <- plot_pkgs[!vapply(plot_pkgs, requireNamespace, logical(1), quietly = TRUE)]
CAN_PLOT     <- length(missing_plot) == 0
if (CAN_PLOT) {
    suppressPackageStartupMessages(library(ggplot2))
} else {
    cat("\n⚠️  Missing plotting packages:", paste(missing_plot, collapse = ", "), "\n")
    cat("   All CSV outputs will still be written; figures will be skipped.\n")
    cat("   To get figures: ./scripts/bootstrap_r_libs.sh\n\n")
}

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
n_agents    <- suppressWarnings(as.numeric(Sys.getenv("BANKRUN_NAGENTS", unset = "")))
skip_inter  <- nzchar(Sys.getenv("BANKRUN_SKIP_INTERACTION", unset = ""))
# Hard cap on runs that were checked off but never wrote a result row (the
# 9be29d7 teardown race). Measured 2026-08-19 at 0.0098% (production) and
# 0.0139% (placebo), so 0.1% is a 7x margin: comfortably above the known defect,
# far below any rate at which the duration selection could matter. Deliberately
# NOT an env var -- a threshold you can raise from the command line is a
# threshold that gets raised at 2am and forgotten.
MAX_LOST_FRAC <- as.numeric(Sys.getenv("BANKRUN_MAX_LOST_FRAC", unset = "0.001"))
out_dir     <- file.path(arm_dir, "analysis")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

cat("arm_dir:     ", arm_dir, "\n")
cat("compare_dir: ", if (nzchar(compare_dir)) compare_dir else "(none — within-arm only)", "\n")
cat("out_dir:     ", out_dir, "\n")
cat("bootstrap:   ", n_boot, "replicates, clustered on paramSeed\n")

# ── Outcome specifications ──────────────────────────────────────────────────
# `col`   the per-run column summed into the numerator
# `scale` multiplier applied for display (100 turns a proportion into pp)
# `unit`  what a displayed number means — printed on every table
#
# ⚠️ N (agent count) is NOT in the consolidated schema: agtCnt was dropped
# deliberately because it never held what it claimed. So |S*| is reported in
# RAW AGENTS unless BANKRUN_NAGENTS is set. Do not silently divide by 1000.
cascade_scale <- 1
cascade_unit  <- "agents withdrawn"
if (!is.na(n_agents) && n_agents > 0) {
    cascade_scale <- 100 / n_agents
    cascade_unit  <- sprintf("%% of N=%g agents", n_agents)
}

OUTCOMES <- list(
    cascade = list(key = "cascade", col = "nWithdrawn", scale = cascade_scale,
                   unit = cascade_unit,
                   desc = "cascade size |S*| — the primary P6b outcome"),
    binary  = list(key = "binary",  col = "bankRunNum", scale = 100,
                   unit = "pp",
                   desc = "P(bank run) — secondary, comparable to the legacy headline")
)

# ── Stratifications ─────────────────────────────────────────────────────────
STRATA_HEADLINE    <- c("lambdaGap", "reserveRatio")
STRATA_INTERACTION <- c("lambdaGap", "reserveRatio", "depQuantile")

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
                   "completed", "bankRun", "nWithdrawn",
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
    # ⚠️ Capture "this row has no outcome at all" BEFORE as_flag() runs.
    # as_flag maps NA to FALSE, which is right for `completed` but destructive
    # for `bankRun`: a run whose result row was never written would silently
    # become bankRun = FALSE, i.e. get counted as a surviving bank. That is a
    # directional bias in the binary block, invisible in every output. Detect it
    # on the raw column, handling both the logical NA fread gives for an
    # all-blank column and the empty string it gives for a mixed one.
    raw_bankrun <- dt[["bankRun"]]
    no_result <- if (is.logical(raw_bankrun)) is.na(raw_bankrun) else
        is.na(raw_bankrun) | !nzchar(trimws(as.character(raw_bankrun)))
    dt[, noResult := no_result]

    dt[, bankRun   := as_flag(bankRun)]
    dt[, completed := as_flag(completed)]
    dt[, bankRunNum := as.numeric(bankRun)]
    dt[noResult == TRUE, bankRunNum := NA_real_]   # undo the NA -> FALSE coercion
    dt <- dt[completed == TRUE]
    if (nrow(dt) == 0) stop(label, ": no completed runs.", call. = FALSE)

    # Blank |S*| has TWO causes and they need opposite treatment. The 2026-08-19
    # run halted here reporting "53 of 540,000 ... predate the instrumentation",
    # which was the wrong diagnosis and would have cost a two-day re-run.
    #
    #   (a) NO RESULT ROW AT ALL -- bankRun, nWithdrawn and depositWithdrawn are
    #       all blank while `completed` is TRUE. consolidate_results.py takes
    #       `completed` from the master ledger bankRunParametersFin.csv and the
    #       outcome columns from bankRunResults*.csv, so this is precisely the
    #       check-off-before-write race fixed in 9be29d7: the master marked the
    #       row done, then the worker was torn down before it wrote. The run is
    #       simply UNOBSERVED. It carries no outcome for either the cascade or
    #       the binary block, so it is dropped from both -- but loudly, with the
    #       keys written out, and only below a hard cap.
    #
    #   (b) A RESULT ROW WITHOUT |S*| -- bankRun is populated, nWithdrawn is
    #       blank. That is genuinely pre-2026-08-13 data, it means depths are
    #       being mixed, and it still REFUSES outright.
    dt[, nWithdrawn := suppressWarnings(as.numeric(nWithdrawn))]

    lost <- dt$noResult & is.na(dt$nWithdrawn)
    n_lost <- sum(lost)
    if (n_lost > 0) {
        frac <- n_lost / nrow(dt)
        cat(sprintf(
            "\n%s: %s of %s completed runs (%.4f%%) have NO result row.\n",
            label, format(n_lost, big.mark = ","),
            format(nrow(dt), big.mark = ","), 100 * frac))
        cat("  Cause: the check-off-before-write race in modelCall() (fixed 9be29d7).\n")
        cat("  The master marked the row complete, then the pool was torn down\n")
        cat("  before the worker wrote its result. The run is unobserved, not\n")
        cat("  mis-measured, so it is dropped from BOTH outcome blocks.\n")
        cat("  ⚠️ NOT missing at random: the lost run is the LAST TO FINISH in its\n")
        cat("  cell, so the loss is selected on run duration. At this rate that is\n")
        cat("  immaterial, but say so in the methods rather than calling it attrition.\n")
        if (frac > MAX_LOST_FRAC) {
            stop(label, ": ", format(n_lost, big.mark = ","), " runs (",
                 sprintf("%.4f%%", 100 * frac), ") have no result row, above the ",
                 sprintf("%.2f%%", 100 * MAX_LOST_FRAC), " cap.\nAt this rate the ",
                 "duration selection is no longer negligible. Investigate with ",
                 "tests/diagnose_short_cells.py before trusting any estimate.",
                 call. = FALSE)
        }
        lost_f <- file.path(out_dir, paste0("dropped_no_result__", label, ".csv"))
        want <- intersect(c("key", "task_id", "paramSeed", "mu", "reserveRatio",
                            "lambdaI", "lambdaC"), names(dt))
        fwrite(dt[lost, ..want], lost_f)
        cat("  Keys written to ", lost_f, "\n\n", sep = "")
        dt <- dt[!lost]
    }

    n_missing <- sum(is.na(dt$nWithdrawn))
    if (n_missing > 0) {
        stop(label, ": ", format(n_missing, big.mark = ","), " of ",
             format(nrow(dt), big.mark = ","), " completed runs have a blank ",
             "`nWithdrawn` but DO carry a bankRun outcome.\nThose predate the ",
             "2026-08-13 |S*| instrumentation, so this arm mixes Monte Carlo ",
             "depths. Cascade size cannot be computed for them and dropping them ",
             "would bias the estimate toward whatever subset survived. Either ",
             "re-run the arm, or restrict to post-instrumentation runs explicitly ",
             "before calling this script.", call. = FALSE)
    }

    # set() not [[<- : the base assignment forces a shallow copy and data.table
    # emits a warning about it on every load, which is noise in a SLURM .out.
    for (cc in c("reserveRatio", "mu", "lambdaI", "lambdaC", "depQuantile"))
        set(dt, j = cc, value = as.numeric(dt[[cc]]))
    dt[, lambdaGap := round(lambdaC - lambdaI, 4)]
    dt[, arm := label]

    # ⚠️ mcDepth is a MODELLING parameter (decision precision scales as
    # 1/sqrt(depth)), not a compute setting. consolidate_results.py says in so
    # many words: DO NOT POOL ACROSS DEPTHS. Nothing enforced it until now.
    depths <- sort(unique(dt$mcDepth))
    if (length(depths) > 1) {
        stop(label, ": consolidated CSV mixes Monte Carlo depths (",
             paste(depths, collapse = ", "), "). Decision precision scales as ",
             "1/sqrt(depth), so these are different models and must not be pooled. ",
             "Split the arm by mcDepth first.", call. = FALSE)
    }

    cat(sprintf("%-10s %s rows, %d headline strata, %d mu levels, %d paramSeeds, mcDepth %s\n",
                label, format(nrow(dt), big.mark = ","),
                nrow(unique(dt[, ..STRATA_HEADLINE])),
                uniqueN(dt$mu), uniqueN(dt$paramSeed), depths))
    dt
}

dt_t <- load_arm(arm_dir, "treatment")
dt_p <- if (nzchar(compare_dir)) load_arm(compare_dir, "placebo") else NULL

# Arms must agree on depth too, or the contrast compares two different models.
if (!is.null(dt_p) && unique(dt_t$mcDepth) != unique(dt_p$mcDepth)) {
    stop("treatment ran at mcDepth ", unique(dt_t$mcDepth), " and placebo at ",
         unique(dt_p$mcDepth), ". The contrast would difference two different ",
         "models. Re-run one arm to match.", call. = FALSE)
}

# ── Cluster table: one row per (stratum, mu, paramSeed) ─────────────────────
# The bootstrap resamples paramSeeds, so collapse to that grain once and then
# every replicate is a fast sum over a small table. The numerator is always
# named `k` downstream regardless of which outcome filled it.
clusters <- function(dt, outcome, strata) {
    dt[, .(n = .N, k = sum(get(outcome$col))),
       by = c(strata, "mu", "paramSeed")]
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
excess_table <- function(cl, n_boot, strata) {
    strata_vals <- unique(cl[, ..strata])
    out <- vector("list", nrow(strata_vals))
    for (i in seq_len(nrow(strata_vals))) {
        key <- strata_vals[i]
        sub <- cl[key, on = strata]
        mu_levels <- sort(unique(sub$mu))

        # Refuse to report rather than report vacuously. An interior peak needs
        # at least three mu levels to exist at all.
        if (length(mu_levels) < 3) {
            out[[i]] <- cbind(key, data.table(
                mu = NA_real_, nMuLevels = length(mu_levels), excess = NA_real_,
                se = NA_real_, ci_lo = NA_real_, ci_hi = NA_real_,
                nSeeds = uniqueN(sub$paramSeed), nRuns = sum(sub$n),
                testable = FALSE))
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
        out[[i]] <- cbind(key, data.table(
            mu = est$mu, nMuLevels = length(mu_levels), excess = est$excess,
            se    = apply(boot, 2, sd),
            ci_lo = apply(boot, 2, quantile, 0.025, names = FALSE),
            ci_hi = apply(boot, 2, quantile, 0.975, names = FALSE),
            nSeeds = uniqueN(sub$paramSeed), nRuns = sum(sub$n), testable = TRUE))
    }
    rbindlist(out)
}

# ── One full analysis for a given (outcome, stratification) ─────────────────
run_block <- function(outcome, strata, block, make_figure) {
    sc  <- outcome$scale
    tag <- paste0(outcome$key, "__", block)

    cat("\n", strrep("=", 74), "\n", sep = "")
    cat("OUTCOME: ", outcome$desc, "\n", sep = "")
    cat("UNITS:   ", outcome$unit, "\n", sep = "")
    cat("STRATA:  ", paste(strata, collapse = " x "), "\n", sep = "")
    cat(strrep("=", 74), "\n", sep = "")

    cl_t <- clusters(dt_t, outcome, strata)
    cat("Bootstrapping treatment arm (", nrow(unique(cl_t[, ..strata])), " strata)...\n", sep = "")
    ex_t <- excess_table(cl_t, n_boot, strata)
    ex_t[, arm := "treatment"]

    untestable <- ex_t[testable == FALSE]
    if (nrow(untestable) > 0) {
        cat("\n⚠️", nrow(untestable), "stratum/strata have fewer than 3 mu levels — an interior\n")
        cat("   peak cannot exist there. Reported as NA (untestable), NOT as monotonic.\n")
    }

    res <- ex_t
    if (!is.null(dt_p)) {
        cat("Bootstrapping placebo arm...\n")
        cl_p <- clusters(dt_p, outcome, strata)
        ex_p <- excess_table(cl_p, n_boot, strata)
        ex_p[, arm := "placebo"]
        res <- rbind(ex_t, ex_p)

        # ── The headline contrast ────────────────────────────────────────────
        # Independent arms, so the difference's SE adds in quadrature.
        keep_t <- c(strata, "mu", "excess", "se")
        d <- merge(setnames(ex_t[testable == TRUE, ..keep_t],
                            c("excess", "se"), c("ex_t", "se_t")),
                   setnames(ex_p[testable == TRUE, ..keep_t],
                            c("excess", "se"), c("ex_p", "se_p")),
                   by = c(strata, "mu"))
        d[, diff := ex_t - ex_p]
        d[, se   := sqrt(se_t^2 + se_p^2)]
        d[, z    := diff / se]
        setorder(d, -diff)
        fwrite(d, file.path(out_dir, paste0("p6b_treatment_minus_placebo__", tag, ".csv")))

        cat("\n=== P6b: excess(treatment) - excess(placebo) — ", outcome$unit, " ===\n", sep = "")
        cat("Positive = hump present under warm-up assignment and absent when\n")
        cat("cultural type is decoupled from network position. That is P6b.\n\n")
        show <- copy(d)
        show[, `:=`(excess_treat = round(sc * ex_t, 2),
                    excess_placebo = round(sc * ex_p, 2),
                    diff_u = round(sc * diff, 2),
                    se_u = round(sc * se, 2), z = round(z, 2))]
        print(show[, c(strata, "mu", "excess_treat", "excess_placebo",
                       "diff_u", "se_u", "z"), with = FALSE])
        cat(sprintf("\nPooled: mean diff %+.3f %s over %d stratum-mu points; %d of %d positive.\n",
                    sc * mean(d$diff), outcome$unit, nrow(d), sum(d$diff > 0), nrow(d)))

        # ── Assumption check: P6a must be untouched at the endpoints ─────────
        # At mu = 0 and mu = 1 only one type is present, so P6b is zero by
        # construction. Any between-arm gap there is P6a contamination and the
        # contrast above is not clean.
        ends <- function(cl) {
            mus <- sort(unique(cl$mu))
            cl[mu %in% c(mus[1], mus[length(mus)]),
               .(rate = sum(k) / sum(n), nRuns = sum(n)),
               by = c(strata, "mu")]
        }
        ec <- merge(setnames(ends(cl_t), "rate", "rate_t")[, c(strata, "mu", "rate_t"), with = FALSE],
                    setnames(ends(cl_p), "rate", "rate_p")[, c(strata, "mu", "rate_p"), with = FALSE],
                    by = c(strata, "mu"))
        ec[, gap_u := sc * (rate_t - rate_p)]
        fwrite(ec, file.path(out_dir, paste0("endpoint_contamination__", tag, ".csv")))
        cat("\n=== Assumption check: P6a unchanged at the endpoints ===\n")
        cat(sprintf("mean |gap| at mu endpoints: %.3f %s   max |gap|: %.3f %s\n",
                    mean(abs(ec$gap_u)), outcome$unit,
                    max(abs(ec$gap_u)), outcome$unit))
        cat("Large gaps here mean random assignment moved P6a too, and the contrast\n")
        cat("above is not clean. See endpoint_contamination__", tag, ".csv.\n", sep = "")
    }

    fwrite(res, file.path(out_dir, paste0("p6b_excess_above_chord__", tag, ".csv")))

    cat("\n=== Within-arm excess above the endpoint chord — ", outcome$unit, " ===\n", sep = "")
    cat("⚠️ Confounded with P6a curvature — see the header. Diagnostic, not a result.\n\n")
    shown <- res[testable == TRUE]
    if (nrow(shown) > 0) {
        shown <- copy(shown)
        shown[, `:=`(excess_u = round(sc * excess, 2),
                     ci = sprintf("[%+.2f, %+.2f]", sc * ci_lo, sc * ci_hi))]
        setorderv(shown, c("arm", strata, "mu"))
        print(shown[, c("arm", strata, "mu", "nMuLevels", "excess_u", "ci", "nSeeds"),
                    with = FALSE])
    }

    # ── Figure (headline stratification only — the facet grid is 2-D) ────────
    if (make_figure && !CAN_PLOT) {
        cat("\n(figure skipped — plotting packages unavailable; CSVs above are complete)\n")
    }
    if (make_figure && CAN_PLOT && nrow(res[testable == TRUE]) > 0) {
        plot_dt <- res[testable == TRUE]
        p <- ggplot(plot_dt, aes(x = factor(mu), y = sc * excess,
                                 ymin = sc * ci_lo, ymax = sc * ci_hi,
                                 color = arm, group = arm)) +
            geom_hline(yintercept = 0, linewidth = 0.4, color = "grey40") +
            geom_pointrange(position = position_dodge(width = 0.4), size = 0.35) +
            facet_grid(sprintf("λ-gap %.1f", lambdaGap) ~ sprintf("r = %.2f", reserveRatio)) +
            labs(title = paste0("P6b: excess above the endpoint chord — ", outcome$desc),
                 subtitle = paste0("Cluster bootstrap on paramSeed (", n_boot,
                                   " reps). Positive = interior hump above a linear P6a baseline."),
                 x = expression("Individualist share " * mu),
                 y = paste0("Excess (", outcome$unit, ")"), color = NULL) +
            theme_minimal(base_size = 10) +
            theme(legend.position = "bottom", panel.grid.minor = element_blank())
        ggsave(file.path(out_dir, paste0("p6b_excess__", tag, ".png")), p,
               width = 11, height = 6, dpi = 200)
        cat("\nWrote p6b_excess__", tag, ".png\n", sep = "")
    }

    invisible(res)
}

# ── Run the blocks ──────────────────────────────────────────────────────────
# Primary outcome on both stratifications; the binary secondary on the headline
# stratification only, so the legacy comparison exists without quadrupling the
# bootstrap cost.
run_block(OUTCOMES$cascade, STRATA_HEADLINE, "headline", make_figure = TRUE)
run_block(OUTCOMES$binary,  STRATA_HEADLINE, "headline", make_figure = TRUE)

if (!skip_inter) {
    n_inter <- nrow(unique(dt_t[, ..STRATA_INTERACTION]))
    cat("\n", strrep("-", 74), "\n", sep = "")
    cat("INSURANCE INTERACTION — depQuantile x lambdaGap, the reduced-form\n")
    cat("social-learning test. ", n_inter, " strata (vs ",
        nrow(unique(dt_t[, ..STRATA_HEADLINE])), " headline), so each\n", sep = "")
    cat("stratum-mu point pools proportionally fewer paramSeeds. Check nSeeds\n")
    cat("in the output before quoting anything from it.\n")
    cat(strrep("-", 74), "\n", sep = "")
    run_block(OUTCOMES$cascade, STRATA_INTERACTION, "insurance", make_figure = FALSE)
} else {
    cat("\nSkipping the insurance interaction (BANKRUN_SKIP_INTERACTION set).\n")
}

cat("\nDone. Outputs in:", out_dir, "\n")
