#!/bin/sh
# What a merge queue's platform leg keeps for a push to main to reuse
# (ci/README.md's "the queue's result"):
#
#     sh .github/scripts/queue-seed.sh stage
#
# The lookups of the queue's runs, which `find` and `ahead` answer, are
# the driver's (`driver.tl queue-find` and `queue-ahead`,
# ci/cosmic_ci/queue_seed.tl): they read the API, and this only copies
# files and runs `tar`, which keeps a file's mode.
#
# stage, a merge_group run's platform leg that passed: copies into
# $RUNNER_TEMP/seed what a push to main would have saved, and writes
# there `seed.keys`, a line `<cache>=<key>` for each, the key it saves
# under: `verdicts` (from $RUNNER_TEMP/verdicts) and `compiles` (from
# $RUNNER_TEMP/build-cache), each as <X>_PREFIX and <X>_DIGEST, where
# the digest is not empty and the key is not <X>_RESTORED, the entry the
# run restored (a job that saves no compiles, ci.yml's `checked`, sets
# no COMPILES_*); `verdicts-sha`, the verdicts' copy keyed by the commit,
# <VERDICTS_PREFIX>sha-<SHA>, where the digest is not empty, even where it
# names the entry restored (the commit's own key is saved on every push
# to main, for a branch based on it: `driver.tl merge-base`); and
# `driver-checked` (from $RUNNER_TEMP/driver-checked), the key its marker
# holds, where the driver check ran and passed; and `zig-build` (from
# $RUNNER_TEMP/zig-build, as $RUNNER_TEMP/seed-zig/zig-build.tar, an
# artifact of its own: an artifact keeps no file's mode, and zig's
# cache holds programs it runs), under ZIG_BUILD_KEY, the restore's
# primary key, where ZIG_BUILD_EXACT, the prefix of an entry built from
# this very core and vendor part, does not begin ZIG_BUILD_RESTORED,
# the entry restored, with that prefix as `zig-build-exact`, which main's
# `seed` looks up before it saves (a job that saves no zig build
# outputs, ci.yml's `checked`, sets no ZIG_BUILD_*). A tar that fails
# keeps none, and the stage goes on: they save only time.
#
set -eu

usage="usage: queue-seed.sh stage"
[ $# -eq 1 ] && [ "$1" = stage ] || { echo "$usage" >&2; exit 2; }

# The entry NAME, from DIR, under PREFIX and DIGEST, unless the digest is
# empty or the key is RESTORED.
entry() {
  name=$1 dir=$2 prefix=$3 digest=$4 restored=$5
  [ -n "$digest" ] && [ "$prefix$digest" != "$restored" ] || return 0
  cp -R "$RUNNER_TEMP/$dir" "$seed/$dir"
  echo "$name=$prefix$digest" >> "$seed/seed.keys"
}

# zig's build outputs under KEY, unless EXACT begins RESTORED (an entry
# of this core and vendor part answers already; an empty EXACT begins
# every key). Never a failure: none kept costs only time.
zig_build() {
  key=$1 exact=$2 restored=$3
  [ -n "$key" ] && [ -d "$RUNNER_TEMP/zig-build" ] || return 0
  case $restored in "$exact"*) return 0 ;; esac
  mkdir -p "$zig" &&
    tar -cf "$zig/zig-build.tar" -C "$RUNNER_TEMP" zig-build || {
    rm -f "$zig/zig-build.tar"
    echo "warning: the zig build outputs could not be kept: none seeded" >&2
    return 0
  }
  echo "zig-build=$key" >> "$seed/seed.keys"
  echo "zig-build-exact=$exact" >> "$seed/seed.keys"
}

stage() {
  seed=$RUNNER_TEMP/seed zig=$RUNNER_TEMP/seed-zig
  rm -rf "$seed" "$zig"
  mkdir -p "$seed"
  : > "$seed/seed.keys"
  entry verdicts verdicts "${VERDICTS_PREFIX-}" "${VERDICTS_DIGEST-}" "${VERDICTS_RESTORED-}"
  entry compiles build-cache "${COMPILES_PREFIX-}" "${COMPILES_DIGEST-}" "${COMPILES_RESTORED-}"
  if [ -n "${VERDICTS_DIGEST-}" ] && [ -n "${SHA-}" ]; then
    [ -d "$seed/verdicts" ] || cp -R "$RUNNER_TEMP/verdicts" "$seed/verdicts"
    echo "verdicts-sha=${VERDICTS_PREFIX-}sha-$SHA" >> "$seed/seed.keys"
  fi
  zig_build "${ZIG_BUILD_KEY-}" "${ZIG_BUILD_EXACT-}" "${ZIG_BUILD_RESTORED-}"
  if [ -f "$RUNNER_TEMP/driver-checked/key" ]; then
    cp -R "$RUNNER_TEMP/driver-checked" "$seed/driver-checked"
    echo "driver-checked=$(cat "$RUNNER_TEMP/driver-checked/key")" >> "$seed/seed.keys"
  fi
  cat "$seed/seed.keys"
}

stage
