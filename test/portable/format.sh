#!/bin/sh
# Cross-language Step 3 check: the production Teal writer makes a prefix from
# build.zig's generated records and real cores, and the production C decoder
# validates it before focused malformed-field mutations are tried.
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
publish=${1:-}
publish_target=${2:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/cosmic-portable-format.XXXXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

. "$root/test/portable/lib.sh"

timing_run 'format fixture writing' \
  "$root/o/bin/cosmic" "$root/test/portable/tool.tl" write-format-fixture \
  "$root/o/targets.tsv" "$root/o/core" "$work/program"
tab=$(printf '\t')
timing_run 'format native decoder compilation' \
  "$root/bin/zig" build portable-format-native
cp "$root/o/portable-fixture/format/format-test-native" "$work/format-test"

timing_run 'format mutation execution' "$work/format-test" "$work/program.a"
timing_run 'format inspection' "$work/format-test" --inspect \
  "$work/program.a" > "$work/inspection"

timing_begin 'format range and prefix verification'
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
[ "$(wc -c < "$work/program.prefix" | tr -d ' ')" = "$prefix_length" ]
compare_file_prefixes "$work/program.a" "$work/program.b" \
  "$prefix_length" "$work/programs-prefix"
compare_file_prefixes "$work/program.prefix" "$work/program.a" \
  "$prefix_length" "$work/written-prefix"
if cmp -s "$work/program.a" "$work/program.b"; then
  echo "portable format: fixture programs unexpectedly match" >&2
  exit 1
fi
timing_end 'format range and prefix verification' 0

if [ "$publish" != "" ]; then
  [ -n "$publish_target" ] || {
    echo 'usage: format.sh [PUBLISH_DIRECTORY TARGET]' >&2
    exit 2
  }
  awk -v target="$publish_target" '$4 == target { found = 1 } END { exit !found }' \
    "$root/o/targets.tsv" || {
      printf 'portable format: unsupported target: %s\n' "$publish_target" >&2
      exit 2
    }
  mkdir -p "$publish"
  rm -f "$publish"/format-test-*
  cp "$work/program.a" "$publish/program"
  cp "$root/o/targets.tsv" "$publish/targets.tsv"
  timing_run "format target decoder compilation: $publish_target" \
    "$root/bin/zig" build "portable-format-$publish_target"
  cp "$root/o/portable-fixture/format/format-test-$publish_target" \
    "$publish/format-test-$publish_target"
fi
printf 'portable format: PASS (generated targets, exact cores, shared prefix, distinct databases)\n'
