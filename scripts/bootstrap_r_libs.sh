#!/usr/bin/env bash
#
# bootstrap_r_libs.sh — install the analysis stage's R packages into a
# project-local library on HPC. Run once; run_analysis.slurm finds the result.
#
# WHY THIS EXISTS
# ---------------
# The analysis stage of run_all.sh had never produced output. Two of the
# reasons were bugs in analysis_p6.R (fixed 2026-08-15). The third, found
# 2026-08-16, is not a bug in our code at all: hopper's `module load r`
# resolves to
#     /opt/sw/other/apps/r/4.3.1/gnu-openblas
# whose site library does not contain data.table. There is no writable site
# library, so the packages have to live somewhere we own.
#
# They go in ${PROJECT_ROOT}/.Rlib/<R version> — project-level rather than
# ~/, so anyone in tstratma running this pipeline picks them up, and keyed by
# R version so a module change does not silently load objects built against a
# different R. .Rlib/ is gitignored.
#
# Usage (on hopper, login node is fine — this is a compile, not a job):
#     cd /projects/tstratma/BankRuns5
#     ./scripts/bootstrap_r_libs.sh
#
# If hopper has no outbound network to CRAN this will fail at download. That
# is not fatal to the chapter: the consolidated CSV is small (a single-cell
# arm is 250 rows; the full 2026-04 sweep is 68 MB), so the fallback is to
# rsync it down and run analysis_p6.R locally. See README.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# The analysis needs exactly these. scales arrives as a ggplot2 dependency but
# is named explicitly because analysis_p6.R calls scales::percent_format()
# directly, so it must be a hard requirement rather than an incidental one.
PKGS='c("data.table", "ggplot2", "scales")'
CRAN="${CRAN_MIRROR:-https://cloud.r-project.org}"

echo "=================================================================="
echo "bootstrap_r_libs.sh"
echo "  project root: ${PROJECT_ROOT}"
echo "  CRAN mirror:  ${CRAN}"
echo "=================================================================="
echo ""

module load gnu10/10.3.0-ya 2>/dev/null || echo "note: gnu10 module not loaded (fine off-HPC)"
if module load R/4.2.0-hb 2>/dev/null; then echo "Loaded R/4.2.0-hb"
elif module load R 2>/dev/null;          then echo "Loaded R (default)"
elif module load r 2>/dev/null;          then echo "Loaded r (default)"
else echo "note: no R module found; using whatever R is in PATH"
fi

command -v R >/dev/null || { echo "ERROR: no R in PATH" >&2; exit 1; }
R_VERSION="$(Rscript -e 'cat(paste0(R.version$major, ".", R.version$minor))')"
LIB="${PROJECT_ROOT}/.Rlib/${R_VERSION}"
mkdir -p "${LIB}"

echo ""
echo "R version:    ${R_VERSION}"
echo "target lib:   ${LIB}"
echo ""
echo "Installing ${PKGS} — this compiles from source and takes 10-25 min."
echo ""

# Ncpus: the login node is shared, so be modest.
Rscript --vanilla -e "
    lib <- '${LIB}'
    .libPaths(c(lib, .libPaths()))
    want <- ${PKGS}
    have <- want[vapply(want, requireNamespace, logical(1), quietly = TRUE)]
    need <- setdiff(want, have)
    if (length(have)) cat('already available:', paste(have, collapse = ', '), '\n')
    if (!length(need)) { cat('nothing to install.\n'); quit(status = 0) }
    cat('installing:', paste(need, collapse = ', '), '\n\n')
    install.packages(need, lib = lib, repos = '${CRAN}', Ncpus = 4)
"

echo ""
echo "=================================================================="
echo "Verifying — every package must load FROM a library, by name:"
echo "=================================================================="
Rscript --vanilla -e "
    .libPaths(c('${LIB}', .libPaths()))
    want <- ${PKGS}
    bad <- character(0)
    for (p in want) {
        ok <- requireNamespace(p, quietly = TRUE)
        if (ok) {
            cat(sprintf('  PASS  %-12s %-10s %s\n', p,
                        as.character(utils::packageVersion(p)),
                        dirname(system.file(package = p))))
        } else {
            cat(sprintf('  FAIL  %-12s not installed\n', p)); bad <- c(bad, p)
        }
    }
    if (length(bad)) {
        cat('\nSTILL MISSING:', paste(bad, collapse = ', '), '\n')
        cat('If the failure was a download error, hopper may have no route to\n')
        cat('CRAN. Fall back to running analysis_p6.R locally on an rsync\\'d\n')
        cat('consolidated_results.csv — see scripts/README.md.\n')
        quit(status = 1)
    }
    cat('\nAll analysis packages present.\n')
"

echo ""
echo "Done. run_analysis.slurm will find these automatically via R_LIBS_USER."
