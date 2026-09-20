#!/bin/sh
# Verify transported product bytes and the exact core selected on this host.
set -eu

product=${1:?usage: product_test.sh PRODUCT TARGET FORMAT_DECODER [--codesign]}
target=${2:?usage: product_test.sh PRODUCT TARGET FORMAT_DECODER [--codesign]}
decoder=${3:?usage: product_test.sh PRODUCT TARGET FORMAT_DECODER [--codesign]}
signature=${4-}
if [ "$#" -gt 4 ] || { [ -n "$signature" ] && [ "$signature" != --codesign ]; }; then
  echo 'usage: product_test.sh PRODUCT TARGET FORMAT_DECODER [--codesign]' >&2
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

hash_value() {
  if command -v sha256sum >/dev/null 2>&1; then value=$(sha256sum "$1") || return
  else value=$(shasum -a 256 "$1") || return; fi
  printf '%s\n' "${value%% *}"
}
check_hashes() {
  for name in cosmic prefix manifest apps/hello apps/second writer portable.db \
      targets.tsv; do
    expected=$(awk -v name="$name" '$2 == name { print $1; found = 1 } END { if (!found) exit 1 }' \
      "$product/hashes.sha256") || return
    actual=$(hash_value "$product/$name") || return
    [ "$actual" = "$expected" ] || {
      printf 'portable product: transported hash differs: %s\n' "$name" >&2
      return 1
    }
  done
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
blocks=$(( (length + 16383) / 16384 ))
[ $((offset % 16384)) -eq 0 ]
dd if="$product/cosmic" of="$work/core.blocks" bs=16384 \
  skip=$((offset / 16384)) count="$blocks" 2>/dev/null
head -c "$length" "$work/core.blocks" > "$work/core"
[ "$(wc -c < "$work/core" | tr -d ' ')" = "$length" ]
[ "$(hash_value "$work/core")" = "$expected_digest" ]

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
