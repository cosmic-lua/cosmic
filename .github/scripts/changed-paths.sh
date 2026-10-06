#!/bin/sh
# The paths a branch changed since its base on main, for a light run's
# format check (ci.yml's `checked` job), which lays out only those and
# makes every check spanning files over the whole tree (`cosmic fix
# --check --changed`, through cosmic_ci's orchestration):
#
#     BASE=<commit> OUT=<file> sh .github/scripts/changed-paths.sh
#
# BASE is the tree's base on main (`driver.tl merge-base`), whose tree main's own
# run held to the whole tree's check. The script fetches that one
# commit into the checkout (from origin, with the credentials
# actions/checkout keeps), writes every path HEAD adds, changes or
# removes since it to OUT, one a line, and `paths=<OUT>` to
# $GITHUB_OUTPUT (standard output, for a run by hand). Where it cannot
# -- no base, a fetch or a diff that fails, a path holding a line break,
# more than LIMIT paths (400, past which the whole tree's check costs
# about as much) -- it writes neither, and the check covers the whole
# tree. The fetch is cut off after FETCH_SECONDS (60) where there is a
# `timeout`. It always exits 0: a list not made costs time, never a
# result.
set -u

out=${OUT:?OUT names the file to write the paths to}
result=${GITHUB_OUTPUT:-/dev/stdout}
limit=${LIMIT:-400}
wait=${FETCH_SECONDS:-60}
base=${BASE-}

rm -f "$out"
listed="$out.z"
trap 'rm -f "$listed"' EXIT

whole() {
  echo "the format check covers the whole tree: $1"
  exit 0
}

case $base in
  *[!0-9a-f]* | "") whole "no base on main" ;;
esac
[ ${#base} -eq 40 ] || whole "no base on main"

if command -v timeout >/dev/null 2>&1; then
  timeout "$wait" git fetch --quiet --no-tags --depth=1 origin "$base" ||
    whole "could not fetch $base"
else
  git fetch --quiet --no-tags --depth=1 origin "$base" || whole "could not fetch $base"
fi
git diff --no-renames --name-only -z "$base" HEAD -- > "$listed" ||
  whole "could not list what changed since $base"

# One NUL ends each path, so a path holding a line break is one line
# too many.
paths=$(tr -dc '\000' < "$listed" | wc -c | tr -d ' ')
lines=$(tr '\000' '\n' < "$listed" | wc -l | tr -d ' ')
[ "$paths" -eq "$lines" ] || whole "a path changed holds a line break"
[ "$paths" -le "$limit" ] || whole "$paths paths changed, more than $limit"

tr '\000' '\n' < "$listed" > "$out" || whole "could not write $out"
echo "paths=$out" >> "$result"
echo "the format check lays out the $paths paths changed since $base"
exit 0
