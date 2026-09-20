#!/bin/sh
# Package one host's portable Cosmic and two applications built by those bytes.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
out=${1:?usage: product_build.sh OUTPUT_DIRECTORY}
case $out in /*) ;; *) out=$PWD/$out ;; esac
if [ -e "$out" ]; then
  printf 'portable product build: output already exists: %s\n' "$out" >&2
  exit 2
fi
for required in "$root/o/bin/cosmic" "$root/o/cosmic.db" \
    "$root/o/targets.tsv"; do
  if [ ! -f "$required" ]; then
    printf 'portable product build: boot output is missing: %s\n' \
      "$required" >&2
    exit 2
  fi
done
if [ ! -x "$root/o/bin/cosmic" ]; then
  echo 'portable product build: boot executables are not executable' >&2
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-portable-product.XXXXXXXX")
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -eq 0 ]; then
    rm -rf "$work"
  else
    printf 'portable product build diagnostics preserved at %s\n' "$work" >&2
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

project=$work/project
mkdir -p "$project/cmd/hello" "$project/cmd/second"
cp "$root/test/portable/fixture/cmd/hello/main.tl.in" \
  "$project/cmd/hello/main.tl"
cp "$root/test/portable/fixture/cmd/second/main.tl.in" \
  "$project/cmd/second/main.tl"
(
  cd "$project"
  COSMIC_PORTABLE_CACHE="$work/cache" "$root/o/bin/cosmic" build
) > "$work/build.out" 2> "$work/build.err"
grep -F 'build: PASS (o/bin/hello, o/bin/second' "$work/build.out" >/dev/null
for application in hello second; do
  [ -x "$project/o/bin/$application" ]
done
(
  cd "$project"
  COSMIC_PORTABLE_CACHE="$work/cache" o/bin/hello
  COSMIC_PORTABLE_CACHE="$work/cache" o/bin/second
) > "$work/applications.out"
grep -F 'hello from the portable fixture' "$work/applications.out" >/dev/null
grep -F 'second portable application' "$work/applications.out" >/dev/null

mkdir -p "$out/apps" "$out/cores"
cp "$root/o/bin/cosmic" "$out/cosmic"
cp "$project/o/bin/hello" "$out/apps/hello"
cp "$project/o/bin/second" "$out/apps/second"
cp "$root/o/cosmic.db" "$out/cosmic.db"
cp "$root/o/targets.tsv" "$out/targets.tsv"
tab=$(printf '\t')
while IFS="$tab" read -r _ _ configuration target _ _; do
  [ "$configuration" = release ]
  mkdir -p "$out/cores/$target"
  cp "$root/o/core/$target/cosmic-core" \
    "$out/cores/$target/cosmic-core"
done < "$out/targets.tsv"
"$root/o/bin/cosmic" "$root/test/portable/product_extract.tl" \
  "$out/cosmic" "$out/prefix" "$out/manifest" "$out/targets.tsv" \
  "$out/cores" \
  "$out/apps/hello" "$out/apps/second"
chmod 755 "$out/cosmic" "$out/apps/hello" "$out/apps/second"

hash_value() {
  if command -v sha256sum >/dev/null 2>&1; then value=$(sha256sum "$1") || return
  else value=$(shasum -a 256 "$1") || return; fi
  printf '%s\n' "${value%% *}"
}
: > "$out/hashes.sha256"
for name in cosmic prefix manifest apps/hello apps/second cosmic.db \
    targets.tsv; do
  value=$(hash_value "$out/$name")
  printf '%s  %s\n' "$value" "$name" >> "$out/hashes.sha256"
done
while IFS="$tab" read -r _ _ configuration target _ _; do
  [ "$configuration" = release ]
  name=cores/$target/cosmic-core
  value=$(hash_value "$out/$name")
  printf '%s  %s\n' "$value" "$name" >> "$out/hashes.sha256"
done < "$out/targets.tsv"
printf 'portable product build: PASS (Cosmic, prefix, manifest, and two local portable applications)\n'
