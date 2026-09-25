#!/bin/sh
# Fuzzes every property on the checked core, for fuzz.yml, from the
# checkout's root: the log streams as it runs, and the run's summary
# says what failed. FUZZ_SEED and FUZZ_ITERS come from the job.
set -e

{
  echo "FUZZ_SEED=$FUZZ_SEED FUZZ_ITERS=$FUZZ_ITERS"
  echo
  echo "A failure's report names the FUZZ_CASE that checks its input again, and its iteration under this seed."
} >> "$GITHUB_STEP_SUMMARY"
mkdir -p "$RUNNER_TEMP/fuzz"
# A failing test's directory is left under TMPDIR, holding the
# shrunk input it kept (build/test.tl's sweep).
# Streamed to the log as it runs, and kept for the summary: a run
# cancelled at its time limit still shows how far it got.
{
  status=0
  TMPDIR="$RUNNER_TEMP/fuzz" COSMIC_AUTO_BOOT=0 COSMIC_TEST_TIMEOUT=1200 \
    o/sanitized/bin/cosmic test --all $(find . \( -path ./o -o -path ./vendor -o -path ./ci \) -prune \
      -o -name '*_fuzz_test.tl' -print | sort) || status=$?
  echo "$status" > "$RUNNER_TEMP/fuzz.status"
} 2>&1 | tee "$RUNNER_TEMP/fuzz.out"
status=$(cat "$RUNNER_TEMP/fuzz.status")
# What failed, on the run's summary page: every failing test's
# line first, then the reports beneath them, bounded.
if [ "$status" -ne 0 ]; then
  {
    echo
    echo "The shrunk inputs are the run's fuzz-inputs-$FUZZ_SEED artifact; once fixed," \
      "keep each in testdata/fuzz/<property>/ as its report says."
    echo
    echo '~~~~'
    grep '^test: FAIL' "$RUNNER_TEMP/fuzz.out" | cut -c1-300 | head -30 || true
    echo
    grep -v -e '^build:' -e '^test: ' "$RUNNER_TEMP/fuzz.out" | cut -c1-300 | head -60 || true
    echo '~~~~'
  } >> "$GITHUB_STEP_SUMMARY"
fi
exit "$status"
