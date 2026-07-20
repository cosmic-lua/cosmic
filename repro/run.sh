#!/usr/bin/env bash
# Drive the #744 reproduction: repeated fresh, high-concurrency bursts of
# Landlock-sandboxed children, counting any that lose their global grant.
#
# Env knobs:
#   MAKE   path to landlock-make            (default ./cosmo-make)
#   N      probes per fresh run             (default 300)
#   J      -j concurrency                   (default nproc)
#   ITERS  fresh runs to attempt            (default 40)
set -u

MAKE=${MAKE:-./cosmo-make}
N=${N:-300}
J=${J:-$(nproc 2>/dev/null || echo 4)}
ITERS=${ITERS:-40}
HAMMER=${HAMMER:-2000}

echo "repro: MAKE=$MAKE N=$N J=$J ITERS=$ITERS HAMMER=$HAMMER"
echo "fd limits: RLIMIT_NOFILE soft=$(ulimit -Sn) hard=$(ulimit -Hn); \
fs.file-max=$(cat /proc/sys/fs/file-max 2>/dev/null || echo '?'); \
fs.file-nr=$(cat /proc/sys/fs/file-nr 2>/dev/null || echo '?')"
"$MAKE" --version 2>/dev/null | head -1 || true

# Build the static reader once (the sandboxed recipes exec it).
if [ ! -x reader ]; then
  gcc -static -O2 -o reader reader.c || { echo "gcc -static failed"; exit 3; }
fi

total_denied=0
runs_with_denied=0
enforced=unknown
for it in $(seq 1 "$ITERS"); do
  # Fresh output tree, but `o` must exist BEFORE the sandboxed children run
  # (unveil skips a grant whose path is absent), so create it outside make.
  rm -rf o && mkdir -p o
  # -k so one denied child never aborts the rest of the burst.
  "$MAKE" -k -j"$J" N="$N" HAMMER="$HAMMER" all >/dev/null 2>&1 || true
  [ -f o/canary.got ] && enforced=$(sed -n 's/^ENFORCE=//p' o/canary.got)
  d=$(grep -l '^DENIED' o/probe-*.got 2>/dev/null | wc -l | tr -d ' ')
  if [ "${d:-0}" -gt 0 ]; then
    runs_with_denied=$((runs_with_denied + 1))
    total_denied=$((total_denied + d))
    errs=$(grep -ho 'errno=[0-9]*([A-Z]*)' o/probe-*.got 2>/dev/null \
      | sort | uniq -c | tr '\n' ' ')
    printf 'iter %d: %d/%d probes DENIED | errno: %s\n' "$it" "$d" "$N" "$errs"
  fi
done

echo "-----------------------------------------------------------"
echo "landlock enforcing: $enforced"
echo "runs with >=1 denied: $runs_with_denied / $ITERS"
echo "total denied probes : $total_denied"
if [ "$enforced" != "yes" ]; then
  echo "RESULT: INCONCLUSIVE — Landlock not enforcing (unveil no-op); clean result is meaningless here"
  exit 2
fi
if [ "$total_denied" -gt 0 ]; then
  echo "RESULT: REPRODUCED (a granted read was denied under the burst)"
  exit 1
fi
echo "RESULT: clean — no granted read was denied across $ITERS fresh bursts"
exit 0
