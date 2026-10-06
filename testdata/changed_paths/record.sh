#!/bin/sh
# Records what the system's git answers .github/scripts/changed-paths.sh,
# for build/changed_paths_test.tl to replay (run from anywhere):
#
#     sh testdata/changed_paths/record.sh
#
# A branch off main's base commit, with fixed names and dates (so the base
# is the same hash each time), is diffed against that base as the script
# does, `git diff --no-renames --name-only -z <base> HEAD --`, once for each
# change the test makes: edited.z (an edit, a removal and an added path
# holding a space), none.z (an empty commit) and linebreak.z (those with a
# path holding a line break too). `base` holds the commit's hash.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_AUTHOR_DATE="1767225600 +0000" GIT_COMMITTER_DATE="1767225600 +0000"
g() { git -C "$work" -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

g init -q
for f in kept edited removed; do echo 'return 1' > "$work/$f.tl"; done
g add . && g commit -q -m base
g rev-parse HEAD > "$here/base"
base=$(cat "$here/base")

edit() {
  echo 'return 2' > "$work/edited.tl"
  rm -f "$work/removed.tl"
  mkdir -p "$work/doc"
  echo added > "$work/doc/a b.md"
}
change() {
  g add -A && g commit -q --allow-empty -m "$1"
  g diff --no-renames --name-only -z "$base" HEAD -- > "$here/$2.z"
  g reset -q --hard "$base"
}
g checkout -q -b branch
change nothing none
edit; change edited edited
edit; printf 'return 3\n' > "$work/two
lines.tl"; change linebreak linebreak
