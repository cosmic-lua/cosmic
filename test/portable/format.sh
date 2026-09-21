#!/bin/sh
# Cross-language Step 3 check: the production Teal writer makes a prefix from
# build.zig's generated records and real cores, and the production C decoder
# validates it before focused malformed-field mutations are tried.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
publish=${1:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-portable-format.XXXXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

. "$root/test/portable/lib.sh"

"$root/o/bin/cosmic" "$root/test/portable/tool.tl" write-format-fixture \
  "$root/o/targets.tsv" "$root/o/core" "$work/program"
required_mask=0
release_configuration=
tab=$(printf '\t')
while IFS="$tab" read -r target_id configuration_id configuration target uname_os uname_arch; do
  [ "$configuration" = release ]
  required_mask=$((required_mask | (1 << target_id)))
  if [ -z "$release_configuration" ]; then
    release_configuration=$configuration_id
  else
    [ "$release_configuration" = "$configuration_id" ]
  fi
done < "$root/o/targets.tsv"
"$root/bin/zig" cc -std=c11 -Wall -Wextra -Werror \
  -DCOSMIC_PORTABLE_REQUIRED_TARGET_MASK=UINT64_C\("$required_mask"\) \
  -DCOSMIC_PORTABLE_RELEASE_CONFIGURATION_ID="$release_configuration" \
  -I "$root/core" "$root/core/portable.c" \
  "$root/test/portable/format_test.c" -o "$work/format-test"

"$work/format-test" "$work/program.a"
"$work/format-test" --inspect "$work/program.a" > "$work/inspection"

while IFS="$tab" read -r target_id configuration_id configuration target uname_os uname_arch; do
  [ "$configuration" = release ]
  line=$(awk -v target="$target_id" -v configuration="$configuration_id" \
    '$1 == "entry" && $2 == target && $3 == configuration { print }' \
    "$work/inspection")
  [ -n "$line" ]
  offset=$(printf '%s\n' "$line" | awk '{ print $4 }')
  length=$(printf '%s\n' "$line" | awk '{ print $5 }')
  digest=$(printf '%s\n' "$line" | awk '{ print $6 }')
  core="$root/o/core/$target/cosmic-core"
  [ "$(wc -c < "$core" | tr -d ' ')" = "$length" ]
  extract_core_range "$work/program.a" "$offset" "$length" "$work/extracted" \
    "$digest" "$core"
done < "$root/o/targets.tsv"

prefix_length=$(awk '$1 == "prefix" { print $2 }' "$work/inspection")
cmp -n "$prefix_length" "$work/program.a" "$work/program.b"
cmp -n "$prefix_length" "$work/program.prefix" "$work/program.a"
if cmp -s "$work/program.a" "$work/program.b"; then
  echo "portable format: fixture programs unexpectedly match" >&2
  exit 1
fi

if [ "$publish" != "" ]; then
  mkdir -p "$publish"
  cp "$work/program.a" "$publish/program"
  cp "$root/o/targets.tsv" "$publish/targets.tsv"
  while IFS="$tab" read -r target_id configuration_id configuration target uname_os uname_arch; do
    "$root/bin/zig" cc -target "$target" -O2 -std=c11 -Wall -Wextra -Werror \
      -DCOSMIC_PORTABLE_REQUIRED_TARGET_MASK=UINT64_C\("$required_mask"\) \
      -DCOSMIC_PORTABLE_RELEASE_CONFIGURATION_ID="$release_configuration" \
      -DPORTABLE_TEST_TARGET_ID="$target_id" \
      -DPORTABLE_TEST_CONFIGURATION_ID="$configuration_id" \
      -I "$root/core" "$root/core/portable.c" \
      "$root/test/portable/format_test.c" -o "$publish/format-test-$target"
  done < "$root/o/targets.tsv"
fi
printf 'portable format: PASS (generated targets, exact cores, shared prefix, distinct databases)\n'
