#!/bin/sh
# Decides the scope of a branch push (ci.yml's `scope` job): `full`, the
# merge queue's, where the branch's change touches a path
# .github/scripts/branch-scope.txt lists, else `light`.
#
#   branch-scope.sh match      reads changed paths, one a line, and prints
#                              the first that the list names and the
#                              pattern that does, exiting 1 where none is.
#   branch-scope.sh decide REPOSITORY SHA
#                              asks GitHub (with $GH_TOKEN) for the
#                              change from main's merge base to SHA and
#                              writes scope=, base= (the merge base, only
#                              on a full run) and why= to $GITHUB_OUTPUT.
#
# It never fails the run for what it cannot tell: a compare that fails, a
# diff of 300 files (the most GitHub lists) or a path the list names is
# `full`, the safe side, and a base it cannot name is `unknown`, which
# orchestration.tl's `harness_moved` takes as a moved harness.
set -u
set -f

list=${BRANCH_SCOPE_LIST:-$(cd "$(dirname "$0")" && pwd)/branch-scope.txt}

# The first line of the list that names $1 as "<path> <pattern>", else
# nothing and status 1.
match_path() {
  path=$1
  hit=
  while IFS= read -r line; do
    line=${line%%#*}
    set -- $line
    [ $# -gt 0 ] || continue
    pattern=$1
    case $pattern in
      '!'*)
        pattern=${pattern#!}
        # shellcheck disable=SC2254
        case $path in $pattern) return 1 ;; esac
        ;;
      *)
        # shellcheck disable=SC2254
        case $path in $pattern) [ -n "$hit" ] || hit=$pattern ;; esac
        ;;
    esac
  done <"$list"
  [ -n "$hit" ] || return 1
  printf '%s %s\n' "$path" "$hit"
}

match() {
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if match_path "$path"; then
      return 0
    fi
  done
  return 1
}

say() {
  # scope, base, why
  echo "branch scope: $1: $3"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "scope=$1"
      echo "base=$2"
    } >>"$GITHUB_OUTPUT"
  fi
}

decide() {
  repository=$1
  sha=$2
  if ! compared=$(gh api "repos/$repository/compare/main...$sha" 2>&1); then
    say full unknown "cannot compare $sha with main: $compared"
    return 0
  fi
  base=$(printf '%s' "$compared" | jq -r '.merge_base_commit.sha // empty') || base=
  count=$(printf '%s' "$compared" | jq -r '.files | length') || count=
  case $base in
    '' | *[!0-9a-f]*) base=unknown ;;
  esac
  case $count in
    '' | *[!0-9]*)
      say full "$base" "cannot read the files of the change"
      return 0
      ;;
  esac
  if [ "$count" -ge 300 ]; then
    say full "$base" "the change lists $count files, which GitHub stops at"
    return 0
  fi
  # A rename's old name too: moving a file out of a listed path changes it.
  files=$(printf '%s' "$compared" | jq -r '.files[] | .filename, (.previous_filename // empty)') || files=
  if hit=$(printf '%s\n' "$files" | match); then
    say full "$base" "$hit"
  else
    say light "" "no path of the change's $count files is one that list names"
  fi
}

case ${1:-} in
  match) match ;;
  decide)
    [ $# -eq 3 ] || { echo "usage: branch-scope.sh decide REPOSITORY SHA" >&2; exit 2; }
    decide "$2" "$3"
    ;;
  *)
    echo "usage: branch-scope.sh match | decide REPOSITORY SHA" >&2
    exit 2
    ;;
esac
