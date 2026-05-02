#!/bin/bash
# Per-parameter distribution of TIMEOUT vs. COMPLETED array tasks for
# the BankRuns5 sweep (job 6976310, params_focused.txt, --array=1-2160).
#
# Prereqs:
#   ~/bankrun_timeouts.txt    sacct --state=TIMEOUT ... | sed 's/.*_//'
#   ~/bankrun_completed.txt   sacct --state=COMPLETED ... | sed 's/.*_//'
#   ~/bankrun_timeout_params.txt     awk-joined against params_focused.txt
#   ~/bankrun_completed_params.txt   ditto
#
# Usage:
#   bash ~/pattern.sh > ~/bankrun_params_patterns.txt
#   cat ~/bankrun_params_patterns.txt
#
# Output is ~90 lines; paste the full cat output back to Claude.

cols="reserve depq sigma k p alpha mu lambdaI lambdaC"

for col in 1 2 3 4 5 6 7 8 9; do
  name=$(echo "$cols" | awk -v c=$col '{print $c}')
  echo "=== $name (col $col) ==="
  echo "TIMEOUT:"
  awk -v c=$col '{print $c}' ~/bankrun_timeout_params.txt | sort | uniq -c | sort -rn
  echo "COMPLETED:"
  awk -v c=$col '{print $c}' ~/bankrun_completed_params.txt | sort | uniq -c | sort -rn
  echo
done
