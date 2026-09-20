#!/bin/sh
# Exercise runtime-v2 verdict isolation with one work database and real cores.
set -eu

fixture=${1:?usage: identity_test.sh RUNTIME_FIXTURE_DIRECTORY [PROJECT_STATE]}
case $fixture in /*) ;; *) fixture=$PWD/$fixture ;; esac
state=${2-}
work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-runtime-identity.XXXXXXXX")
cleanup() {
  status=$?
  trap - EXIT
  if [ "$status" -ne 0 ]; then
    for diagnostic in "$work"/*.out "$work"/*.err; do
      if [ -s "$diagnostic" ]; then
        printf '%s:\n' "$diagnostic" >&2
        cat "$diagnostic" >&2
      fi
    done
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 126' HUP INT TERM

project=$work/project
if [ -n "$state" ]; then
  case $state in /*) ;; *) state=$PWD/$state ;; esac
  cp -R "$state" "$project"
else
  mkdir -p "$project/cmd/hello"
  cp "$fixture/runtime_test.tl.in" "$project/runtime_test.tl"
  cp "$fixture/hello_main.tl.in" "$project/cmd/hello/main.tl"
fi
counter=$project/test-runs
cache=$work/cache

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then value=$(sha256sum "$1")
  else value=$(shasum -a 256 "$1"); fi
  printf '%s\n' "${value%% *}"
}

expect_tally() {
  output=$1
  ran=$2
  stood=$3
  grep -F "test: PASS (1 tests, 1 modules; $ran ran, $stood stood)" \
    "$output" >/dev/null
}

run_release() {
  artifact=$1
  output=$2
  (
    cd "$project"
    COSMIC_PORTABLE_CACHE="$cache" COSMIC_FIXTURE_COUNTER="$counter" \
      "$artifact" test
  ) > "$output" 2>&1
}

entry_fields() {
  python3 - "$1" "$2" "$3" <<'PY'
import struct
import sys
path, wanted_target, wanted_configuration = sys.argv[1:]
wanted_target = int(wanted_target)
wanted_configuration = int(wanted_configuration)
with open(path, "rb") as source:
    data = source.read()
trailer = data[-48:]
if trailer[:8] != b"CosmicT1":
    raise SystemExit("identity fixture: trailer is missing")
manifest_offset = struct.unpack(">Q", trailer[16:24])[0]
manifest = data[manifest_offset:manifest_offset + 4096]
count = struct.unpack(">I", manifest[24:28])[0]
for index in range(count):
    entry = manifest[32 + index * 56:32 + (index + 1) * 56]
    target, configuration, offset, length = struct.unpack(">IIQQ", entry[:24])
    if target == wanted_target and configuration == wanted_configuration:
        print(offset, length, entry[24:56].hex())
        break
else:
    raise SystemExit("identity fixture: selected manifest entry is missing")
PY
}

run_sanitized() {
  artifact=$fixture/runtime.sanitized
  target_id=$(cat "$fixture/sanitized-target-id")
  core_name=$(cat "$fixture/sanitized-core-name")
  core=$fixture/sanitized-cores/$core_name/cosmic-core
  set -- $(entry_fields "$artifact" "$target_id" 2)
  offset=$1
  length=$2
  digest=$3
  chmod 755 "$core"
  (
    cd "$project"
    exec 8<"$artifact"
    exec 9<"$core"
    COSMIC_FIXTURE_COUNTER="$counter" \
    COSMIC_PORTABLE_ARTIFACT_FD=8 COSMIC_PORTABLE_CORE_FD=9 \
    COSMIC_PORTABLE_TARGET_ID="$target_id" \
    COSMIC_PORTABLE_CONFIGURATION_ID=2 \
    COSMIC_PORTABLE_CORE_OFFSET="$offset" \
    COSMIC_PORTABLE_CORE_LENGTH="$length" \
    COSMIC_PORTABLE_CORE_SHA256="$digest" \
      "$core" --artifact "$artifact" test
  ) > "$work/sanitized.out" 2>&1
}

# The target overlay fixes the old missing-host failure. Step 7 has not yet
# migrated embedding, so the expected boundary is the absent legacy image.
if [ -z "$state" ]; then
  set +e
  (
    cd "$project"
    COSMIC_PORTABLE_CACHE="$cache" "$fixture/runtime.old" build
  ) > "$work/build.out" 2>&1
  build_status=$?
  set -e
  [ "$build_status" -eq 1 ]
  grep -F 'this binary carries no image for ' "$work/build.out" >/dev/null
  grep -F 'build: FAIL' "$work/build.out" >/dev/null

  run_release "$fixture/runtime.old" "$work/release.out"
  expect_tally "$work/release.out" 1 0
  run_release "$fixture/runtime.old" "$work/unchanged.out"
  expect_tally "$work/unchanged.out" 0 1

  # These artifact bytes have a different application DB and prefix padding,
  # but exactly the same selected raw core and runtime basis.
  run_release "$fixture/runtime.new" "$work/application.out"
  expect_tally "$work/application.out" 0 1

  # A project database is searched ahead of the binary after attachment. Its
  # rows must not override validated portable context or the binary's basis.
  python3 - "$project/o/cosmic.db" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
for key, value in (
    ("host", "spoofed"), ("host_image", "spoofed"),
    ("runtime", "f" * 64), ("runtime_basis", "spoofed"),
    ("artifact", "/spoofed"), ("runtime_context", "legacy-spoof")):
    db.execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
               (key, value))
db.commit()
db.close()
PY

  run_release "$fixture/runtime.basis" "$work/basis.out"
  expect_tally "$work/basis.out" 1 0
  run_sanitized
  expect_tally "$work/sanitized.out" 1 0

  python3 - "$project/o/build.db" "$counter" <<'PY'
import sqlite3
import sys
db = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
keys = db.execute("SELECT key FROM verdicts ORDER BY key").fetchall()
db.close()
with open(sys.argv[2], encoding="utf-8") as source:
    lines = [line.rstrip("\n") for line in source]
if len(keys) != 3 or len(lines) != 3 or len(set(lines)) != 3:
    raise SystemExit("identity fixture: expected three distinct runtime verdicts")
PY

  missing=$work/missing-project
  mkdir -p "$missing"
  cp "$fixture/runtime_test.tl.in" "$missing/runtime_test.tl"
  set +e
  (
    cd "$missing"
    COSMIC_PORTABLE_CACHE="$work/missing-cache" \
    COSMIC_FIXTURE_COUNTER="$missing/counter" \
      "$fixture/runtime.missing" test
  ) > "$work/missing.out" 2>&1
  missing_status=$?
  set -e
  [ "$missing_status" -eq 1 ]
  grep -F 'the running binary names no runtime identity' \
    "$work/missing.out" >/dev/null
  [ ! -e "$missing/counter" ]
else
  # Cross-host CI transports this exact directory. Each actual host selects a
  # different release core from the unchanged artifact, so the new context
  # must run once and its immediate repeat must stand.
  projection_before=$(sha_of "$project/o/cosmic.db")
  run_release "$fixture/runtime.old" "$work/transported.out"
  expect_tally "$work/transported.out" 1 0
  run_release "$fixture/runtime.old" "$work/transported-repeat.out"
  expect_tally "$work/transported-repeat.out" 0 1
  [ "$(sha_of "$project/o/cosmic.db")" = "$projection_before" ]
fi

if [ -n "${COSMIC_PORTABLE_IDENTITY_STATE_OUT-}" ]; then
  mkdir -p "$COSMIC_PORTABLE_IDENTITY_STATE_OUT"
  cp -R "$project/." "$COSMIC_PORTABLE_IDENTITY_STATE_OUT/"
fi

printf 'portable identity: PASS (real target/core/configuration/basis contexts; unchanged and app-only contexts stand)\n'
