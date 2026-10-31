#!/bin/sh
# Build the credential proof's helper beside the candidate tool, in the
# build directory build/paths.tl names under this step's environment,
# and publish that directory to the proof step (COSMIC_CREDENTIALS_BUILD,
# through $GITHUB_ENV): the proof runs as root with a cache of its own,
# under which the resolver would name another directory, and refuses
# this user's.
set -eu
root=$(pwd -P)
output=$("$root/bin/cosmic-bootstrap" --standalone "$root/build/paths.tl" "$root")
"$root/bin/zig" cc -std=c11 -Wall -Wextra -Werror -O2 \
  "$root/.github/scripts/credentials-probe.c" -o "$output/credentials-probe"
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'COSMIC_CREDENTIALS_BUILD=%s\n' "$output" >> "$GITHUB_ENV"
fi
printf '%s\n' "$output"
