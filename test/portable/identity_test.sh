#!/bin/sh
# Exercise runtime-v2 verdict isolation with one work database and real cores.
set -eu

fixture=${1:?usage: identity_test.sh RUNTIME_FIXTURE_DIRECTORY [PROJECT_STATE]}
case $fixture in /*) ;; *) fixture=$PWD/$fixture ;; esac
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
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
  mkdir -p "$project/cmd/second"
  cat > "$project/cmd/second/main.tl" <<'TL'
return function(): integer
  print("second portable application")
  return 0
end
TL
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

if [ -z "$state" ]; then
  # Run just build/embed_test.tl under the real portable runtime. Its four
  # cases cover the explicit legacy/portable expectations without claiming
  # the full portable Cosmic suite before the step-8 reboot migration.
  focused=$work/focused-embed
  mkdir "$focused"
  cp -R "$root/build" "$focused/build"
  find "$focused" -type f -name '*_test.tl' ! -name 'embed_test.tl' \
    -exec sh -c 'for source do mv "$source" "$source.in"; done' sh {} +
  (
    cd "$focused"
    COSMIC_PORTABLE_CACHE="$cache" "$fixture/runtime.old" test
  ) > "$work/focused-embed.out" 2>&1
  grep -F 'test: PASS (4 tests, 1 modules; 4 ran, 0 stood)' \
    "$work/focused-embed.out" >/dev/null

  (
    cd "$project"
    COSMIC_PORTABLE_CACHE="$cache" "$fixture/runtime.old" build
  ) > "$work/build.out" 2>&1
  grep -F 'build: PASS (o/bin/hello, o/bin/second' "$work/build.out" >/dev/null

  prefix_length=$(cat "$fixture/runtime.old.prefix-length")
  for application in hello second; do
    output=$project/o/bin/$application
    [ -x "$output" ]
    head -c 10 "$output" | grep -F '#!/bin/sh' >/dev/null
    cmp -n "$prefix_length" "$fixture/runtime.old.prefix" "$output"
  done
  cp "$project/o/bin/hello" "$work/hello-before-edit"
  sed 's/hello from the portable fixture/hello from the edited portable fixture/' \
    "$fixture/hello_main.tl.in" > "$project/cmd/hello/main.tl"
  (
    cd "$project"
    COSMIC_PORTABLE_CACHE="$cache" "$fixture/runtime.old" build
  ) > "$work/rebuild.out" 2>&1
  grep -F 'build: PASS (o/bin/hello, o/bin/second' "$work/rebuild.out" >/dev/null
  cmp -n "$prefix_length" "$work/hello-before-edit" "$project/o/bin/hello"
  if cmp "$work/hello-before-edit" "$project/o/bin/hello" >/dev/null; then
    printf 'portable identity: application edit did not change its suffix\n' >&2
    exit 1
  fi

  # The build consumes the descriptor retained at startup, even after its
  # logical pathname is unlinked. The resulting application keeps that exact
  # prefix and executes normally.
  unlinked=$work/unlinked-runtime
  cp "$fixture/runtime.old" "$unlinked"
  chmod 755 "$unlinked"
  ready=$work/build-ready
  go=$work/build-go
  mkfifo "$ready" "$go"
  (
    cd "$project"
    COSMIC_PORTABLE_CACHE="$cache" \
    COSMIC_PORTABLE_STARTUP_TEST_READY="$ready" \
    COSMIC_PORTABLE_STARTUP_TEST_GO="$go" \
      "$unlinked" build
  ) > "$work/unlinked-build.out" 2> "$work/unlinked-build.err" &
  build_pid=$!
  IFS= read -r ignored < "$ready"
  rm "$unlinked"
  printf 'go\n' > "$go" & release_pid=$!
  wait "$release_pid"
  wait "$build_pid"
  grep -F 'build: PASS (o/bin/hello, o/bin/second' \
    "$work/unlinked-build.out" >/dev/null
  cmp -n "$prefix_length" "$fixture/runtime.old.prefix" \
    "$project/o/bin/hello"

  # Atomic replacement of the logical pathname after the same pause also
  # leaves this build on the one retained artifact.
  renamed=$work/renamed-runtime
  cp "$fixture/runtime.old" "$renamed"
  chmod 755 "$renamed"
  rename_ready=$work/rename-ready
  rename_go=$work/rename-go
  mkfifo "$rename_ready" "$rename_go"
  (
    cd "$project"
    COSMIC_PORTABLE_CACHE="$cache" \
    COSMIC_PORTABLE_STARTUP_TEST_READY="$rename_ready" \
    COSMIC_PORTABLE_STARTUP_TEST_GO="$rename_go" \
      "$renamed" build
  ) > "$work/renamed-build.out" 2> "$work/renamed-build.err" &
  renamed_pid=$!
  IFS= read -r ignored < "$rename_ready"
  mv "$renamed" "$work/renamed-away"
  printf 'go\n' > "$rename_go" & rename_release_pid=$!
  wait "$rename_release_pid"
  wait "$renamed_pid"
  grep -F 'build: PASS (o/bin/hello, o/bin/second' \
    "$work/renamed-build.out" >/dev/null
  cmp -n "$prefix_length" "$fixture/runtime.old.prefix" \
    "$project/o/bin/hello"

  # A nonselected raw core corruption lets this host start, but the private
  # prefix reader validates every core before output publication.
  host_system=$(uname -s)
  host_arch=$(uname -m)
  tab=$(printf '\t')
  host_target=$(awk -F "$tab" -v sysname="$host_system" -v arch="$host_arch" \
    '$5 == sysname && $6 == arch { print $4; exit }' "$fixture/targets.tsv")
  [ -n "$host_target" ]
  corrupt=$fixture/runtime.corrupt-$host_target
  corrupt_project=$work/corrupt-project
  mkdir -p "$corrupt_project/cmd/hello"
  cp "$fixture/hello_main.tl.in" "$corrupt_project/cmd/hello/main.tl"
  set +e
  (
    cd "$corrupt_project"
    COSMIC_PORTABLE_CACHE="$work/corrupt-cache" "$corrupt" build
  ) > "$work/corrupt-build.out" 2> "$work/corrupt-build.err"
  corrupt_status=$?
  set -e
  [ "$corrupt_status" -ne 0 ]
  grep -F 'retained portable core range ' "$work/corrupt-build.err" >/dev/null
  grep -F ' digest differs from manifest' "$work/corrupt-build.err" >/dev/null
  [ ! -e "$corrupt_project/o/bin/hello" ]

  for application in hello second; do
    (
      cd "$project"
      COSMIC_PORTABLE_CACHE="$cache" "o/bin/$application"
    ) > "$work/$application.out"
  done
  grep -F 'hello from the edited portable fixture' "$work/hello.out" >/dev/null
  grep -F 'second portable application' "$work/second.out" >/dev/null
  [ "$(find "$cache" -type f | wc -l | tr -d ' ')" = 1 ]
  sha_of "$project/o/bin/hello" > "$project/portable-hello.sha256"
  sha_of "$project/o/bin/second" > "$project/portable-second.sha256"

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

  # These are the canonical x86 Linux application bytes transported with the
  # work database. Every host executes them unchanged through its own core.
  [ "$(sha_of "$project/o/bin/hello")" = \
    "$(cat "$project/portable-hello.sha256")" ]
  [ "$(sha_of "$project/o/bin/second")" = \
    "$(cat "$project/portable-second.sha256")" ]
  # GitHub artifact transport normalizes executable modes; restore only the
  # launch permission after proving the transported bytes are unchanged.
  chmod 755 "$project/o/bin/hello" "$project/o/bin/second"
  (
    cd "$project"
    COSMIC_PORTABLE_CACHE="$cache" o/bin/hello
    COSMIC_PORTABLE_CACHE="$cache" o/bin/second
  ) > "$work/applications.out"
  grep -F 'hello from the edited portable fixture' \
    "$work/applications.out" >/dev/null
  grep -F 'second portable application' "$work/applications.out" >/dev/null
fi

if [ -n "${COSMIC_PORTABLE_IDENTITY_STATE_OUT-}" ]; then
  mkdir -p "$COSMIC_PORTABLE_IDENTITY_STATE_OUT"
  cp -R "$project/." "$COSMIC_PORTABLE_IDENTITY_STATE_OUT/"
fi

printf 'portable identity: PASS (runtime identities and unchanged portable application bytes execute on this host)\n'
