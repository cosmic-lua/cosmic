#!/bin/sh
# Moves the checkout to a path of this commit's and this leg's own, for a
# job that builds or tests the tree, as the user the job's steps run as:
#
#     sh .github/scripts/place-tree.sh           move the checkout there
#     sh .github/scripts/place-tree.sh --name    only say where, under
#                                                $GITHUB_WORKSPACE's parent
#
# A test must not depend on where the tree is (AGENTS.md): a verdict is
# shared between checkouts, which key an in-tree path by its name under
# the tree. So the tree moves beside $GITHUB_WORKSPACE, one to three
# directories deep, each name of its own length, all chosen by a sha256
# of the commit ($GITHUB_SHA) and the leg ($COSMIC_WORKER). A re-run of
# a commit meets the same path, so a failure it finds is found again; a
# new commit meets a new one, so a test that turns on the tree's
# absolute path fails some run rather than none. The log names both
# inputs and the path, and `--name` with the same two gives it again.
#
# $GITHUB_WORKSPACE becomes a link to it, relative so it resolves both
# in a job container and on its host: what a job reads from there (a
# local action, a later step's working directory, the checkout's post
# step) is the tree, and whatever resolves the path -- the driver's root
# (ci/cosmic_ci/context.tl), a process's working directory -- is the new
# one. So it moves only what is under $GITHUB_WORKSPACE's parent, which
# the job's user owns.
set -e

case "${1-}" in
  "" | --name) ;;
  *) echo "usage: place-tree.sh [--name]" >&2; exit 2 ;;
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
relative=""
depth=$(( $(byte "$seed" 0) % 3 + 1 ))
at=1
while [ "$at" -le "$depth" ]; do
  length=$(( $(byte "$seed" "$at") % 24 + 1 ))
  name=$(printf '%s %s\n' "$seed" "$at" | digest | cut -c1-"$length")
  relative="$relative${relative:+/}$name"
  at=$(( at + 1 ))
done

if [ "${1-}" = --name ]; then
  echo "$relative"
  exit 0
fi

parent=$(dirname "$GITHUB_WORKSPACE")
tree="$parent/$relative"
mkdir -p "$(dirname "$tree")"
mv "$GITHUB_WORKSPACE" "$tree"
ln -s "$relative" "$GITHUB_WORKSPACE"
echo "the tree is at $tree (commit $GITHUB_SHA, leg $COSMIC_WORKER)"
