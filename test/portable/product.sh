#!/bin/sh
# Builds and verifies the per-host provenance bundle: portable Cosmic plus
# two standalone applications built by those same portable bytes.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
. "$root/test/portable/lib.sh"

verb=${1-}
case "$verb" in
  build|test) shift ;;
  *)
    echo "usage: product.sh {build|test} ARGS..." >&2
    echo "  product.sh build OUTPUT_DIRECTORY" >&2
    echo "  product.sh test PRODUCT TARGET FORMAT_DECODER [--codesign]" >&2
    exit 2
    ;;
esac

if [ "$verb" = build ]; then
  out=${1:?usage: product.sh build OUTPUT_DIRECTORY}
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
  "$root/o/bin/cosmic" "$root/test/portable/tool.tl" product-extract \
    "$out/cosmic" "$out/prefix" "$out/manifest" "$out/targets.tsv" \
    "$out/cores" \
    "$out/apps/hello" "$out/apps/second"
  chmod 755 "$out/cosmic" "$out/apps/hello" "$out/apps/second"

  : > "$out/hashes.sha256"
  for name in cosmic prefix manifest apps/hello apps/second cosmic.db \
      targets.tsv; do
    value=$(sha256_of "$out/$name")
    printf '%s  %s\n' "$value" "$name" >> "$out/hashes.sha256"
  done
  while IFS="$tab" read -r _ _ configuration target _ _; do
    [ "$configuration" = release ]
    name=cores/$target/cosmic-core
    value=$(sha256_of "$out/$name")
    printf '%s  %s\n' "$value" "$name" >> "$out/hashes.sha256"
  done < "$out/targets.tsv"
  printf 'portable product build: PASS (Cosmic, prefix, manifest, and two local portable applications)\n'
  exit 0
fi

# verb = test. Verifies transported product bytes and the exact core
# selected on this host.
product=${1:?usage: product.sh test PRODUCT TARGET FORMAT_DECODER [--codesign]}
target=${2:?usage: product.sh test PRODUCT TARGET FORMAT_DECODER [--codesign]}
decoder=${3:?usage: product.sh test PRODUCT TARGET FORMAT_DECODER [--codesign]}
signature=${4-}
if [ "$#" -gt 4 ] || { [ -n "$signature" ] && [ "$signature" != --codesign ]; }; then
  echo 'usage: product.sh test PRODUCT TARGET FORMAT_DECODER [--codesign]' >&2
  exit 2
fi
case $product in /*) ;; *) product=$PWD/$product ;; esac
case $decoder in /*) ;; *) decoder=$PWD/$decoder ;; esac
for executable in "$product/cosmic" "$product/apps/hello" \
    "$product/apps/second" "$decoder"; do
  if [ ! -x "$executable" ]; then
    printf 'portable product: executable mode was not restored: %s\n' \
      "$executable" >&2
    exit 2
  fi
done

check_hashes() {
  for name in cosmic prefix manifest apps/hello apps/second cosmic.db \
      targets.tsv; do
    expected=$(awk -v name="$name" '$2 == name { print $1; found = 1 } END { if (!found) exit 1 }' \
      "$product/hashes.sha256") || return
    actual=$(sha256_of "$product/$name") || return
    [ "$actual" = "$expected" ] || {
      printf 'portable product: transported hash differs: %s\n' "$name" >&2
      return 1
    }
  done
  tab=$(printf '\t')
  while IFS="$tab" read -r _ _ configuration core_target _ _; do
    [ "$configuration" = release ] || return
    name=cores/$core_target/cosmic-core
    expected=$(awk -v name="$name" '$2 == name { print $1; found = 1 } END { if (!found) exit 1 }' \
      "$product/hashes.sha256") || return
    actual=$(sha256_of "$product/$name") || return
    [ "$actual" = "$expected" ] || {
      printf 'portable product: transported hash differs: %s\n' "$name" >&2
      return 1
    }
  done < "$product/targets.tsv"
}
check_hashes

work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-portable-product-test.XXXXXXXX")
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
"$decoder" --inspect "$product/cosmic" > "$work/inspection"
target_id=$(awk -F '\t' -v target="$target" \
  '$4 == target { print $1; found = 1 } END { if (!found) exit 1 }' \
  "$product/targets.tsv")
entry=$(awk -v target="$target_id" \
  '$1 == "entry" && $2 == target && $3 == 1 { print $4, $5, $6; found = 1 } END { if (!found) exit 1 }' \
  "$work/inspection")
set -- $entry
offset=$1
length=$2
expected_digest=$3
extract_core_range "$product/cosmic" "$offset" "$length" "$work/core" \
  "$expected_digest" "$product/cores/$target/cosmic-core"

prefix_record=$(awk '$1 == "prefix" { print $2, $4, $5; found = 1 } END { if (!found) exit 1 }' \
  "$work/inspection")
set -- $prefix_record
prefix_length=$1
manifest_offset=$2
manifest_length=$3
[ "$manifest_length" -eq 4096 ]
[ $((manifest_offset % 16384)) -eq 0 ]
[ "$prefix_length" -eq "$(wc -c < "$product/prefix" | tr -d ' ')" ]
head -c "$prefix_length" "$product/cosmic" > "$work/prefix"
cmp "$product/prefix" "$work/prefix"
dd if="$product/cosmic" of="$work/manifest.block" bs=16384 \
  skip=$((manifest_offset / 16384)) count=1 2>/dev/null
head -c "$manifest_length" "$work/manifest.block" > "$work/manifest"
cmp "$product/manifest" "$work/manifest"
for application in hello second; do
  head -c "$prefix_length" "$product/apps/$application" > \
    "$work/$application.prefix"
  cmp "$product/prefix" "$work/$application.prefix"
done
if [ "$signature" = --codesign ]; then
  codesign --verify --strict --verbose=2 "$work/core"
fi

mkdir "$work/run"
(
  cd "$work/run"
  COSMIC_PORTABLE_CACHE="$work/cache" "$product/apps/hello"
  COSMIC_PORTABLE_CACHE="$work/cache" "$product/apps/second"
) > "$work/applications.out"
grep -F 'hello from the portable fixture' "$work/applications.out" >/dev/null
grep -F 'second portable application' "$work/applications.out" >/dev/null
check_hashes
printf 'portable product: PASS (transported bytes, shared prefix, selected range, and applications)\n'
