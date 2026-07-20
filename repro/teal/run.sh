#!/usr/bin/env bash
# Iteration 3 driver: run the REAL teal compiler under a fresh, high-concurrency
# sandboxed burst and count compiles that report "module not found" for a
# present, granted module — the #744 signature.
#
# Env knobs: MAKE (landlock-make), N (test files), K (modules each requires),
#            J (-j), ITERS (fresh bursts).
set -u

BOOT_URL=https://github.com/whilp/cosmic/releases/download/2026-07-19-5c6bce5/cosmic-lua
BOOT_SHA=6c2a0afe6c942560ce2a0d796ddf8f8df096ce2c92b8ce142c28da59ecac6dc6

MAKE=${MAKE:-./cosmo-make}
N=${N:-250}
K=${K:-100}
J=${J:-$(nproc 2>/dev/null || echo 4)}
ITERS=${ITERS:-8}

# 1. Bootstrap: download once, assimilate to a native ELF (sandboxed rules
#    need an ELF, not an APE that would extract a loader into an ungranted dir).
if [ ! -x cosmic ]; then
  curl -fsSL -o cosmic "$BOOT_URL" || { echo "download failed"; exit 3; }
  echo "$BOOT_SHA  cosmic" | sha256sum -c - || { echo "bootstrap sha mismatch"; exit 3; }
  chmod +x cosmic
  ./cosmic --assimilate
  printf '\177ELF' | cmp -s - <(head -c 4 cosmic) || { echo "assimilate did not yield ELF"; exit 3; }
fi

# 2. Synthetic tree: K modules; N test files each requiring all K; one hidden
#    module (present but never unveiled) for the enforcement canary.
mkdir -p mods tests hidden-mods
for k in $(seq 1 "$K"); do [ -f "mods/m$k.tl" ] || echo 'return {}' > "mods/m$k.tl"; done
[ -f hidden-mods/hm.tl ] || echo 'return {}' > hidden-mods/hm.tl
[ -f canary.tl ] || echo 'require("hidden-mods.hm")' > canary.tl
if [ ! -f "tests/test-$N.tl" ]; then
  for n in $(seq 1 "$N"); do
    { for k in $(seq 1 "$K"); do echo "require(\"mods.m$k\")"; done; echo 'return {}'; } \
      > "tests/test-$n.tl"
  done
fi

echo "teal-repro: MAKE=$MAKE N=$N K=$K J=$J ITERS=$ITERS"
echo "fd limits: RLIMIT_NOFILE soft=$(ulimit -Sn) hard=$(ulimit -Hn)"

enforced=unknown
fails=0
runs_with_fail=0
for it in $(seq 1 "$ITERS"); do
  rm -rf o && mkdir -p o
  "$MAKE" -k -j"$J" N="$N" K="$K" all >/dev/null 2>&1 || true
  [ -f o/canary.status ] && enforced=$(sed -n 's/^ENFORCE=//p' o/canary.status)
  f=$(grep -l 'module not found\|COMPILE-FAILED' o/test-*.err 2>/dev/null | wc -l | tr -d ' ')
  if [ "${f:-0}" -gt 0 ]; then
    runs_with_fail=$((runs_with_fail + 1))
    fails=$((fails + f))
    printf 'iter %d: %d/%d compiles FAILED | %s\n' "$it" "$f" "$N" \
      "$(grep -h 'module not found' o/test-*.err 2>/dev/null | head -1)"
  fi
done

echo "-----------------------------------------------------------"
echo "sandbox enforcing: $enforced"
echo "runs with >=1 failed compile: $runs_with_fail / $ITERS"
echo "total failed compiles       : $fails"
if [ "$enforced" != "yes" ]; then
  echo "RESULT: INCONCLUSIVE — sandbox not enforcing reads (canary compiled a non-granted module)"
  exit 2
fi
if [ "$fails" -gt 0 ]; then
  echo "RESULT: REPRODUCED (#744 — a granted module resolved as not found under the burst)"
  exit 1
fi
echo "RESULT: clean — every granted module resolved across $ITERS fresh bursts"
exit 0
