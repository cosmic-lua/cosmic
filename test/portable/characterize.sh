#!/bin/sh
# Characterize the packed prototype's missing runtime identity. The fixture
# sources use .tl.in so the repository's own compiler never stages them.
set -eu

artifact=${1:?usage: test/portable/characterize.sh /absolute/path/to/portable-cosmic}
case $artifact in
  /*) ;;
  *) printf 'portable characterization: artifact path must be absolute\n' >&2; exit 2;;
esac

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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
runtime=$(python3 - "$artifact" "$work/embedded.db" <<'PY'
import sqlite3
import struct
import sys

artifact = sys.argv[1]
with open(artifact, "rb") as source:
    data = source.read()
marker = b"Start-Of-Cosmic--"
trailer = len(marker) + 8
if len(data) < trailer or data[-trailer:-8] != marker:
    raise SystemExit("portable characterization: prototype trailer is missing")
offset = struct.unpack(">Q", data[-8:])[0]
if offset >= len(data) - trailer:
    raise SystemExit("portable characterization: prototype database range is invalid")
database = sys.argv[2]
with open(database, "wb") as output:
    output.write(data[offset:-trailer])
try:
    connection = sqlite3.connect("file:" + database + "?mode=ro", uri=True)
    row = connection.execute("SELECT value FROM meta WHERE key = 'runtime'").fetchone()
    connection.close()
finally:
    import os
    os.unlink(database)
print("<missing>" if row is None else row[0])
PY
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

python3 - "$work/project/o/build.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
rows = connection.execute("SELECT key FROM verdicts").fetchall()
connection.close()
if rows:
    raise SystemExit("portable characterization: missing runtime wrote a verdict")
PY
run_test "$work/test-b.out"
[ ! -e "$counter" ]

printf 'portable characterization: PASS (legacy prototype build lacks host; missing runtime %s is rejected before verdict)\n' \
  "$runtime"
