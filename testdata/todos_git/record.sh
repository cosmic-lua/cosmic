#!/bin/sh
# Records the answers of the system's git that build/todos_git_test.tl
# replays, into this directory's scenarios (run from anywhere):
#
#     sh testdata/todos_git/record.sh
#
# Each scenario is a repository built with fixed names and dates, so a
# run records the same hashes again; each step it records holds what
# `cosmic todos` asks of git at that HEAD:
#   head            `git rev-parse --verify -q HEAD`
#   ancestors       `git rev-list HEAD`, which `merge-base --is-ancestor` answers from
#   diff-<old>      `git diff --name-only --no-renames --relative <old> HEAD --`
#   <file>.blame     `git blame --line-porcelain -L <n>,<n>... [--ignore-revs-file F] -- <file>`
#                   (a "/" in the file's name is "_")
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
tick=1767225600
# The line ranges `blame` is asked for, as the verb asks one per TODO.
ranges="-L 1,1"

g() { git -C "$repo" -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# commit <message> [<git commit options>]: a commit one minute after the last.
commit() {
  tick=$((tick + 60))
  GIT_AUTHOR_DATE="$tick +0000" GIT_COMMITTER_DATE="$tick +0000" \
    g commit -q "$@"
}

# record <dir> <root> <ignore-file or ""> <earlier heads> -- <files>: the answers
# for the tree at <root> (the repository, a directory in it or a worktree of it).
record() {
  dir=$1 root=$2 ignore=$3
  shift 3
  mkdir -p "$dir"
  git -C "$root" rev-parse --verify -q HEAD > "$dir/head"
  git -C "$root" rev-list HEAD > "$dir/ancestors"
  while [ "$1" != -- ]; do
    git -C "$root" diff --name-only --no-renames --relative "$1" HEAD -- > "$dir/diff-$1" || true
    shift
  done
  shift
  for file in "$@"; do
    name=$(printf %s "$file" | tr / _)
    if [ -n "$ignore" ]; then
      git -C "$root" blame --line-porcelain --ignore-revs-file "$ignore" $ranges -- "$file" > "$dir/$name.blame"
    else
      git -C "$root" blame --line-porcelain $ranges -- "$file" > "$dir/$name.blame"
    fi
  done
}

# carries: blame moves on across commits that leave a file alone, and is
# made again for one they touch and for every file after an amended commit.
repo=$work/carries
mkdir -p "$repo" && g init -q
echo '-- TODO: first' > "$repo/a.tl"
echo '-- TODO: second' > "$repo/b.tl"
g add . && commit -m one
h1=$(g rev-parse HEAD)
record "$here/carries/1" "$repo" "" -- a.tl b.tl
echo 'local c = 3' > "$repo/c.tl"
g add c.tl && commit -m two
h2=$(g rev-parse HEAD)
record "$here/carries/2" "$repo" "" "$h1" -- a.tl b.tl
echo '-- TODO: second, reworded' > "$repo/b.tl"
commit -a -m three
h3=$(g rev-parse HEAD)
record "$here/carries/3" "$repo" "" "$h1" "$h2" -- a.tl b.tl
commit -a --amend -m 'three again'
record "$here/carries/4" "$repo" "" "$h1" "$h2" "$h3" -- a.tl b.tl

# ignores: a commit .git-blame-ignore-revs lists is passed over.
repo=$work/ignores
mkdir -p "$repo" && g init -q
echo '-- TODO: see `x`' > "$repo/a.tl"
g add . && commit -m one
echo '-- TODO: see [`x`]' > "$repo/a.tl"
commit -a -m sweep
sweep=$(g rev-parse HEAD)
record "$here/ignores/1" "$repo" "" -- a.tl
g rev-parse HEAD > "$repo/.git-blame-ignore-revs"
g add .git-blame-ignore-revs && commit -m 'ignore the sweep'
record "$here/ignores/2" "$repo" "$repo/.git-blame-ignore-revs" "$sweep" -- a.tl

# placed: a tree below its repository's root, and a worktree's checkout.
repo=$work/placed
mkdir -p "$repo/sub" && g init -q
echo '-- TODO: below the root' > "$repo/sub/a.tl"
g add . && commit -m one
record "$here/placed/below" "$repo/sub" "" -- a.tl
g worktree add -q "$work/worktree"
record "$here/placed/worktree" "$work/worktree" "" -- sub/a.tl

# pair: one file's two TODOs, from two commits, blamed in one call.
repo=$work/pair
mkdir -p "$repo" && g init -q
echo '-- TODO: first' > "$repo/a.tl"
g add . && commit -m one
printf '%s\n' '-- TODO: first' 'local x = 1' '-- TODO: third' > "$repo/a.tl"
commit -a -m two
ranges="-L 1,1 -L 3,3"
record "$here/pair/1" "$repo" "" -- a.tl
