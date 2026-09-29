#!/bin/sh
# Moves the checkout to a path of this commit's and this leg's own, for a
# job that builds or tests the tree, as the user the job's steps run as:
#
#     sh .github/scripts/place-tree.sh           move the checkout there
#     sh .github/scripts/place-tree.sh --name    only say where, under
#                                                $GITHUB_WORKSPACE's parent
#     sh .github/scripts/place-tree.sh --restore move it back, if it moved
#
# A test must not depend on where the tree is (AGENTS.md): a verdict is
# shared between checkouts, which key an in-tree path by its name under
# the tree. So the tree moves beside $GITHUB_WORKSPACE, to a directory
# whose name, its length and its digits, a sha256 of the commit
# ($GITHUB_SHA) and the leg ($COSMIC_WORKER) chooses. A re-run of a
# commit meets the same path, so a failure it finds is found again; a
# new commit meets a new one, so a test that turns on the tree's
# absolute path fails some run rather than none. The log names both
# inputs and the path, and `--name` with the same two gives it again.
#
# TODO: choose the macOS leg's path by the leg alone, or decide to keep
# paying for a path chosen by the commit there: an unsandboxed worker's
# key holds the tree's path (build/declared_key.tl's `Spec.tree`), so on
# that leg every test runs on every new commit and stands only on a
# re-run's verdicts; a path fixed per leg would stand across commits,
# and a checkout moved elsewhere would still run every test.
#
# Only the name varies, never the depth: the tree is always one
# directory below $GITHUB_WORKSPACE's parent, as deep as the workspace
# itself. actions/cache names a path outside the workspace, such as
# $RUNNER_TEMP (<work>/_temp beside <work>/<repo>/<repo>), relative to
# $GITHUB_WORKSPACE (`../../_temp/...`, by `path.relative`) and archives
# it with `tar -C $GITHUB_WORKSPACE`, which enters the link: from a tree
# any deeper, `../..` names a directory under <work>/<repo> instead, and
# the save finds nothing. At depth one it names <work> as it would
# unmoved, so the saves run with the tree moved. That costs nothing a
# varied depth would catch: the absolute path still moves by commit and
# leg, which is what fails a test that depends on it, and a sandboxed
# worker sees the tree at /tree wherever it is.
#
# $GITHUB_WORKSPACE becomes a link to it, relative so it resolves both
# in a job container and on its host: what a job reads from there (a
# local action, a later step's working directory) is the tree, and
# whatever resolves the path -- the driver's root
# (ci/cosmic_ci/context.tl), a process's working directory -- is the new
# one. So it moves only what is under $GITHUB_WORKSPACE's parent, which
# the job's user owns.
#
# The job's last step, whatever came before it, runs `--restore`, which
# puts the tree back at $GITHUB_WORKSPACE before the post steps run: the
# checkout's resolves the path too, and a git that finds a repository
# at a path other than the one it was told is safe refuses it (git
# 2.43's "dubious ownership"), which leaves the checkout's credentials
# in its config. It removes the link, and changes nothing when the tree
# never moved, or is back already, so it can run twice, or after a move
# that stopped halfway.
set -eu

case "${1-}" in
  "" | --name | --restore) ;;
  *) echo "usage: place-tree.sh [--name | --restore]" >&2; exit 2 ;;
esac
[ -n "${GITHUB_SHA-}" ] || { echo "place-tree.sh: GITHUB_SHA is not set" >&2; exit 2; }
[ -n "${COSMIC_WORKER-}" ] || { echo "place-tree.sh: COSMIC_WORKER is not set" >&2; exit 2; }

# The sha256 of standard input, as 64 hex digits: sha256sum on Linux
# (coreutils, or Alpine's busybox), shasum on a macOS without it.
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi |
    cut -c1-64
}

# Byte `$2` (from 0) of the digest `$1`, as a number from 0 to 255.
byte() {
  hex=$(printf %s "$1" | cut -c$(( $2 * 2 + 1 ))-$(( $2 * 2 + 2 )))
  echo $(( 0x$hex ))
}

# TODO: put a space in a name too, to catch a path left unquoted, once
# ci/run-local runs the driver from a path with one (its drop_env is
# split on spaces) and shows its phases take it: the suite itself does.
seed=$(printf 'commit %s\nleg %s\n' "$GITHUB_SHA" "$COSMIC_WORKER" | digest)
length=$(( $(byte "$seed" 0) % 24 + 1 ))
relative=$(printf '%s 1\n' "$seed" | digest | cut -c1-"$length")

if [ "${1-}" = --name ]; then
  echo "$relative"
  exit 0
fi

[ -n "${GITHUB_WORKSPACE-}" ] || { echo "place-tree.sh: GITHUB_WORKSPACE is not set" >&2; exit 2; }
parent=$(dirname "$GITHUB_WORKSPACE")
tree="$parent/$relative"

if [ "${1-}" = --restore ]; then
  if [ -L "$GITHUB_WORKSPACE" ]; then
    link=$(readlink "$GITHUB_WORKSPACE")
    if [ "$link" != "$relative" ]; then
      echo "place-tree.sh: $GITHUB_WORKSPACE links to $link, not $relative" >&2
      exit 1
    fi
    rm "$GITHUB_WORKSPACE"
  fi
  if [ ! -e "$GITHUB_WORKSPACE" ] && [ -d "$tree" ]; then
    mv "$tree" "$GITHUB_WORKSPACE"
    echo "the tree is back at $GITHUB_WORKSPACE from $tree"
  fi
  exit 0
fi

# Placed already, as by a step that runs twice: nothing to move.
if [ -L "$GITHUB_WORKSPACE" ] && [ "$(readlink "$GITHUB_WORKSPACE")" = "$relative" ]; then
  echo "the tree is at $tree already"
  exit 0
fi
mv "$GITHUB_WORKSPACE" "$tree"
ln -s "$relative" "$GITHUB_WORKSPACE"
echo "the tree is at $tree (commit $GITHUB_SHA, leg $COSMIC_WORKER)"
