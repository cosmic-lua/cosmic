#!/usr/bin/env bash
# #744 instrumented compile burst. Runs as the runner user inside the netns.
# Loops fresh, parallel strict-compile bursts under INSTRUMENT=1 and captures
# the first run that reproduces the offline-lane resolution failure, dumping
# the io-log.lua errno diagnostics that pinpoint the failing open.
set -u

ITERS=${ITERS:-40}
LOG=o/instrument-744.log
: > "$LOG"

sig='IOOPENFAIL|COMPILEFAIL|module not found|invalid key|cannot open file'

echo "instrument-744: ITERS=$ITERS -j=$(nproc)"
for it in $(seq 1 "$ITERS"); do
  # Wipe compiled outputs; keep staged deps (o/tl, o/cosmos), bootstrap, bin.
  rm -rf o/lib o/docs o/cosmic/.built o/bin/cosmic o/main.lua 2>/dev/null || true
  # -k so one failing compile does not abort the rest of the burst; capture
  # stderr (io-log writes there) plus stdout into the per-iter log.
  INSTRUMENT=1 bin/make -k -j build >>"$LOG" 2>&1 || true
  if grep -Eq "$sig" "$LOG"; then
    echo "=========================================================="
    echo "CAUGHT on iteration $it — matching lines:"
    grep -nE "$sig" "$LOG" | head -40
    echo "----------- surrounding context (last 120 lines) ---------"
    tail -120 "$LOG"
    exit 1
  fi
  echo "iter $it/$ITERS clean"
done

echo "=========================================================="
echo "no reproduction across $ITERS iterations (compiles all clean)"
exit 0
