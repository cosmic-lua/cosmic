#!/bin/sh
# Bootstraps the pinned CI driver for ci.yml's jobs, which run it from
# ci/:
#
#     sh ../.github/scripts/cosmic-driver.sh [zig-cache]
#
# bin/cosmic-bootstrap fetches and verifies the pinned release into
# $XDG_CACHE_HOME/cosmic/bootstrap, where bin/zig finds it again, and
# checks a restored cache against the pin first. The driver is linked in
# as cosmic-driver on the job's PATH. `zig-cache` also points the job's
# later steps at the caches the platform job restores.
set -e

case "${1-}" in
  "" | zig-cache) ;;
  *) echo "usage: cosmic-driver.sh [zig-cache]" >&2; exit 2 ;;
esac

driver=$(COSMIC_BOOTSTRAP_VERIFY=1 XDG_CACHE_HOME="$RUNNER_TEMP/cache" \
  sh ../bin/cosmic-bootstrap)
mkdir -p "$RUNNER_TEMP/bin"
if [ -e "$RUNNER_TEMP/bin/cosmic-driver" ] || [ -L "$RUNNER_TEMP/bin/cosmic-driver" ]; then
  echo "$RUNNER_TEMP/bin/cosmic-driver already exists" >&2; exit 1
fi
ln -s "$driver" "$RUNNER_TEMP/bin/cosmic-driver"
echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"

if [ "${1-}" = zig-cache ]; then
  echo "XDG_CACHE_HOME=$RUNNER_TEMP/cache" >> "$GITHUB_ENV"
  # zig's global cache -- libc, compiler-rt and its standard library,
  # keyed by content -- is used where actions/cache restored it,
  # outside the checkout; the driver seeds and saves only the
  # project cache, which the driver keeps under o/.
  echo "COSMIC_ZIG_GLOBAL_CACHE=$RUNNER_TEMP/zig-build/zig-global" >> "$GITHUB_ENV"
  # Where ci.yml restored the zig-build cache, for the driver's
  # build and cache-save phases. Spelled from $RUNNER_TEMP, not
  # `runner.temp`: in the alpine job container the expression is
  # the host's path, which does not exist there, so the seed was
  # never found and that leg recompiled vendor/ and core/ each run.
  echo "COSMIC_ZIG_CACHE_SEED=$RUNNER_TEMP/zig-build" >> "$GITHUB_ENV"
fi
