#!/bin/sh
# Moves the checkout to a path of this run's own, for a job that builds
# or tests the tree, as the user the job's steps run as:
#
#     sh .github/scripts/place-tree.sh
#
# A test must not depend on where the tree is (AGENTS.md): a verdict is
# shared between checkouts, which key an in-tree path by its name under
# the tree. So each run moves the tree beside $GITHUB_WORKSPACE, one to
# three directories deep, each name of its own length, and a test that
# turns on the tree's absolute path fails some run rather than none.
# The path is in the log, to check such a failure out there again.
#
# $GITHUB_WORKSPACE becomes a link to it, relative so it resolves both
# in a job container and on its host: what a job reads from there (a
# local action, a later step's working directory, the checkout's post
# step) is the tree, and whatever resolves the path -- the driver's root
# (ci/cosmic_ci/context.tl), a process's working directory -- is the new
# one. So it moves only what is under $GITHUB_WORKSPACE's parent, which
# the job's user owns.
set -e

# One byte from /dev/urandom, as a number from 0 to 255.
byte() {
  od -An -tu1 -N1 /dev/urandom | tr -d ' \n'
}

# `$1` characters, each a random hex digit.
# TODO: put a space in a name too, to catch a path left unquoted, once
# ci/run-local runs the driver from a path with one (its drop_env is
# split on spaces) and shows its phases take it: the suite itself does.
name() {
  od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n' | cut -c1-"$1"
}

parent=$(dirname "$GITHUB_WORKSPACE")
relative=""
depth=$(( $(byte) % 3 + 1 ))
while [ "$depth" -gt 0 ]; do
  relative="$relative${relative:+/}$(name $(( $(byte) % 24 + 1 )))"
  depth=$(( depth - 1 ))
done
tree="$parent/$relative"

mkdir -p "$(dirname "$tree")"
mv "$GITHUB_WORKSPACE" "$tree"
ln -s "$relative" "$GITHUB_WORKSPACE"
echo "the tree is at $tree"
