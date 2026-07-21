#!/usr/bin/env bash
# Iteration 4 driver: replicate #746's absolute tree-only TL_PATH resolution of
# root-dotted requires under a fresh sandboxed burst, counting compiles that
# report "module not found" for a present, granted module.
set -u

BOOT_URL=https://github.com/whilp/cosmic/releases/download/2026-07-19-5c6bce5/cosmic-lua
BOOT_SHA=6c2a0afe6c942560ce2a0d796ddf8f8df096ce2c92b8ce142c28da59ecac6dc6

MAKE=${MAKE:-./cosmo-make}
N=${N:-250}
K=${K:-100}
J=${J:-$(nproc 2>/dev/null || echo 4)}
ITERS=${ITERS:-30}

if [ ! -x cosmic ]; then
  curl -fsSL -o cosmic "$BOOT_URL" || { echo "download failed"; exit 3; }
  echo "$BOOT_SHA  cosmic" | sha256sum -c - || { echo "bootstrap sha mismatch"; exit 3; }
  chmod +x cosmic
  ./cosmic --assimilate
  printf '\177ELF' | cmp -s - <(head -c 4 cosmic) || { echo "assimilate did not yield ELF"; exit 3; }
fi

# Tree: K modules under lib/mods (granted via r:lib); N test files under
# lib/tests each root-dotted-requiring all K (the lib.docs.publish shape); one
# hidden module OUTSIDE lib/ (never granted) for the enforcement canary.
mkdir -p lib/mods lib/tests lib-hidden
for k in $(seq 1 "$K"); do [ -f "lib/mods/m$k.tl" ] || echo 'return {}' > "lib/mods/m$k.tl"; done
[ -f lib-hidden/hm.tl ] || echo 'return {}' > lib-hidden/hm.tl
[ -f canary.tl ] || echo 'require("lib-hidden.hm")' > canary.tl
if [ ! -f "lib/tests/test-$N.tl" ]; then
  for n in $(seq 1 "$N"); do
    { for k in $(seq 1 "$K"); do echo "require(\"lib.mods.m$k\")"; done; echo 'return {}'; } \
      > "lib/tests/test-$n.tl"
  done
fi

echo "tlpath-repro: MAKE=$MAKE N=$N K=$K J=$J ITERS=$ITERS"

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
  echo "RESULT: INCONCLUSIVE — sandbox not enforcing reads"
  exit 2
fi
if [ "$fails" -gt 0 ]; then
  echo "RESULT: REPRODUCED (#746 TL_PATH resolution dropped a granted module under the burst)"
  exit 1
fi
echo "RESULT: clean — #746 resolution resolved every granted module across $ITERS fresh bursts"
exit 0
