#!/bin/sh
# Build the credential proof's helper beside the candidate tool.
set -eu
root=$(pwd -P)
output=$("$root/bin/cosmic-bootstrap" --standalone "$root/build/paths.tl" "$root")
"$root/bin/zig" cc -std=c11 -Wall -Wextra -Werror -O2 \
  "$root/.github/scripts/credentials-probe.c" -o "$output/credentials-probe"
