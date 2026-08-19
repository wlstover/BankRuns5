#!/usr/bin/env Rscript
#
# test_p6b_continuous.R — ground-truth fixtures for scripts/analysis_p6b.R
# under the CONTINUOUS outcome (cascade size |S*|), added 2026-08-17.
#
# WHY THIS FILE EXISTS
# --------------------
# The four fixtures that validated the binary version of analysis_p6b.R on
# 2026-08-16 were built in-session and never committed — tests/ held only Julia
# tests. So the one artefact proving the estimator works could not be re-run.
# This commits them, and extends them to the continuous outcome, where the
# estimator is a mean rather than a proportion.
#
# Each fixture is generated with a KNOWN answer, at the real clustering depth
# (runs nested in paramSeed, ICC ~ 0.27 as measured on the legacy sweep), and
# the script's output is checked against it.
#
#   A  real P6b in treatment, none in placebo   -> contrast recovers the hump
#   B  NO P6b, but a curved P6a in BOTH arms    -> contrast ~ 0  (THE TRAP)
#   C  single mu level                          -> UNTESTABLE, not a verdict
#   D  legacy positional schema                 -> refuse to run
#   E  blank nWithdrawn (pre-instrumentation)   -> refuse to run   [NEW]
#   F  mixed mcDepth in one file                -> refuse to run   [NEW]
#
# B is the important one. A curved P6a produces a positive WITHIN-ARM excess
# with no P6b whatsoever; only the treatment-minus-placebo contrast can tell
# the two apart. The test asserts both halves: that the within-arm number is
# misleadingly positive, and that the contrast is not fooled by it.
#
# E and F are new because the continuous outcome created two new ways to be
# silently wrong that the binary version could not have: dropping legacy rows
# whose |S*| is blank, and pooling Monte Carlo depths.
#
# USAGE
#   Rscript tests/test_p6b_continuous.R
#
# Requires data.table. Does NOT require ggplot2 — the analysis script degrades
# to CSV-only when the plotting stack is absent, and this test relies on that.

suppressPackageStartupMessages(library(data.table))
set.seed(424242)

repo   <- normalizePath(file.path(dirname(sub("^--file=", "",
              grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), ".."))
script <- file.path(repo, "scripts", "analysis_p6b.R")
stopifnot(file.exists(script))

root <- file.path(tempdir(), paste0("p6b_fix_", Sys.getpid()))
dir.create(root, recursive = TRUE, showWarnings = FALSE)

PASS <- 0L; FAIL <- 0L
ok <- function(cond, msg) {
    if (isTRUE(cond)) { PASS <<- PASS + 1L; cat("  PASS  ", msg, "\n")
    } else            { FAIL <<- FAIL + 1L; cat("  FAIL  ", msg, "\n") }
}

# ── Fixture generator ───────────────────────────────────────────────────────
# mean_fn(mu) gives the true mean cascade size in agents. Runs are nested in
# paramSeed with a seed-level random effect sized to give ICC ~ 0.27:
#   ICC = tau^2/(tau^2 + sigma_w^2) = 0.27  =>  tau = 0.608 * sigma_w
N_AGENTS  <- 1000
SIGMA_W   <- 60      # within-seed run-to-run sd, agents
TAU       <- 36.5    # between-seed sd, agents  (ICC ~ 0.27)
MUS       <- c(0, 0.25, 0.5, 0.75, 1)
GAPS      <- c(0.8, 0.6)
RESERVES  <- c(0.25, 0.30)
DEPQS     <- c(0.0, 0.5)
N_SEEDS   <- 40      # paramSeeds per (stratum, mu)
N_RUNS    <- 5       # runs per paramSeed

make_arm <- function(dir, mean_fn, assign_rule, mus = MUS, depths = 100,
                     blank_sstar = FALSE, legacy = FALSE, seed_base = 0,
                     n_lost = 0L) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    rows <- list(); i <- 0L; sid <- seed_base
    for (g in GAPS) for (r in RESERVES) for (q in DEPQS) for (m in mus) {
        for (s in seq_len(N_SEEDS)) {
            sid <- sid + 1L
            seed_effect <- rnorm(1, 0, TAU)
            base <- mean_fn(m, g, r)
            v <- base + seed_effect + rnorm(N_RUNS, 0, SIGMA_W)
            v <- pmin(pmax(round(v), 0), N_AGENTS)
            i <- i + 1L
            # NB: `key` is a reserved argument of data.table(), and the real
            # consolidated schema has a column of that name. Add it after
            # construction rather than passing it in.
            x <- data.table(
                task_id = sid, paramSeed = sid, replication = seq_len(N_RUNS),
                k = 6, p = 0.05, reserveRatio = r, depQuantile = q, sigma = 2.0,
                warmupAlpha = 0.1, mu = m, lambdaI = round((1 - g) / 2, 4),
                lambdaC = round((1 + g) / 2, 4),
                seed = sid, armTag = "fix", assignRule = assign_rule,
                mcDepth = if (length(depths) == 1) depths else
                          sample(depths, N_RUNS, replace = TRUE),
                completed = TRUE,
                bankRun = v > (r * N_AGENTS * 2),
                nWithdrawn = if (blank_sstar) NA_integer_ else v,
                depositWithdrawn = v * 12.5)
            x[, key := sid]
            rows[[i]] <- x
        }
    }
    dt <- rbindlist(rows)
    # Simulate the 9be29d7 teardown race: the master checked the row off, so
    # `completed` stays TRUE, but no result row was ever written, so ALL THREE
    # outcome columns are blank. This is what consolidate_results.py emits,
    # because `completed` comes from bankRunParametersFin.csv and the outcomes
    # come from bankRunResults*.csv.
    if (n_lost > 0L) {
        idx <- sample.int(nrow(dt), n_lost)
        dt[idx, `:=`(bankRun = NA, nWithdrawn = NA_integer_,
                     depositWithdrawn = NA_real_)]
    }
    if (legacy) {
        # The legacy schema's tell: columns that only it has. Its `reserveRatio`
        # holds the rewiring probability, which is exactly why name-presence
        # checks are not enough.
        dt[, `:=`(agtCnt = N_AGENTS, depositInsurance = 0.25, exogProb = 0.1)]
    }
    fwrite(dt, file.path(dir, "consolidated_results.csv"))
    dir
}

run_script <- function(arm, compare = NULL, boot = 200, skip_inter = TRUE) {
    env <- c(paste0("BANKRUN_PROJECT_ROOT=", repo),
             paste0("BANKRUN_ARM_DIR=", arm),
             paste0("BANKRUN_BOOT=", boot))
    if (!is.null(compare)) env <- c(env, paste0("BANKRUN_COMPARE_DIR=", compare))
    if (skip_inter)        env <- c(env, "BANKRUN_SKIP_INTERACTION=1")
    out <- suppressWarnings(system2("Rscript", script, env = env,
                                    stdout = TRUE, stderr = TRUE))
    list(status = attr(out, "status") %||% 0L, out = paste(out, collapse = "\n"))
}
`%||%` <- function(a, b) if (is.null(a)) b else a

# ═══ A. Real P6b in treatment, none in placebo ══════════════════════════════
# Treatment: linear P6a decline PLUS a hump that vanishes at both endpoints.
# Because the hump is zero at mu = 0 and mu = 1, the endpoint chord is exactly
# the linear part, so the true excess IS the hump: ground truth in closed form.
cat("\n=== Fixture A: real P6b (treatment) vs none (placebo) ===\n")
HUMP <- 60   # agents at the peak
hump_fn <- function(m) HUMP * 4 * m * (1 - m)
a_t <- make_arm(file.path(root, "A_treat"), function(m, g, r) 700 - 200 * m + hump_fn(m),
                "warmup", seed_base = 0)
a_p <- make_arm(file.path(root, "A_plac"),  function(m, g, r) 700 - 200 * m,
                "random", seed_base = 100000)
ra <- run_script(a_t, a_p)
ok(ra$status == 0, "A: script exits 0")
fa <- file.path(a_t, "analysis", "p6b_treatment_minus_placebo__cascade__headline.csv")
ok(file.exists(fa), "A: contrast CSV written")
if (file.exists(fa)) {
    d <- fread(fa)
    d[, truth := hump_fn(mu)]
    err <- mean(d$diff - d$truth)
    cat(sprintf("     mean contrast %.1f agents vs truth %.1f (bias %+.1f); %d/%d positive\n",
                mean(d$diff), mean(d$truth), err, sum(d$diff > 0), nrow(d)))
    ok(abs(err) < 12, "A: contrast recovers the hump (bias < 12 agents)")
    ok(sum(d$diff > 0) >= 0.8 * nrow(d), "A: >=80% of stratum-mu points positive")
}

# ═══ B. THE TRAP: curved P6a in both arms, no P6b anywhere ══════════════════
# Both arms get an identical NONLINEAR P6a. Within-arm excess is positive and
# looks exactly like P6b. The contrast must refuse it.
cat("\n=== Fixture B: curved P6a in BOTH arms, no P6b (the trap) ===\n")
CURV <- 50
curved <- function(m, g, r) 700 - 200 * m + CURV * 4 * m * (1 - m)
b_t <- make_arm(file.path(root, "B_treat"), curved, "warmup", seed_base = 200000)
b_p <- make_arm(file.path(root, "B_plac"),  curved, "random", seed_base = 300000)
rb <- run_script(b_t, b_p)
ok(rb$status == 0, "B: script exits 0")
fb  <- file.path(b_t, "analysis", "p6b_treatment_minus_placebo__cascade__headline.csv")
fbw <- file.path(b_t, "analysis", "p6b_excess_above_chord__cascade__headline.csv")
if (file.exists(fb) && file.exists(fbw)) {
    d  <- fread(fb); w <- fread(fbw)
    within <- mean(w[testable == TRUE & arm == "treatment"]$excess)
    cat(sprintf("     within-arm excess %+.1f agents (misleading), contrast %+.1f agents\n",
                within, mean(d$diff)))
    ok(within > 20,             "B: within-arm excess IS misleadingly positive")
    ok(abs(mean(d$diff)) < 12,  "B: contrast is NOT fooled (|mean| < 12 agents)")
}

# ═══ C. Single mu level -> untestable, not a verdict ════════════════════════
cat("\n=== Fixture C: single mu level ===\n")
c_t <- make_arm(file.path(root, "C_treat"), function(m, g, r) 700, "warmup",
                mus = 0.5, seed_base = 400000)
rc <- run_script(c_t)
ok(rc$status == 0, "C: script exits 0 (does not crash on a smoke-shaped arm)")
fc <- file.path(c_t, "analysis", "p6b_excess_above_chord__cascade__headline.csv")
if (file.exists(fc)) {
    d <- fread(fc)
    ok(all(d$testable == FALSE), "C: every stratum marked testable = FALSE")
    ok(all(is.na(d$excess)),     "C: excess is NA, not a number")
    ok(grepl("fewer than 3 mu levels", rc$out, fixed = TRUE),
       "C: warns that an interior peak cannot exist")
}

# ═══ D. Legacy positional schema -> refuse ══════════════════════════════════
cat("\n=== Fixture D: legacy positional schema ===\n")
d_t <- make_arm(file.path(root, "D_treat"), function(m, g, r) 700 - 200 * m,
                "warmup", legacy = TRUE, seed_base = 500000)
rd <- run_script(d_t)
ok(rd$status != 0, "D: script REFUSES the legacy schema (non-zero exit)")
ok(grepl("LEGACY positional schema", rd$out), "D: names the legacy schema in the error")

# ═══ E. Blank nWithdrawn -> refuse, do not drop ═════════════════════════════
cat("\n=== Fixture E: blank |S*| (pre-instrumentation runs) ===\n")
e_t <- make_arm(file.path(root, "E_treat"), function(m, g, r) 700 - 200 * m,
                "warmup", blank_sstar = TRUE, seed_base = 600000)
re <- run_script(e_t)
ok(re$status != 0, "E: script REFUSES blank nWithdrawn rather than dropping them")
ok(grepl("blank", re$out) && grepl("instrumentation", re$out),
   "E: error explains these predate the |S*| instrumentation")

# ═══ E2. Lost result rows BELOW the cap -> drop, loudly ═════════════════════
# The 2026-08-19 production run halted with "53 of 540,000 ... predate the
# instrumentation". That diagnosis was wrong: those rows had NO result row at
# all, from the check-off-before-write race fixed in 9be29d7, and the advice to
# re-run the arm would have cost two days for 0.0098% of the data. These two
# fixtures pin the distinction so it cannot regress.
cat("\n=== Fixture E2: lost result rows, below the cap ===\n")
e2_t <- make_arm(file.path(root, "E2_treat"), function(m, g, r) 700 - 200 * m,
                 "warmup", seed_base = 610000, n_lost = 3L)
e2_p <- make_arm(file.path(root, "E2_plac"), function(m, g, r) 700 - 200 * m,
                 "random", seed_base = 620000)
re2 <- run_script(e2_t, e2_p, boot = 100)
ok(re2$status == 0, "E2: proceeds when lost rows are below the cap")
ok(grepl("NO result row", re2$out), "E2: says the rows have no result row")
ok(grepl("9be29d7|check-off-before-write", re2$out),
   "E2: names the teardown race, NOT the instrumentation")
ok(!grepl("predate the", re2$out),
   "E2: does NOT misattribute this to pre-instrumentation data")
ok(grepl("selected on run duration", re2$out),
   "E2: warns the loss is not missing-at-random")
ok(file.exists(file.path(e2_t, "analysis", "dropped_no_result__treatment.csv")),
   "E2: writes the dropped keys out for audit")
ok(file.exists(file.path(e2_t, "analysis",
                         "p6b_treatment_minus_placebo__cascade__headline.csv")),
   "E2: still produces the headline contrast")

# ═══ E3. Lost result rows ABOVE the cap -> refuse ═══════════════════════════
cat("\n=== Fixture E3: lost result rows, above the cap ===\n")
e3_t <- make_arm(file.path(root, "E3_treat"), function(m, g, r) 700 - 200 * m,
                 "warmup", seed_base = 630000, n_lost = 400L)
re3 <- run_script(e3_t)
ok(re3$status != 0, "E3: REFUSES when lost rows exceed the cap")
ok(grepl("above the", re3$out) && grepl("cap", re3$out),
   "E3: names the cap it exceeded")
ok(grepl("diagnose_short_cells", re3$out),
   "E3: points at the diagnostic rather than leaving it hanging")

# ═══ F. Mixed Monte Carlo depth -> refuse ═══════════════════════════════════
cat("\n=== Fixture F: mixed mcDepth in one arm ===\n")
f_t <- make_arm(file.path(root, "F_treat"), function(m, g, r) 700 - 200 * m,
                "warmup", depths = c(100, 1000), seed_base = 700000)
rf <- run_script(f_t)
ok(rf$status != 0, "F: script REFUSES mixed mcDepth (different models)")
ok(grepl("mixes Monte Carlo depths", rf$out), "F: names the depth mixture")

# ═══ G. Insurance interaction actually stratifies on depQuantile ════════════
cat("\n=== Fixture G: insurance interaction block ===\n")
rg <- run_script(a_t, a_p, boot = 100, skip_inter = FALSE)
fg <- file.path(a_t, "analysis", "p6b_treatment_minus_placebo__cascade__insurance.csv")
ok(rg$status == 0,  "G: script exits 0 with the interaction enabled")
ok(file.exists(fg), "G: interaction CSV written")
if (file.exists(fg)) {
    d <- fread(fg)
    ok("depQuantile" %in% names(d), "G: interaction output carries depQuantile")
    ok(uniqueN(d$depQuantile) == length(DEPQS),
       sprintf("G: all %d insurance levels present", length(DEPQS)))
    ok(nrow(unique(d[, .(lambdaGap, reserveRatio, depQuantile)])) ==
       length(GAPS) * length(RESERVES) * length(DEPQS),
       "G: stratum count = lambdaGap x reserveRatio x depQuantile")
}

# ── Summary ─────────────────────────────────────────────────────────────────
cat("\n", strrep("=", 60), "\n", sep = "")
cat(sprintf("%d PASS / %d FAIL\n", PASS, FAIL))
cat(strrep("=", 60), "\n", sep = "")
unlink(root, recursive = TRUE)
if (FAIL > 0) quit(status = 1)
