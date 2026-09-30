#!/bin/sh
# Bootstraps the pinned CI driver for the workflows' jobs, through the
# cosmic-driver action (.github/actions/cosmic-driver), which restores
# its cache and runs this from ci/:
#
#     sh ../.github/scripts/cosmic-driver.sh [zig-cache]
#
# bin/cosmic-bootstrap fetches and verifies the pinned release into
# $XDG_CACHE_HOME/cosmic/bootstrap, where bin/zig finds it again, and
# checks a restored cache against the pin first. The driver is linked in
# as cosmic-driver on the job's PATH. `zig-cache` also points the job's
# later steps at the caches the platform job restores.
set -eu

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
  # outside the checkout, as its project cache is (the seed, below).
  echo "COSMIC_ZIG_GLOBAL_CACHE=$RUNNER_TEMP/zig-build/zig-global" >> "$GITHUB_ENV"
  # Where ci.yml restored the zig-build cache, whose zig-cache the
  # driver's builds use in place. Spelled from $RUNNER_TEMP, not
  # `runner.temp`: in the alpine job container the expression is the
  # host's path, which does not exist there, so the seed would not be
  # found and the leg would recompile vendor/ and core/ each run.
  echo "COSMIC_ZIG_CACHE_SEED=$RUNNER_TEMP/zig-build" >> "$GITHUB_ENV"
  # The test verdicts every checkout shares (build/shared_verdicts.tl),
  # keyed by what each test declares (build/declared_key.tl), kept in a
  # cache of their own that ci.yml restores before the leg's suites and
  # saves after them, each leg its own, trimmed to what the run reached
  # where it passed (cosmic_ci/verdicts.tl). Whether a suite stands on
  # them is cosmic_ci/orchestration.tl's (`stands`): every leg does, in
  # a push's run and the merge queue's -- the Linux legs sandboxed, the
  # macOS leg keyed by declared inputs unenforced, as the tree's tool
  # keys every unsandboxed run (the pinned driver, for the fixtures it
  # runs, only under COSMIC_TEST_KEY=declared, which
  # cosmic_ci/orchestration.tl sets) -- and none in a manual or
  # scheduled run.
  # The portable suite keeps its own file beside this one
  # (`suite_verdicts`), in the same cache.
  echo "COSMIC_VERDICT_CACHE=$RUNNER_TEMP/verdicts/verdicts.db" >> "$GITHUB_ENV"
  # The compiles and parses every build of the leg shares
  # (build/shared_compiles.tl), in a cache of their own that ci.yml
  # restores before the leg's builds and saves after them, trimmed to
  # what the run used; the fixtures, which check what a fresh tree
  # compiles, share none
  # (cosmic_ci/orchestration.tl's `fixture`).
  echo "COSMIC_BUILD_CACHE=$RUNNER_TEMP/build-cache/cache.db" >> "$GITHUB_ENV"
fi
