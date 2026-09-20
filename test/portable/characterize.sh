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
  target=$1
  identity=$2
  output=$3
  (
    cd "$work/project"
    COSMIC_PORTABLE_CACHE=$work/cache \
    COSMIC_FIXTURE_COUNTER=$counter \
    COSMIC_FIXTURE_TARGET=$target \
    COSMIC_FIXTURE_RUNTIME=$identity \
      "$artifact" test
  ) >"$output" 2>&1
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

run_test target-a runtime-a "$work/test-a.out"
grep -F 'test: PASS (1 tests, 1 modules; 1 ran, 0 stood)' "$work/test-a.out" >/dev/null
[ "$(cat "$counter")" = 'target-a runtime-a' ]

first_verdict=$(python3 - "$work/project/o/build.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
rows = connection.execute(
    "SELECT key, passed, run_at_ns FROM verdicts ORDER BY key"
).fetchall()
connection.close()
if len(rows) != 1 or rows[0][1] != 1:
    raise SystemExit("portable characterization: expected one passing verdict")
print(rows[0][0] + " " + str(rows[0][2]))
PY
)

# These labels stand in for the target/runtime context that commit 6 will
# supply from the validated physical core. Today the packed binary supplies an
# empty runtime to build/test.tl, so the changed context silently reuses the
# first passing verdict and the observable test counter does not advance.
run_test target-b runtime-b "$work/test-b.out"
grep -F 'test: PASS (1 tests, 1 modules; 0 ran, 1 stood)' "$work/test-b.out" >/dev/null
[ "$(cat "$counter")" = 'target-a runtime-a' ]

second_verdict=$(python3 - "$work/project/o/build.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
rows = connection.execute(
    "SELECT key, passed, run_at_ns FROM verdicts ORDER BY key"
).fetchall()
connection.close()
if len(rows) != 1 or rows[0][1] != 1:
    raise SystemExit("portable characterization: expected one reused verdict")
print(rows[0][0] + " " + str(rows[0][2]))
PY
)
[ "$second_verdict" = "$first_verdict" ]

printf 'portable characterization: PASS (build exit 1/missing host; test 1 ran then 1 stood; runtime %s; unchanged verdict %s)\n' \
  "$runtime" "${first_verdict%% *}"
