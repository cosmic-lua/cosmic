#!/bin/sh
# Exercise a portable Cosmic rebuilding and re-entering its own logical path.
# The supplied fixture uses the existing startup FIFO hook, compiled out of
# production cores.
set -eu

script=$(CDPATH= cd -- "$(dirname "$0")" && pwd)/self_rebuild.sh
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)

hash_value() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

cache_entries() {
  find "$1" -type f -name 'core-*' | wc -l | tr -d ' '
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
  cp "$fixture/runtime.old" "$tree/o/bin/cosmic-portable"
  chmod 755 "$tree/o/bin/cosmic-portable"
  program=$tree/o/bin/cosmic-portable
  original_hash=$(hash_value "$program")
  prefix_length=$(cat "$fixture/runtime.old.prefix-length")
  printf 'legacy output sentinel\n' > "$tree/o/bin/cosmic"
  chmod 755 "$tree/o/bin/cosmic"
  legacy_hash=$(hash_value "$tree/o/bin/cosmic")

  # The disposable edit makes the tool stale. The code reached after re-entry
  # inspects the exact arguments and an ordinary environment value.
  awk '
    { print }
    $0 == "local Time = require(\"cosmic.time\")" {
      print "local step8_sys = require(\"cosmic.sys\")"
    }
    $0 == "function test.run(argv: {integer:string}): integer" {
      print "  if step8_sys.getenv(\"COSMIC_STEP8_REENTRY\") ~= nil then"
      print "    assert(argv[1] == \"test\")"
      print "    assert(argv[2] == \"\")"
      print "    assert(argv[3] == \"argument with spaces\")"
      print "    assert(argv[4] == nil)"
      print "    assert(step8_sys.getenv(\"COSMIC_STEP8_REENTRY\") == \"kept with spaces\")"
      print "  end"
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
  grep -E 'test: PASS \([^;]+; [1-9][0-9]* ran, 0 stood\)' \
    "$case_root/rebuild.out" >/dev/null
  stale_lines=$(awk '/the tool is stale; rebuilding it from the tree/ { count++ } END { print count + 0 }' \
    "$case_root/rebuild.err")
  [ "$stale_lines" -eq 1 ]
  if grep -F 'the tool is still stale after a reboot' \
      "$case_root/rebuild.err" >/dev/null; then
    exit 1
  fi
  cmp -n "$prefix_length" "$fixture/runtime.old.prefix" "$program"
  entries_after=$(cache_entries "$cache")
  [ "$entries_after" -eq "$entries_before" ]
  [ "$(hash_value "$program")" != "$original_hash" ]
  [ "$(hash_value "$tree/o/bin/cosmic")" = "$legacy_hash" ]

  # A core input cannot be represented by a database-only rebuild.
  printf '\n/* step-8 core-change fixture */\n' >> "$tree/core/startup.h"
  before_refusal=$(hash_value "$program")
  set +e
  (
    cd "$tree"
    COSMIC_PORTABLE_CACHE="$cache" "$program" test
  ) > "$case_root/core.out" 2> "$case_root/core.err"
  core_status=$?
  set -e
  [ "$core_status" -eq 3 ]
  grep -F 'the tool is stale; run bin/zig build boot' \
    "$case_root/core.err" >/dev/null
  [ "$(hash_value "$program")" = "$before_refusal" ]
  [ "$(hash_value "$tree/o/bin/cosmic")" = "$legacy_hash" ]
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

run_bounded_case() {
  action=$1
  mkdir "$work/$action"
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$script" --case "$action" "$fixture" "$work/$action"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 30 "$script" --case "$action" "$fixture" "$work/$action"
  elif [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::notice::timeout is unavailable; the $action self-rebuild case runs under the existing job bound"
    "$script" --case "$action" "$fixture" "$work/$action"
  else
    echo "timeout or gtimeout is required outside GitHub Actions" >&2
    return 125
  fi
}

run_bounded_case rename
run_bounded_case unlink

printf 'portable self-rebuild: PASS (one re-entry, exact argv/env, retained prefix after rename/unlink, one cache entry, legacy preserved, core refusal)\n'
