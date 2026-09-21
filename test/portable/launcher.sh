#!/bin/sh
# Builds and exercises the shell launcher contract fixture.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/test/portable/lib.sh"

verb=${1-}
case "$verb" in
  build|test) shift ;;
  *)
    echo "usage: launcher.sh {build|test} ARGS..." >&2
    echo "  launcher.sh build OUTPUT_DIRECTORY" >&2
    echo "  launcher.sh test TEST_ARTIFACT [SOCKET_HELPER]" >&2
    exit 2
    ;;
esac

if [ "$verb" = build ]; then
  # Build one identical launcher fixture containing a native TEST payload for
  # every generated target. The fixture verifies only the shell launcher
  # contract.
  out=${1:?usage: launcher.sh build OUTPUT_DIRECTORY}
  mkdir -p "$out/payloads"
  tab=$(printf '\t')
  while IFS="$tab" read -r target_id configuration_id configuration target uname_os uname_arch; do
    [ "$configuration" = release ]
    timing_run "launcher payload compilation: $target" \
      "$root/bin/zig" cc -target "$target" -O2 -std=c11 -Wall -Wextra -Werror \
      "$root/test/portable/launcher_payload.c" -o "$out/payloads/payload-$target"
    timing_run "launcher socket compilation: $target" \
      "$root/bin/zig" cc -target "$target" -O2 -std=c11 -Wall -Wextra -Werror \
      "$root/test/portable/launcher_socket_fd.c" -o "$out/payloads/socket-$target"
  done < "$root/o/targets.tsv"

  timing_run 'launcher fixture writing' \
    "$root/o/bin/cosmic" "$root/test/portable/tool.tl" write-launcher-fixture \
    "$root/o/targets.tsv" "$out/payloads" "$out/launcher"
  chmod 755 "$out/launcher.release" "$out/launcher.test"
  for kind in release test; do
    dd if="$out/launcher.$kind" of="$out/launcher.$kind.header" \
      bs=16384 count=1 2>/dev/null
    /bin/sh -n "$out/launcher.$kind.header"
  done
  if grep -a -q 'COSMIC_PORTABLE_TEST_' "$out/launcher.release"; then
    echo 'release launcher contains fixture hook names' >&2
    exit 1
  fi
  grep -a -q 'COSMIC_PORTABLE_TEST_' "$out/launcher.test"
  printf 'portable launcher build: PASS (three native TEST payloads, release shell has no hooks)\n'
  exit 0
fi

# verb = test. Focused integration coverage for the production portable
# shell launcher.
artifact_input=${1:?usage: launcher.sh test TEST_ARTIFACT [SOCKET_HELPER]}
socket_helper=${2-}
case $artifact_input in /*) ;; *) artifact_input=$PWD/$artifact_input ;; esac
if [ -n "$socket_helper" ]; then
  case $socket_helper in /*) ;; *) socket_helper=$PWD/$socket_helper ;; esac
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-launcher.XXXXXXXX")
noexec_root=
cleanup() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    for diagnostic in "$work"/*.err; do
      if [ -s "$diagnostic" ]; then
        printf '%s:\n' "$diagnostic" >&2
        cat "$diagnostic" >&2
      fi
    done
  fi
  chmod -R u+w "$work" 2>/dev/null || :
  if [ -n "$noexec_root" ]; then rm -rf "$noexec_root"; fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 126' HUP INT TERM

mkdir -p "$work/program space" "$work/run space"
ln -s "$work/run space" "$work/run alias"
artifact=$work/program\ space/launcher.test
cp "$artifact_input" "$artifact"
chmod 755 "$artifact"
artifact_before=$(sha256_of "$artifact")
ordinary='PORTABLE_ORDINARY_ENV=preserved'
caller_umask=$(umask)
PORTABLE_CALLER_LOCALE=preserved
export PORTABLE_CALLER_LOCALE

mode_of() {
  case $(uname -s) in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' -- "$1" ;;
  esac
}
mtime_of() {
  case $(uname -s) in
    Darwin) stat -f '%m' "$1" ;;
    *) stat -c '%Y' -- "$1" ;;
  esac
}
core_in() {
  find "$1" -type f ! -name '.*' -print
}
run_plain() {
  portable_run_cache=$1
  shift
  env "$ordinary" COSMIC_PORTABLE_CACHE="$portable_run_cache" "$artifact" "$@"
}
expect_failure() {
  pattern=$1
  failure_cache=$2
  program=${3:-$artifact}
  set +e
  env "$ordinary" COSMIC_PORTABLE_CACHE="$failure_cache" "$program" > "$work/fail.out" 2> "$work/fail.err"
  status=$?
  set -e
  [ "$status" -ne 0 ]
  grep -q "$pattern" "$work/fail.err"
}

# Cold execution preserves cwd, streams, environment, empty/space arguments,
# and PID; a warm read-only launch changes no cache mtime or bytes.
basic_cache="$work/cache \\ override"
marker=$work/basic.marker
printf 'input stays intact\n' > "$work/input"
cd "$work/run alias"
env "$ordinary" COSMIC_PORTABLE_CACHE="$basic_cache" \
  PORTABLE_PAYLOAD_MARKER="$marker" PORTABLE_EXPECT_CWD="$PWD" \
  PORTABLE_EXPECT_UMASK="$caller_umask" PORTABLE_CHECK_IO=1 \
  "$artifact" 'a b' '' --literal \
  < "$work/input" > "$work/basic.out" 2> "$work/basic.err" &
launcher_pid=$!
wait "$launcher_pid"
grep -q "^pid=$launcher_pid$" "$work/basic.out"
grep -q '^args=a b||--literal$' "$work/basic.out"
grep -q '^payload stderr$' "$work/basic.err"
[ "$(wc -l < "$marker")" -eq 1 ]
[ "$(mode_of "$basic_cache")" = 700 ]
core=$(core_in "$basic_cache")
[ -n "$core" ]
[ "$(mode_of "$core")" = 500 ]
core_hash=$(sha256_of "$core")
cache_mtime=$(mtime_of "$basic_cache")
core_mtime=$(mtime_of "$core")
chmod 500 "$basic_cache"
run_plain "$basic_cache" > "$work/warm.out" 2> "$work/warm.err"
[ "$(mode_of "$basic_cache")" = 500 ]
[ "$(mtime_of "$basic_cache")" = "$cache_mtime" ]
[ "$(mtime_of "$core")" = "$core_mtime" ]
[ "$(sha256_of "$core")" = "$core_hash" ]
chmod 700 "$basic_cache"

# Default paths: absolute XDG wins; relative XDG falls back to an absolute
# HOME; platform HOME defaults differ. Empty/relative overrides are errors.
home=$work/home
xdg=$work/xdg
mkdir -p "$home" "$xdg"
env -u COSMIC_PORTABLE_CACHE -u XDG_CACHE_HOME HOME="$home" "$ordinary" \
  "$artifact" > /dev/null
case $(uname -s) in
  Darwin) default_cache=$home/Library/Caches/cosmic/cores ;;
  *) default_cache=$home/.cache/cosmic/cores ;;
esac
[ -d "$default_cache" ]
[ "$(mode_of "$default_cache")" = 700 ]
env -u COSMIC_PORTABLE_CACHE XDG_CACHE_HOME="$xdg" HOME="$home" "$ordinary" \
  "$artifact" > /dev/null
[ -d "$xdg/cosmic/cores" ]
relative_home=$work/relative-home
mkdir -p "$relative_home"
env -u COSMIC_PORTABLE_CACHE XDG_CACHE_HOME=relative HOME="$relative_home" "$ordinary" \
  "$artifact" > /dev/null
set +e
env COSMIC_PORTABLE_CACHE= "$ordinary" "$artifact" > /dev/null 2> "$work/empty.err"
empty_status=$?
env COSMIC_PORTABLE_CACHE=relative "$ordinary" "$artifact" > /dev/null 2> "$work/relative.err"
relative_status=$?
env -u COSMIC_PORTABLE_CACHE XDG_CACHE_HOME=relative HOME=relative "$ordinary" \
  "$artifact" > /dev/null 2> "$work/home.err"
home_status=$?
env -u COSMIC_PORTABLE_CACHE -u XDG_CACHE_HOME -u HOME "$ordinary" \
  "$artifact" > /dev/null 2> "$work/unset-home.err"
unset_home_status=$?
set -e
[ "$empty_status" -ne 0 ]
grep -q 'must be an absolute path' "$work/empty.err"
[ "$relative_status" -ne 0 ]
grep -q 'must be an absolute path' "$work/relative.err"
[ "$home_status" -ne 0 ]
grep -q 'no absolute HOME' "$work/home.err"
[ "$unset_home_status" -ne 0 ]
grep -q 'no absolute HOME' "$work/unset-home.err"

# Leaf policy rejects symlinks, unsafe modes, and a different owner when this
# runner can create one. A 0500 cache without the selected core fails clearly.
mkdir "$work/leaf-target"
ln -s "$work/leaf-target" "$work/leaf-link"
expect_failure 'symbolic link' "$work/leaf-link"
expect_failure 'symbolic link' "$work/leaf-link/"
expect_failure 'symbolic link' "$work/leaf-link////"
mkdir "$work/mode-cache"
chmod 755 "$work/mode-cache"
expect_failure 'mode must be 0700 or 0500' "$work/mode-cache"
mkdir "$work/cold-read-only"
chmod 500 "$work/cold-read-only"
expect_failure 'cache is read-only' "$work/cold-read-only"
if [ "$(id -u)" -eq 0 ] && command -v chown >/dev/null 2>&1; then
  mkdir "$work/wrong-owner"
  chown 1 "$work/wrong-owner" 2>/dev/null || :
  if [ "$(case $(uname -s) in Darwin) stat -f '%u' "$work/wrong-owner";; *) stat -c '%u' "$work/wrong-owner";; esac)" != 0 ]; then
    expect_failure 'different owner' "$work/wrong-owner"
  fi
fi

# Entry lstat checks never follow a symlink. Invalid mode, size, digest, and an
# empty directory are removed before lock-free publication; the symlink target
# remains untouched.
key=$(basename "$core")
sentinel=$work/sentinel
printf 'untouched\n' > "$sentinel"
mkdir "$work/symlink-cache"
chmod 700 "$work/symlink-cache"
ln -s "$sentinel" "$work/symlink-cache/$key"
run_plain "$work/symlink-cache" > /dev/null 2> "$work/symlink-repair.err"
[ "$(cat "$sentinel")" = untouched ]
[ ! -L "$work/symlink-cache/$key" ]
grep -q 'symbolic link; repairing' "$work/symlink-repair.err"
mkdir "$work/directory-cache" "$work/directory-cache/$key"
chmod 700 "$work/directory-cache"
run_plain "$work/directory-cache" > /dev/null 2> "$work/directory-repair.err"
[ -f "$work/directory-cache/$key" ]
mkdir "$work/entry-mode-cache"
chmod 700 "$work/entry-mode-cache"
cp "$core" "$work/entry-mode-cache/$key"
chmod 700 "$work/entry-mode-cache/$key"
run_plain "$work/entry-mode-cache" > /dev/null 2> "$work/entry-mode.err"
grep -q 'mode is not 0500; repairing' "$work/entry-mode.err"
chmod 700 "$core"
printf Z | dd of="$core" bs=1 seek=0 conv=notrunc 2>/dev/null
chmod 500 "$core"
chmod 500 "$basic_cache"
set +e
env "$ordinary" COSMIC_PORTABLE_CACHE="$basic_cache" \
  PORTABLE_PAYLOAD_MARKER="$work/read-only-corrupt.marker" "$artifact" \
  > /dev/null 2> "$work/read-only-corrupt.err"
read_only_corrupt_status=$?
set -e
[ "$read_only_corrupt_status" -ne 0 ]
[ ! -e "$work/read-only-corrupt.marker" ]
grep -q 'digest differs and cache is read-only' "$work/read-only-corrupt.err"
chmod 700 "$basic_cache"
run_plain "$basic_cache" > /dev/null 2> "$work/warm-corrupt.err"
grep -q 'digest differs; repairing' "$work/warm-corrupt.err"
[ "$(sha256_of "$core")" = "$core_hash" ]
chmod 700 "$core"
dd if="$core" of="$work/short-core" bs=1 count=20 2>/dev/null
cat "$work/short-core" > "$core"
chmod 500 "$core"
run_plain "$basic_cache" > /dev/null 2> "$work/warm-short.err"
grep -q 'length differs; repairing' "$work/warm-short.err"

# Artifact truncation and equal-length corruption are distinct cold failures.
host=$(uname -s):$(uname -m)
selected=$(dd if="$artifact" bs=16384 count=1 2>/dev/null | grep "^  $host)")
offset=$(printf '%s\n' "$selected" | sed 's/.*cosmic_offset=\([0-9][0-9]*\);.*/\1/')
length=$(printf '%s\n' "$selected" | sed 's/.*cosmic_length=\([0-9][0-9]*\);.*/\1/')
dd if="$artifact" of="$work/truncated" bs=1 count=$((offset + length - 1)) 2>/dev/null
chmod 755 "$work/truncated"
expect_failure 'extracted core is truncated' "$work/truncated-cache" "$work/truncated"
cp "$artifact" "$work/equal-corrupt"
printf Z | dd of="$work/equal-corrupt" bs=1 seek="$offset" conv=notrunc 2>/dev/null
chmod 755 "$work/equal-corrupt"
expect_failure 'extracted core digest differs' "$work/equal-cache" "$work/equal-corrupt"

# Two cold publishers are stopped at the fixture-only gate, then released.
# Hard-link publication leaves one verified winner and no private stage files.
race=$work/race-cache
for n in 1 2; do mkfifo "$work/ready$n" "$work/go$n"; done
env "$ordinary" COSMIC_PORTABLE_CACHE="$race" COSMIC_PORTABLE_TEST_HOOK=before_publish \
  COSMIC_PORTABLE_TEST_READY="$work/ready1" COSMIC_PORTABLE_TEST_GO="$work/go1" \
  "$artifact" > "$work/race1.out" 2> "$work/race1.err" & race1=$!
IFS= read -r ready < "$work/ready1"
env "$ordinary" COSMIC_PORTABLE_CACHE="$race" COSMIC_PORTABLE_TEST_HOOK=before_publish \
  COSMIC_PORTABLE_TEST_READY="$work/ready2" COSMIC_PORTABLE_TEST_GO="$work/go2" \
  "$artifact" > "$work/race2.out" 2> "$work/race2.err" & race2=$!
IFS= read -r ready < "$work/ready2"
printf 'go\n' > "$work/go1" & release1=$!
printf 'go\n' > "$work/go2" & release2=$!
wait "$release1"
wait "$release2"
wait "$race1"
wait "$race2"
[ "$(core_in "$race" | wc -l)" -eq 1 ]
[ "$(find "$race" -name '.core.*' -o -name '.repair-*' | wc -l)" -eq 0 ]

# Publisher and repair-lock interruption both clean private names. The next
# launch succeeds without manual cleanup. FIFO synchronization uses no sleeps.
interrupted=$work/interrupted-cache
mkfifo "$work/interrupt-ready" "$work/interrupt-go"
env "$ordinary" COSMIC_PORTABLE_CACHE="$interrupted" COSMIC_PORTABLE_TEST_HOOK=before_publish \
  COSMIC_PORTABLE_TEST_READY="$work/interrupt-ready" \
  COSMIC_PORTABLE_TEST_GO="$work/interrupt-go" "$artifact" > /dev/null 2> "$work/interrupted.err" & interrupted_pid=$!
IFS= read -r ready < "$work/interrupt-ready"
kill -TERM "$interrupted_pid"
set +e; wait "$interrupted_pid"; interrupted_status=$?; set -e
[ "$interrupted_status" -ne 0 ]
[ "$(find "$interrupted" -name '.core.*' | wc -l)" -eq 0 ]
run_plain "$interrupted" > /dev/null
interrupted_core=$(core_in "$interrupted")
chmod 700 "$interrupted_core"
printf Z | dd of="$interrupted_core" bs=1 seek=0 conv=notrunc 2>/dev/null
chmod 500 "$interrupted_core"
mkfifo "$work/repair-ready" "$work/repair-go"
env "$ordinary" COSMIC_PORTABLE_CACHE="$interrupted" COSMIC_PORTABLE_TEST_HOOK=after_repair_lock \
  COSMIC_PORTABLE_TEST_READY="$work/repair-ready" COSMIC_PORTABLE_TEST_GO="$work/repair-go" \
  "$artifact" > /dev/null 2> "$work/repair-interrupted.err" & repair_pid=$!
IFS= read -r ready < "$work/repair-ready"
kill -TERM "$repair_pid"
set +e; wait "$repair_pid"; repair_status=$?; set -e
[ "$repair_status" -ne 0 ]
[ "$(find "$interrupted" -name '.repair-*' | wc -l)" -eq 0 ]
run_plain "$interrupted" > /dev/null 2> "$work/repair-next.err"

# SIGKILL cannot run a shell trap. A left repair-owner file therefore causes a
# bounded diagnostic naming the exact private path; the launcher never guesses
# that the lock is stale and races a replacement owner.
chmod 700 "$interrupted_core"
printf Z | dd of="$interrupted_core" bs=1 seek=0 conv=notrunc 2>/dev/null
chmod 500 "$interrupted_core"
mkfifo "$work/kill-ready" "$work/kill-go"
env "$ordinary" COSMIC_PORTABLE_CACHE="$interrupted" COSMIC_PORTABLE_TEST_HOOK=after_repair_lock \
  COSMIC_PORTABLE_TEST_READY="$work/kill-ready" COSMIC_PORTABLE_TEST_GO="$work/kill-go" \
  "$artifact" > /dev/null 2> "$work/repair-killed.err" & killed_pid=$!
IFS= read -r ready < "$work/kill-ready"
kill -KILL "$killed_pid"
set +e; wait "$killed_pid" 2>/dev/null; killed_status=$?; set -e
[ "$killed_status" -ne 0 ]
expect_failure 'cache repair is already locked:' "$interrupted"
stale_lock=$(find "$interrupted" -name '.repair-*' -type f)
[ -n "$stale_lock" ]
rm -f "$stale_lock"
run_plain "$interrupted" > /dev/null 2> "$work/repair-after-stale.err"

# Caller read, write, and socket descriptors are preserved simultaneously,
# including the old fixed 8/9 pair; the launcher chooses two other slots.
guard=$work/caller-write.guard
if [ -n "$socket_helper" ]; then
  chmod 755 "$socket_helper"
  (
    exec 3< "$artifact"
    exec 8> "$guard"
    printf 'before\n' >&8
    env "$ordinary" COSMIC_PORTABLE_CACHE="$work/mixed-fd-cache" \
      "$socket_helper" 9 "$artifact" > /dev/null
    printf 'after\n' >&8
  )
  [ "$(cat "$guard")" = "before
after" ]
fi

# Descriptor exhaustion is diagnosed before opening the artifact or creating a
# cache. Both the one-free and zero-free cases leave caller guards usable.
one_guard=$work/one-free.guard
set +e
(
  exec 3< "$artifact" 4< "$artifact" 5< "$artifact" 6< "$artifact"
  exec 7< "$artifact" 8> "$one_guard"
  printf 'before\n' >&8
  env "$ordinary" COSMIC_PORTABLE_CACHE="$work/one-free-cache" "$artifact" \
    > /dev/null 2> "$work/one-free.err"
  result=$?
  printf 'after\n' >&8
  exit "$result"
)
one_free_status=$?
set -e
[ "$one_free_status" -ne 0 ]
grep -q 'fewer than two private descriptors are available in 3 through 9' \
  "$work/one-free.err"
[ "$(cat "$one_guard")" = "before
after" ]
[ ! -e "$work/one-free-cache" ]

zero_guard=$work/zero-free.guard
set +e
(
  exec 3< "$artifact" 4< "$artifact" 5< "$artifact" 6< "$artifact"
  exec 7< "$artifact" 8< "$artifact" 9> "$zero_guard"
  printf 'before\n' >&9
  env "$ordinary" COSMIC_PORTABLE_CACHE="$work/zero-free-cache" "$artifact" \
    > /dev/null 2> "$work/zero-free.err"
  result=$?
  printf 'after\n' >&9
  exit "$result"
)
zero_free_status=$?
set -e
[ "$zero_free_status" -ne 0 ]
grep -q 'fewer than two private descriptors are available in 3 through 9' \
  "$work/zero-free.err"
[ "$(cat "$zero_guard")" = "before
after" ]
[ ! -e "$work/zero-free-cache" ]

# Nonzero exit and signal each append one marker and are never retried.
exit_marker=$work/exit.marker
set +e
env "$ordinary" COSMIC_PORTABLE_CACHE="$basic_cache" PORTABLE_PAYLOAD_MARKER="$exit_marker" \
  PORTABLE_PAYLOAD_EXIT=23 "$artifact" > /dev/null
exit_status=$?
set -e
[ "$exit_status" -eq 23 ]
[ "$(wc -l < "$exit_marker")" -eq 1 ]
signal_marker=$work/signal.marker
set +e
env "$ordinary" COSMIC_PORTABLE_CACHE="$basic_cache" PORTABLE_PAYLOAD_MARKER="$signal_marker" \
  PORTABLE_PAYLOAD_SIGNAL=1 "$artifact" > /dev/null 2> "$work/signal.err"
signal_status=$?
set -e
[ "$signal_status" -ne 0 ]
[ "$(wc -l < "$signal_marker")" -eq 1 ]

# Exercise a noexec cache only when this host exposes one without privilege.
noexec_parent=${COSMIC_PORTABLE_NOEXEC_ROOT:-/dev/shm}
if [ "$(uname -s)" = Linux ] && [ -d "$noexec_parent" ] && [ -w "$noexec_parent" ]; then
  noexec_root=$(mktemp -d "$noexec_parent/cosmic-launcher.XXXXXXXX")
  printf '#!/bin/sh\nexit 0\n' > "$noexec_root/probe"
  chmod 700 "$noexec_root/probe"
  set +e; "$noexec_root/probe" >/dev/null 2>&1; probe_status=$?; set -e
  if [ "$probe_status" -ne 0 ]; then
    set +e
    env "$ordinary" COSMIC_PORTABLE_CACHE="$noexec_root/cache" "$artifact" \
      > /dev/null 2> "$work/noexec.err"
    noexec_status=$?
    set -e
    [ "$noexec_status" -eq 126 ]
    [ -f "$noexec_root/cache/$key" ]
    printf '%s\n' 'cosmic portable: verified core cannot execute on the cache filesystem' \
      > "$work/noexec.expected"
    cmp "$work/noexec.expected" "$work/noexec.err"
  fi
  rm -rf "$noexec_root"
  noexec_root=
fi

artifact_after=$(sha256_of "$artifact")
[ "$artifact_after" = "$artifact_before" ]

# Report cost without a pass/fail threshold. This runs on every workflow host.
timing_cache="$work/timing cache"
if [ -x /usr/bin/time ]; then
  /usr/bin/time -p env "$ordinary" COSMIC_PORTABLE_CACHE="$timing_cache" "$artifact" \
    > /dev/null 2> "$work/cold.time"
  /usr/bin/time -p env "$ordinary" COSMIC_PORTABLE_CACHE="$timing_cache" "$artifact" \
    > /dev/null 2> "$work/warm.time"
else
  timing_start=$(date +%s)
  run_plain "$timing_cache" > /dev/null
  printf 'real %s (one-second clock)\n' "$(($(date +%s) - timing_start))" > "$work/cold.time"
  timing_start=$(date +%s)
  run_plain "$timing_cache" > /dev/null
  printf 'real %s (one-second clock)\n' "$(($(date +%s) - timing_start))" > "$work/warm.time"
fi
printf 'portable launcher cold timing: '
tr '\n' ' ' < "$work/cold.time"
printf '\nportable launcher warm timing: '
tr '\n' ' ' < "$work/warm.time"
printf '\n'
printf 'portable launcher: PASS (cache policy, integrity, races, descriptors, exec semantics)\n'
