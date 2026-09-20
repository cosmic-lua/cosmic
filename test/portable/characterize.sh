#!/bin/sh
# Characterize the packed prototype's missing runtime identity. The fixture
# sources use .tl.in so the repository's own compiler never stages them.
set -eu

artifact=${1:?usage: test/portable/characterize.sh /absolute/path/to/portable-cosmic TEAL_RUNTIME}
runtime_helper=${2:?usage: test/portable/characterize.sh /absolute/path/to/portable-cosmic TEAL_RUNTIME}
case $artifact in
  /*) ;;
  *) printf 'portable characterization: artifact path must be absolute\n' >&2; exit 2;;
esac
case $runtime_helper in
  /*) ;;
  *) printf 'portable characterization: helper runtime path must be absolute\n' >&2; exit 2;;
esac
[ -x "$runtime_helper" ] || {
  printf 'portable characterization: helper runtime is not executable: %s\n' \
    "$runtime_helper" >&2
  exit 2
}

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-portable-characterization.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/cache" "$work/project" "$work/project/cmd" "$work/project/cmd/hello"
cp "$here/fixture/runtime_test.tl.in" "$work/project/runtime_test.tl"
cp "$here/fixture/cmd/hello/main.tl.in" "$work/project/cmd/hello/main.tl"
counter=$work/test-runs

# Read the database embedded in the prototype itself, rather than trusting the
# packer's intermediate shared.db. This parser is intentionally limited to the
# current experimental 17-byte marker plus 8-byte big-endian trailer.
runtime=$(
  cd "$root"
  COSMIC_PORTABLE_CACHE="$work/helper-cache" \
    "$runtime_helper" test/portable/characterize_fixture.tl \
    runtime "$artifact" "$work/embedded.db"
)
[ "$runtime" = '<missing>' ] || {
  printf 'portable characterization: expected missing runtime metadata, got %s\n' "$runtime" >&2
  exit 1
}

run_test() {
  output=$1
  set +e
  (
    cd "$work/project"
    COSMIC_PORTABLE_CACHE=$work/cache \
    COSMIC_FIXTURE_COUNTER=$counter \
      "$artifact" test
  ) >"$output" 2>&1
  status=$?
  set -e
  [ "$status" -eq 1 ]
  grep -F 'the running binary names no runtime identity' "$output" >/dev/null
}

set +e
(
  cd "$work/project"
  COSMIC_PORTABLE_CACHE=$work/cache "$artifact" build
) >"$work/build.out" 2>&1
build_status=$?
set -e
[ "$build_status" -eq 1 ]
grep -F 'this binary names no host target' "$work/build.out" >/dev/null
grep -F 'build: FAIL' "$work/build.out" >/dev/null

run_test "$work/test-a.out"
[ ! -e "$counter" ]

(
  cd "$root"
  COSMIC_PORTABLE_CACHE="$work/helper-cache" \
    "$runtime_helper" test/portable/characterize_fixture.tl \
    verdicts "$work/project/o/build.db"
)
run_test "$work/test-b.out"
[ ! -e "$counter" ]

printf 'portable characterization: PASS (legacy prototype build lacks host; missing runtime %s is rejected before verdict)\n' \
  "$runtime"
