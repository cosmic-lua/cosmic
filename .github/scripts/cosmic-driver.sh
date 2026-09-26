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
  # outside the checkout, as is the project cache (below).
  echo "COSMIC_ZIG_GLOBAL_CACHE=$RUNNER_TEMP/zig-build/zig-global" >> "$GITHUB_ENV"
  # Where ci.yml restored the zig-build cache, whose zig-cache the
  # driver's builds use in place. Spelled from $RUNNER_TEMP, not
  # `runner.temp`: in the alpine job container the expression is
  # the host's path, which does not exist there, so the seed was
  # never found and that leg recompiled vendor/ and core/ each run.
  echo "COSMIC_ZIG_CACHE_SEED=$RUNNER_TEMP/zig-build" >> "$GITHUB_ENV"
  # The test verdicts every checkout shares (build/shared_verdicts.tl),
  # kept in the zig-build cache so a run starts from the last saved
  # one's. One stands only where its whole key -- the test, what it
  # loads, the runtime, every file and variable it read -- is reached
  # again, and the driver's --all runs every test no key can hold.
  # CI stands only on what it runs itself (COSMIC_TEST_NO_SHARED=1),
  # while still writing what it reaches, so the cache is warm
  # when that changes; doc/design.md's "before CI stands on
  # shared verdicts" is the checklist.
  # TODO: stand on shared verdicts in CI (drop COSMIC_TEST_NO_SHARED
  # here and in ci/cosmic_ci/orchestration.tl) once the key holds a
  # stat's times and inode where a test turns on them without declaring
  # it (the TODO above build/test.tl's `held_stat`), a tree digest (the
  # TODO above core/syscalls_fs.c's `tree_digest`), a database a
  # connection opened before the test reads (the TODO above
  # build/filesystem_observations.tl's `start`), a read resolved by the
  # call itself (the TODO above core/observed.c's `log_resolution`), a
  # file SQLite opens resolved as it opens it (the TODO above
  # build/filesystem_observations.tl's `drain_sqlite`) and an in-tree
  # path that crosses a link out (the TODO above build/test.tl's
  # `under_root`).
  echo "COSMIC_TEST_NO_SHARED=1" >> "$GITHUB_ENV"
  # TODO: save what the product suite from fresh tracked source
  # reaches too: it runs after the zig-build cache is saved, so
  # its verdicts never reach a later run, and it runs every test.
  echo "COSMIC_VERDICT_CACHE=$RUNNER_TEMP/zig-build/verdicts.db" >> "$GITHUB_ENV"
fi
