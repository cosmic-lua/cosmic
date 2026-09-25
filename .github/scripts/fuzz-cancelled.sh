#!/bin/sh
# Says on the run's summary how far a cancelled fuzz.yml run got, from
# the output fuzz.sh kept.
set -e

{
  echo
  echo 'Cancelled, at the time limit or by hand, before fuzzing finished: a property'
  echo 'that hangs is the likeliest cause. The end of its output:'
  echo
  echo '~~~~'
  tail -n 40 "$RUNNER_TEMP/fuzz.out" 2>/dev/null | cut -c1-300 || true
  echo '~~~~'
} >> "$GITHUB_STEP_SUMMARY"
