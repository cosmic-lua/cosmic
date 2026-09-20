#!/bin/sh
# Build real new-format Cosmic artifacts for retained-descriptor integration.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
if [ "$#" -ne 1 ] && [ "$#" -ne 2 ] && [ "$#" -ne 4 ]; then
  echo 'usage: runtime_build.sh OUTPUT_DIRECTORY [PREBUILT_PREFIX [WRITER PORTABLE_DATABASE]]' >&2
  exit 2
fi
out=$1
prebuilt=${2-}
writer=${3-}
database=${4-}
if [ -e "$out" ]; then
  printf 'portable runtime build: output already exists: %s\n' "$out" >&2
  exit 2
fi
mkdir -p "$out"
owned_prebuilt=
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$owned_prebuilt" ]; then
    if [ "$status" -eq 0 ]; then
      rm -rf "$owned_prebuilt"
    else
      printf 'portable runtime build inputs preserved at %s\n' \
        "$owned_prebuilt" >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

if [ -z "$prebuilt" ]; then
  owned_prebuilt=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-portable-cores.XXXXXXXX")
  prebuilt=$owned_prebuilt
  "$root/bin/zig" build portable-fixture-cores --prefix "$prebuilt"
else
  case $prebuilt in /*) ;; *) prebuilt=$PWD/$prebuilt ;; esac
fi
if [ -z "$writer" ]; then writer=$root/o/bin/cosmic; fi
if [ -z "$database" ]; then database=$root/o/cosmic.db; fi
case $writer in /*) ;; *) writer=$PWD/$writer ;; esac
case $database in /*) ;; *) database=$PWD/$database ;; esac
if [ ! -x "$writer" ]; then
  printf 'portable runtime build: writer is not executable: %s\n' "$writer" >&2
  exit 2
fi
if [ ! -f "$database" ]; then
  printf 'portable runtime build: portable database is missing: %s\n' \
    "$database" >&2
  exit 2
fi

targets=$prebuilt/targets.tsv
release_cores=$prebuilt/core
hooked_cores=$prebuilt/portable-fixture/core
sanitized_core=$prebuilt/portable-fixture/sanitized/cosmic-core
for required in "$targets" "$sanitized_core"; do
  if [ ! -f "$required" ]; then
    printf 'portable runtime build: prebuilt input is missing: %s\n' \
      "$required" >&2
    exit 2
  fi
done
tab=$(printf '\t')
while IFS="$tab" read -r _ _ _ target _ _; do
  for required in "$release_cores/$target/cosmic-core" \
      "$hooked_cores/$target/cosmic-core"; do
    if [ ! -f "$required" ]; then
      printf 'portable runtime build: prebuilt input is missing: %s\n' \
        "$required" >&2
      exit 2
    fi
  done
done < "$targets"

mkdir -p "$out/hooked-build"
cp -R "$hooked_cores" "$out/hooked-build/core"
cp "$targets" "$out/hooked-build/targets.tsv"
mkdir -p "$out/sanitized-build/sanitized"
cp "$sanitized_core" "$out/sanitized-build/sanitized/cosmic-core"
cp "$database" "$out/old.db"
cp "$database" "$out/new.db"
cp "$database" "$out/basis.db"
cp "$database" "$out/missing.db"
"$writer" "$root/test/portable/prepare_runtime_databases.tl" \
  "$out/old.db" "$out/new.db" "$out/basis.db" "$out/missing.db"

"$writer" "$root/test/portable/write_runtime_fixture.tl" \
  "$targets" "$release_cores" "$out/old.db" "$out/runtime.release"
"$writer" "$root/test/portable/write_runtime_fixture.tl" \
  "$targets" "$out/hooked-build/core" "$out/old.db" \
  "$out/runtime.old" test
"$writer" "$root/test/portable/write_runtime_fixture.tl" \
  "$targets" "$out/hooked-build/core" "$out/new.db" \
  "$out/runtime.new" test
"$writer" "$root/test/portable/write_runtime_fixture.tl" \
  "$targets" "$out/hooked-build/core" "$out/basis.db" \
  "$out/runtime.basis" test
"$writer" "$root/test/portable/write_runtime_fixture.tl" \
  "$targets" "$out/hooked-build/core" "$out/missing.db" \
  "$out/runtime.missing" test

# A fixture-only fourth manifest entry binds the real host sanitized core. Its
# synthetic uname tuple is deliberately unreachable from the launcher; the
# identity test executes that raw core with descriptors 8 and 9 populated from
# this manifest entry, exercising the production startup contract without
# making sanitized the ordinary shell selection.
host_system=$(uname -s)
host_arch=$(uname -m)
host_record=$(awk -F "$tab" -v sysname="$host_system" -v arch="$host_arch" \
  '$5 == sysname && $6 == arch { print; exit }' "$targets")
[ -n "$host_record" ]
target_id=$(printf '%s\n' "$host_record" | awk -F "$tab" '{ print $1 }')
target=$(printf '%s\n' "$host_record" | awk -F "$tab" '{ print $4 }')
sanitized_name="sanitized-$target"
cat "$targets" > "$out/sanitized-targets.tsv"
printf '%s\t2\tsanitized\t%s\tFixture\tSanitized\n' \
  "$target_id" "$sanitized_name" >> "$out/sanitized-targets.tsv"
mkdir -p "$out/sanitized-cores"
while IFS="$tab" read -r _ _ _ release_target _ _; do
  mkdir -p "$out/sanitized-cores/$release_target"
  cp "$out/hooked-build/core/$release_target/cosmic-core" \
    "$out/sanitized-cores/$release_target/cosmic-core"
done < "$targets"
mkdir -p "$out/sanitized-cores/$sanitized_name"
cp "$out/sanitized-build/sanitized/cosmic-core" \
  "$out/sanitized-cores/$sanitized_name/cosmic-core"
"$writer" "$root/test/portable/write_runtime_fixture.tl" \
  "$out/sanitized-targets.tsv" "$out/sanitized-cores" "$out/old.db" \
  "$out/runtime.sanitized" test
printf '%s\n' "$target_id" > "$out/sanitized-target-id"
printf '%s\n' "$target" > "$out/sanitized-target"
printf '%s\n' "$sanitized_name" > "$out/sanitized-core-name"

mkdir -p "$out/incompatible-cores"
while IFS="$tab" read -r target_id configuration_id configuration target uname_os uname_arch; do
  mkdir -p "$out/incompatible-cores/$target"
  cp "$out/hooked-build/core/$target/cosmic-core" \
    "$out/incompatible-cores/$target/cosmic-core"
  printf X | dd of="$out/incompatible-cores/$target/cosmic-core" \
    bs=1 seek=128 conv=notrunc 2>/dev/null
done < "$targets"
"$writer" "$root/test/portable/write_runtime_fixture.tl" \
  "$targets" "$out/incompatible-cores" "$out/new.db" \
  "$out/runtime.incompatible" test

# Make the second complete artifact's prefix observably different without
# changing its valid launcher or manifest. This byte is padding in the final
# shell comment, outside all core ranges.
"$writer" "$root/test/portable/prepare_runtime_artifacts.tl" \
  "$out" "$targets"

cp "$root/test/portable/fixture/retained_probe.tl.in" "$out/probe.tl"
cp "$root/test/portable/fixture/runtime_test.tl.in" "$out/runtime_test.tl.in"
cp "$root/test/portable/fixture/cmd/hello/main.tl.in" "$out/hello_main.tl.in"
chmod 755 "$out/runtime.release" "$out/runtime.old" "$out/runtime.new" \
  "$out/runtime.basis" "$out/runtime.missing" "$out/runtime.sanitized" \
  "$out/runtime.incompatible" "$out"/runtime.corrupt-*
cp "$targets" "$out/targets.tsv"
printf 'portable runtime build: PASS (host-independent projection, real release/sanitized cores, distinct complete artifacts)\n'
