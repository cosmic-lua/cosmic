#!/bin/sh
# External entry point keeps timing_run from invoking a shell function in a
# conditional, which would weaken set -e inside that function on some shells.
set -eu
root=${1:?usage: checked-suite.sh ROOT TARGET WORK}
target=${2:?usage: checked-suite.sh ROOT TARGET WORK}
work=${3:?usage: checked-suite.sh ROOT TARGET WORK}
. "$root/test/portable/lib.sh"
targets=$root/o/sanitized/targets.tsv
cosmic=$root/o/sanitized/bin/cosmic
core=$root/o/sanitized/cosmic-core
target_id=$(awk -F '\t' '$2 == 2 && $3 == "sanitized" { print $1; count++ } END { if (count != 1) exit 1 }' "$targets")
checked_target=$(awk -F '\t' -v id="$target_id" '$1 == id && $2 == 1 && $3 == "release" { print $4; count++ } END { if (count != 1) exit 1 }' "$targets")
[ "$checked_target" = "$target" ]
set -- $("$cosmic" "$root/test/portable/tool.tl" entry "$cosmic" "$target_id" 2)
[ "$#" -eq 3 ]
offset=$1; length=$2; digest=$3
[ "$length" -eq "$(wc -c < "$core")" ]
extract_core_range "$cosmic" "$offset" "$length" "$work/checked.core" "$digest" "$core"
"$cosmic" "$root/test/portable/tool.tl" checked-context "$core" "$target"
if command -v timeout >/dev/null 2>&1; then
  timeout 90 "$cosmic" test
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout 90 "$cosmic" test
elif [ "${GITHUB_ACTIONS:-}" = true ]; then
  echo 'checked suite: timeout command unavailable; relying on the job bound' >&2
  "$cosmic" test
else
  echo 'checked suite: timeout or gtimeout is required outside CI' >&2
  exit 2
fi
