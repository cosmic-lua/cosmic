#!/bin/sh
# Exercise retained validation, VFS reads, and private prefix reads using the
# real Cosmic runtime rather than the step-4 native payload substitute.
set -eu

fixture=${1:?usage: runtime_test.sh RUNTIME_FIXTURE_DIRECTORY}
case $fixture in /*) ;; *) fixture=$PWD/$fixture ;; esac
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-runtime.XXXXXXXX")
cleanup() {
  status=$?
  trap - EXIT
  # Diagnostics and cleanup must never replace the inferior's original status.
  set +e
  if [ "$status" -ne 0 ]; then
    for diagnostic in "$work"/*.err; do
      if [ -s "$diagnostic" ]; then
        printf '%s:\n' "$diagnostic" >&2
        cat "$diagnostic" >&2
      fi
    done
    if [ -s "$work/paused.out" ]; then
      printf '%s:\n' "$work/paused.out" >&2
      cat "$work/paused.out" >&2
    fi
    if [ -n "${COSMIC_PORTABLE_DIAGNOSTICS-}" ]; then
      mkdir -p "$COSMIC_PORTABLE_DIAGNOSTICS"
      printf '%s\n' "$status" > "$COSMIC_PORTABLE_DIAGNOSTICS/status"
      for diagnostic in "$work"/*.out "$work"/*.err; do
        if [ -f "$diagnostic" ]; then
          cp "$diagnostic" "$COSMIC_PORTABLE_DIAGNOSTICS/"
        fi
      done
      for executable in "$work"/cache-replace/core-*; do
        if [ -f "$executable" ]; then
          cp "$executable" "$COSMIC_PORTABLE_DIAGNOSTICS/executing-core"
        fi
      done
      # Cover ordinary core and core.PID file patterns when the kernel writes
      # them. The checkout already has a core/ directory, so an unsuffixed dump
      # in $root cannot land there; piped system core handlers are also outside
      # this fixture's filesystem capture.
      for dump in "$root"/core "$root"/core.[0-9]* \
          "$work"/core "$work"/core.[0-9]*; do
        if [ -f "$dump" ]; then
          cp "$dump" "$COSMIC_PORTABLE_DIAGNOSTICS/"
        fi
      done
    fi
  fi
  chmod -R u+w "$work" 2>/dev/null || :
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 126' HUP INT TERM
ulimit -c unlimited 2>/dev/null || :

chmod 755 "$fixture/runtime.release" "$fixture/runtime.old" \
  "$fixture/runtime.new" "$fixture/runtime.incompatible"
release_hash=$(cat "$fixture/runtime.release.prefix-sha256")
old_hash=$(cat "$fixture/runtime.old.prefix-sha256")
new_hash=$(cat "$fixture/runtime.new.prefix-sha256")
[ "$old_hash" != "$new_hash" ]
mkdir -p "$work/bin" "$work/run space"
cp "$fixture/runtime.release" "$work/bin/cosmic-runtime"
cp "$fixture/probe.tl" "$work/run space/probe.tl"
chmod 755 "$work/bin/cosmic-runtime"

# The selectable fixture TU owns every diagnostic phase, including the one
# after the retained artifact has closed. Production cores carry none of it.
COSMIC_PORTABLE_CACHE="$work/cache-phases" \
  "$fixture/runtime.old" help > "$work/phases.out" 2> "$work/phases.err"
cat > "$work/phases.expected" <<'EOF'
cosmic portable test phase: artifact adopted
cosmic portable test phase: startup released
cosmic portable test phase: database opened
cosmic portable test phase: store installed
cosmic portable test phase: main entering
cosmic portable test phase: main returned
cosmic portable test phase: lua closed
cosmic portable test phase: database closed
cosmic portable test phase: artifact closed
EOF
cmp "$work/phases.expected" "$work/phases.err"

# Absolute, relative, PATH, and symlink logical names all open the same retained
# descriptor. Help, docs, and a real compiled script read the artifact DB.
COSMIC_PORTABLE_CACHE="$work/cache-release" \
  "$work/bin/cosmic-runtime" help > "$work/help"
grep -q '^cosmic -- a runtime' "$work/help"
# Occupied 8 and 9 no longer conflict with the portable contract: the shell
# chooses another pair and the real runtime adopts the exported numbers.
(
  exec 8< "$fixture/runtime.release"
  exec 9< "$fixture/runtime.release"
  COSMIC_PORTABLE_CACHE="$work/cache-release" \
    "$work/bin/cosmic-runtime" help > /dev/null
)
COSMIC_PORTABLE_CACHE="$work/cache-release" \
  "$work/bin/cosmic-runtime" docs Fs.read > "$work/docs"
grep -q 'Fs.read' "$work/docs"
(
  cd "$work/bin"
  COSMIC_PORTABLE_CACHE="$work/cache-release" ./cosmic-runtime help >/dev/null
)
PATH="$work/bin:$PATH" COSMIC_PORTABLE_CACHE="$work/cache-release" \
  cosmic-runtime help >/dev/null
ln -s "$work/bin/cosmic-runtime" "$work/cosmic-alias"
COSMIC_PORTABLE_CACHE="$work/cache-release" "$work/cosmic-alias" help >/dev/null
(
  cd "$work/run space"
  COSMIC_PORTABLE_CACHE="$work/cache-release" "$work/bin/cosmic-runtime" \
    probe.tl "$release_hash" old > "$work/script"
)
grep -q "^script $release_hash old$" "$work/script"

# Any private field marks a strict portable launch, even without --artifact;
# it cannot propagate through or enter the raw-core --boot bridge.
host=$(uname -s):$(uname -m)
selected=$(dd if="$fixture/runtime.release" bs=16384 count=1 2>/dev/null | \
  grep "^  $host")
target_id=$(printf '%s\n' "$selected" | \
  sed 's/.*cosmic_target_id=\([0-9][0-9]*\);.*/\1/')
configuration_id=$(printf '%s\n' "$selected" | \
  sed 's/.*cosmic_configuration_id=\([0-9][0-9]*\);.*/\1/')
offset=$(printf '%s\n' "$selected" | \
  sed 's/.*cosmic_offset=\([0-9][0-9]*\);.*/\1/')
length=$(printf '%s\n' "$selected" | \
  sed 's/.*cosmic_length=\([0-9][0-9]*\);.*/\1/')
digest=$(printf '%s\n' "$selected" | \
  sed 's/.*cosmic_sha256=\([0-9a-f][0-9a-f]*\) .*/\1/')
target=$(awk -F '\t' -v id="$target_id" '$1 == id { print $4 }' \
  "$fixture/hooked-build/targets.tsv")
wrong_core=$fixture/hooked-build/core/$target/cosmic-core
chmod 755 "$wrong_core"
set +e
COSMIC_PORTABLE_TARGET_ID="$target_id" "$wrong_core" --boot x y \
  > "$work/partial.out" 2> "$work/partial.err"
partial_status=$?
set -e
[ "$partial_status" -ne 0 ]
grep -q 'portable startup names no artifact' "$work/partial.err"

expect_contract_error() {
  contract_name=$1
  artifact_field=$2
  core_field=$3
  contract_pattern=$4
  set +e
  (
    exec 8< "$fixture/runtime.release"
    exec 9< "$wrong_core"
    COSMIC_PORTABLE_ARTIFACT_FD="$artifact_field" \
      COSMIC_PORTABLE_CORE_FD="$core_field" \
      COSMIC_PORTABLE_TARGET_ID="$target_id" \
      COSMIC_PORTABLE_CONFIGURATION_ID="$configuration_id" \
      COSMIC_PORTABLE_CORE_OFFSET="$offset" \
      COSMIC_PORTABLE_CORE_LENGTH="$length" \
      COSMIC_PORTABLE_CORE_SHA256="$digest" \
      "$wrong_core" --artifact "$fixture/runtime.release" help
  ) > "$work/contract-$contract_name.out" \
    2> "$work/contract-$contract_name.err"
  contract_status=$?
  set -e
  [ "$contract_status" -ne 0 ]
  grep -q "$contract_pattern" "$work/contract-$contract_name.err"
}

# Startup accepts representable nonstandard descriptors, while standard,
# equal, and unrepresentable fields are rejected before descriptor adoption.
expect_contract_error standard 2 9 \
  'portable artifact descriptor field is invalid'
expect_contract_error equal 8 8 'portable descriptor fields are equal'
expect_contract_error unrepresentable 2147483648 9 \
  'portable artifact descriptor field is invalid'

# A different build of the same target/configuration is the executing inode and
# FD9, but differs from the manifest's exact core bytes and is rejected.
set +e
(
  exec 8<"$fixture/runtime.release"
  exec 9<"$wrong_core"
  COSMIC_PORTABLE_ARTIFACT_FD=8 COSMIC_PORTABLE_CORE_FD=9 \
    COSMIC_PORTABLE_TARGET_ID="$target_id" \
    COSMIC_PORTABLE_CONFIGURATION_ID="$configuration_id" \
    COSMIC_PORTABLE_CORE_OFFSET="$offset" COSMIC_PORTABLE_CORE_LENGTH="$length" \
    COSMIC_PORTABLE_CORE_SHA256="$digest" \
    "$wrong_core" --artifact "$fixture/runtime.release" help
) > "$work/wrong-core.out" 2> "$work/wrong-core.err"
wrong_core_status=$?
set -e
[ "$wrong_core_status" -ne 0 ]
grep -Eq 'executing core (length|digest) differs from manifest' \
  "$work/wrong-core.err"

# A warm cached core remains independently usable when any artifact core range
# is corrupt. Prefix reuse verifies every manifest range lazily and returns no
# bytes on failure; a cold launch still rejects corruption in the selected
# range while extracting it.
COSMIC_PORTABLE_CACHE="$work/cache-release" \
  "$fixture/runtime.release" "$root/test/portable/corrupt_runtime_ranges.tl" \
  "$fixture/runtime.release" "$work" "$offset"

selected_corrupt=
nonselected_ranges=0
while read -r corrupt_program corrupt_kind; do
  COSMIC_PORTABLE_CACHE="$work/cache-release" \
    "$corrupt_program" help > /dev/null
  set +e
  (
    cd "$root"
    COSMIC_PORTABLE_CACHE="$work/cache-release" "$corrupt_program" \
      test/portable/retained_prefix_probe.tl "$release_hash" corrupt
  ) > "$work/prefix-$corrupt_kind.out" 2> "$work/prefix-$corrupt_kind.err"
  prefix_status=$?
  set -e
  [ "$prefix_status" -ne 0 ]
  grep -q 'retained portable core range .* digest differs from manifest' \
    "$work/prefix-$corrupt_kind.err"
  if [ "$corrupt_kind" = selected ]; then
    selected_corrupt=$corrupt_program
  else
    nonselected_ranges=$((nonselected_ranges + 1))
  fi
done < "$work/corrupt-ranges"
[ -n "$selected_corrupt" ]
[ "$nonselected_ranges" -ge 1 ]
set +e
COSMIC_PORTABLE_CACHE="$work/cache-selected-corrupt" \
  "$selected_corrupt" help > /dev/null 2> "$work/cold-corrupt.err"
cold_corrupt_status=$?
set -e
[ "$cold_corrupt_status" -ne 0 ]
grep -q 'extracted core digest differs' "$work/cold-corrupt.err"

run_paused() {
  hook=$1
  program=$2
  cache=$3
  expected_hash=$4
  expected_marker=$5
  ready=$work/ready
  go=$work/go
  rm -f "$ready" "$go"
  mkfifo "$ready" "$go"
  if [ "$hook" = after_validation ]; then
    (
      cd "$root"
      COSMIC_PORTABLE_CACHE="$cache" \
        COSMIC_PORTABLE_STARTUP_TEST_READY="$ready" \
        COSMIC_PORTABLE_STARTUP_TEST_GO="$go" \
        "$program" test/portable/retained_prefix_probe.tl \
        "$expected_hash" "$expected_marker"
    ) > "$work/paused.out" 2> "$work/paused.err" &
  else
    (
      cd "$work/run space"
      COSMIC_PORTABLE_CACHE="$cache" COSMIC_PORTABLE_TEST_HOOK="$hook" \
        COSMIC_PORTABLE_TEST_READY="$ready" COSMIC_PORTABLE_TEST_GO="$go" \
        "$program" probe.tl "$expected_hash" "$expected_marker"
    ) > "$work/paused.out" 2> "$work/paused.err" &
  fi
  paused_pid=$!
  IFS= read -r ignored < "$ready"
}
release_paused() {
  printf 'go\n' > "$work/go" & release_pid=$!
  wait "$release_pid"
  wait "$paused_pid"
}

# Once the artifact descriptor is open, atomic replacement cannot mix the new
# pathname's database or prefix into the paused process. A subsequent launch
# selects all-new bytes.
mkdir -p "$work/replace space"
program=$work/replace\ space/cosmic
cp "$fixture/runtime.old" "$program"
chmod 755 "$program"
run_paused after_validation "$program" "$work/cache-replace" "$old_hash" old
cp "$fixture/runtime.new" "$work/replacement"
chmod 755 "$work/replacement"
mv "$work/replacement" "$program"
release_paused
grep -q "^old $old_hash$" "$work/paused.out"
(
  cd "$root"
  COSMIC_PORTABLE_CACHE="$work/cache-replace" "$program" \
    test/portable/retained_prefix_probe.tl "$new_hash" new > "$work/new.out"
)
grep -q "^new $new_hash$" "$work/new.out"

# Unlink after adoption also leaves database and private prefix reads on the
# retained descriptor.
unlinked=$work/unlinked
cp "$fixture/runtime.old" "$unlinked"
chmod 755 "$unlinked"
run_paused after_validation "$unlinked" "$work/cache-unlink" "$old_hash" old
rm "$unlinked"
release_paused
grep -q "^old $old_hash$" "$work/paused.out"

# Replacement after shell selection but before open cannot pair old launcher
# claims with an incompatible complete artifact and never reaches boot mode.
mismatch=$work/mismatch
cp "$fixture/runtime.old" "$mismatch"
chmod 755 "$mismatch"
run_paused after_select "$mismatch" "$work/cache-mismatch" "$old_hash" old
cp "$fixture/runtime.incompatible" "$work/mismatch.new"
chmod 755 "$work/mismatch.new"
mv "$work/mismatch.new" "$mismatch"
set +e
release_paused
mismatch_status=$?
set -e
[ "$mismatch_status" -ne 0 ]
grep -q 'extracted core digest differs' "$work/paused.err"
if grep -q 'no tree to boot' "$work/paused.err"; then exit 1; fi

# Record real runtime.release entry cost independently of the tiny launcher
# payload timings. These observations are informational and set no threshold.
runtime_timing_cache="$work/runtime-timing-cache"
runtime_bytes=$(wc -c < "$fixture/runtime.release")
COSMIC_PORTABLE_CACHE="$work/runtime-timing-driver-cache" \
  "$fixture/runtime.release" "$root/test/portable/time_runtime.tl" \
  "$fixture/runtime.release" "$runtime_timing_cache" \
  > "$work/runtime-cold.time"
COSMIC_PORTABLE_CACHE="$work/runtime-timing-driver-cache" \
  "$fixture/runtime.release" "$root/test/portable/time_runtime.tl" \
  "$fixture/runtime.release" "$runtime_timing_cache" \
  > "$work/runtime-warm.time"
printf 'portable runtime.release entry cold timing (%s bytes): ' "$runtime_bytes"
tr '\n' ' ' < "$work/runtime-cold.time"
printf '\nportable runtime.release entry warm timing (%s bytes): ' "$runtime_bytes"
tr '\n' ' ' < "$work/runtime-warm.time"
printf '\n'

printf 'portable runtime: PASS (real help/docs/script, logical paths, retained replacement/unlink, mismatch rejection)\n'
