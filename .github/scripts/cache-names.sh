#!/bin/sh
# GitHub's hashFiles expressions in the cache-names action supply the
# hashes. Run before build-cache restores or tree relocation so trimming
# counts every row this run uses.
set -eu

echo "vendor=zig-build-$LEG-$VENDOR-" >> "$GITHUB_OUTPUT"
echo "core=$CORE" >> "$GITHUB_OUTPUT"
echo "image=${ImageOS:-}-${ImageVersion:-}" >> "$GITHUB_OUTPUT"
echo "since=$(date +%s)" >> "$GITHUB_OUTPUT"
echo "compiles=compiles-branch-$LEG-$COMPILER-" >> "$GITHUB_OUTPUT"
