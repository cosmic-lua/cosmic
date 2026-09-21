#!/bin/sh
# Exercise a portable Cosmic rebuilding and re-entering its own logical path.
# The supplied fixture uses the existing startup FIFO hook, compiled out of
# production cores.
set -eu

script=$(CDPATH= cd -- "$(dirname "$0")" && pwd)/self_rebuild.sh
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

. "$root/test/portable/lib.sh"

cache_entries() {
  find "$1" -type f -name 'core-*' | wc -l | tr -d ' '
}

file_size() {
  wc -c < "$1" | awk '{ print $1 }'
}

compare_prefix() {
  expected=$1
  program=$2
  length=$3
  extracted=$4
  case $length in
    ''|*[!0-9]*)
      printf 'portable self-rebuild: invalid prefix length: %s\n' "$length" >&2
      return 1
      ;;
  esac
  expected_size=$(file_size "$expected")
  if [ "$expected_size" -ne "$length" ]; then
    printf 'portable self-rebuild: expected prefix has %s bytes, want %s\n' \
      "$expected_size" "$length" >&2
    return 1
  fi
  # Compare equal-length files: Darwin's bounded cmp still rejects the longer
  # artifact after matching the requested bytes.
  head -c "$length" "$program" > "$extracted"
  extracted_size=$(file_size "$extracted")
  if [ "$extracted_size" -ne "$length" ]; then
    printf 'portable self-rebuild: rebuilt artifact prefix has %s bytes, want %s\n' \
      "$extracted_size" "$length" >&2
    return 1
  fi
  cmp "$expected" "$extracted"
}

if [ "${1-}" = --case ]; then
  action=${2:?internal usage: --case ACTION FIXTURE CASE-DIRECTORY}
  fixture=${3:?internal usage: --case ACTION FIXTURE CASE-DIRECTORY}
  case_root=${4:?internal usage: --case ACTION FIXTURE CASE-DIRECTORY}
  rebuild_pid=
  release_pid=
  cleanup_case() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$release_pid" ]; then
      kill "$release_pid" 2>/dev/null || :
      wait "$release_pid" 2>/dev/null || :
    fi
    if [ -n "$rebuild_pid" ]; then
      kill "$rebuild_pid" 2>/dev/null || :
      wait "$rebuild_pid" 2>/dev/null || :
    fi
    exit "$status"
  }
  trap cleanup_case EXIT
  trap 'exit 126' HUP INT TERM

  tree=$case_root/tree
  cache=$case_root/cache
  mkdir -p "$tree/o/bin"
  git -C "$root" archive HEAD | tar -xf - -C "$tree"
  cp "$fixture/runtime.old" "$tree/o/bin/cosmic"
  chmod 755 "$tree/o/bin/cosmic"
  program=$tree/o/bin/cosmic
  original_hash=$(sha256_of "$program")
  prefix_length=$(cat "$fixture/runtime.old.prefix-length")
  # The disposable edit makes the tool stale. The code reached after re-entry
  # inspects the exact arguments and an ordinary environment value.
  awk '
    { print }
    $0 == "local Time = require(\"cosmic.time\")" {
      print "local step8_sys = require(\"cosmic.sys\")"
    }
    $0 == "function test.run(argv: {integer:string}): integer" {
      print "  assert(argv[1] == \"test\")"
      print "  assert(argv[2] == \"\")"
      print "  assert(argv[3] == \"argument with spaces\")"
      print "  assert(argv[4] == nil)"
      print "  assert(step8_sys.getenv(\"COSMIC_STEP8_REENTRY\") == \"kept with spaces\")"
    }
  ' "$tree/build/test.tl" > "$tree/build/test.tl.new"
  mv "$tree/build/test.tl.new" "$tree/build/test.tl"

  ready=$case_root/ready
  go=$case_root/go
  mkfifo "$ready" "$go"
  (
    cd "$tree"
    COSMIC_PORTABLE_CACHE="$cache" \
      COSMIC_PORTABLE_STARTUP_TEST_READY="$ready" \
      COSMIC_PORTABLE_STARTUP_TEST_GO="$go" \
      COSMIC_STEP8_REENTRY="kept with spaces" \
      "$program" test "" "argument with spaces"
  ) > "$case_root/rebuild.out" 2> "$case_root/rebuild.err" &
  rebuild_pid=$!

  IFS= read -r first_ready < "$ready"
  [ "$first_ready" = ready ]
  entries_before=$(cache_entries "$cache")
  [ "$entries_before" -eq 1 ]
  if [ "$action" = rename ]; then
    mv "$program" "$case_root/adopted-artifact"
  else
    rm "$program"
  fi
  printf 'go\n' > "$go" & release_pid=$!
  wait "$release_pid"
  release_pid=

  # The rebuilt artifact starts once more at the same logical path.
  IFS= read -r second_ready < "$ready"
  [ "$second_ready" = ready ]
  printf 'go\n' > "$go" & release_pid=$!
  wait "$release_pid"
  release_pid=
  wait "$rebuild_pid"
  rebuild_pid=

  [ -x "$program" ]
  grep -E 'test: PASS \([^;]+; [1-9][0-9]* ran, 0 stood' \
    "$case_root/rebuild.out" >/dev/null
  stale_lines=$(awk '/the tool is stale; rebuilding it from the tree/ { count++ } END { print count + 0 }' \
    "$case_root/rebuild.err")
  [ "$stale_lines" -eq 1 ]
  if grep -F 'the tool is still stale after a reboot' \
      "$case_root/rebuild.err" >/dev/null; then
    exit 1
  fi
  compare_prefix "$fixture/runtime.old.prefix" "$program" "$prefix_length" \
    "$case_root/rebuilt.prefix"
  entries_after=$(cache_entries "$cache")
  [ "$entries_after" -eq "$entries_before" ]
  [ "$(sha256_of "$program")" != "$original_hash" ]

  # A core input cannot be represented by a database-only rebuild.
  printf '\n/* step-8 core-change fixture */\n' >> "$tree/core/startup.h"
  before_refusal=$(sha256_of "$program")
  set +e
  (
    cd "$tree"
    COSMIC_PORTABLE_CACHE="$cache" \
      COSMIC_STEP8_REENTRY="kept with spaces" \
      "$program" test "" "argument with spaces"
  ) > "$case_root/core.out" 2> "$case_root/core.err"
  core_status=$?
  set -e
  [ "$core_status" -eq 3 ]
  grep -F 'the tool is stale; run bin/zig build boot' \
    "$case_root/core.err" >/dev/null
  [ "$(sha256_of "$program")" = "$before_refusal" ]
  [ "$(cache_entries "$cache")" -eq "$entries_before" ]
  exit 0
fi

fixture=${1:?usage: self_rebuild.sh RUNTIME_FIXTURE_DIRECTORY}
case $fixture in /*) ;; *) fixture=$PWD/$fixture ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-portable-rebuild.XXXXXXXX")
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -eq 0 ]; then
    rm -rf "$work"
  else
    printf 'portable self-rebuild diagnostics preserved at %s\n' "$work" >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 126' HUP INT TERM

exercise_prefix_comparison() {
  comparison=$work/prefix-comparison
  mkdir "$comparison"
  printf 'abc' > "$comparison/expected"
  printf 'abc-suffix' > "$comparison/program"
  compare_prefix "$comparison/expected" "$comparison/program" 3 \
    "$comparison/extracted"

  printf 'ab' > "$comparison/program-short"
  if compare_prefix "$comparison/expected" "$comparison/program-short" 3 \
      "$comparison/extracted-short" > /dev/null 2>&1; then
    echo 'portable self-rebuild: short prefix comparison unexpectedly passed' >&2
    return 1
  fi

  printf 'axc-suffix' > "$comparison/program-mutated"
  if compare_prefix "$comparison/expected" "$comparison/program-mutated" 3 \
      "$comparison/extracted-mutated" > /dev/null 2>&1; then
    echo 'portable self-rebuild: mutated prefix comparison unexpectedly passed' >&2
    return 1
  fi
}

run_bounded_case() {
  action=$1
  mkdir "$work/$action"
  run_bounded "the $action self-rebuild case" \
    "$script" --case "$action" "$fixture" "$work/$action"
}

refusal_case() {
  name=$1
  case_root=$work/refuse-$name
  tree=$case_root/tree
  cache=$case_root/cache
  mkdir -p "$tree/o/bin"
  git -C "$root" archive HEAD | tar -xf - -C "$tree"
  cp "$fixture/runtime.old" "$tree/o/bin/cosmic"
  chmod 755 "$tree/o/bin/cosmic"
  program=$tree/o/bin/cosmic
  before=$(sha256_of "$program")
  case $name in
    tl-pin) printf '\n# refusal fixture\n' >> "$tree/vendor/tl/PIN" ;;
    tl-patch)
      mkdir -p "$tree/patch/tl"
      printf 'refusal fixture\n' > "$tree/patch/tl/refusal-fixture.patch"
      ;;
    launcher) printf '\n-- refusal fixture\n' >> "$tree/build/launcher.tl" ;;
  esac
  set +e
  (cd "$tree"; COSMIC_PORTABLE_CACHE="$cache" "$program" test) \
    > "$case_root/out" 2> "$case_root/err"
  status=$?
  set -e
  [ "$status" -eq 3 ]
  grep -F 'the tool is stale; run bin/zig build boot' "$case_root/err" >/dev/null
  [ "$(sha256_of "$program")" = "$before" ]
}

exercise_prefix_comparison
run_bounded_case rename
run_bounded_case unlink
refusal_case tl-pin
refusal_case tl-patch
refusal_case launcher

printf 'portable self-rebuild: PASS (one re-entry, exact argv/env, retained prefix after rename/unlink, one cache entry, and core/compiler/launcher refusal)\n'
