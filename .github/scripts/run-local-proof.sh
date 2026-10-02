#!/bin/sh
# Only this runner fixture runs as root; its fake phases prove they dropped.
set -eu
root=$(pwd -P)
driver=$(bin/cosmic-bootstrap)
proof=$(mktemp -d)
trap 'rm -rf "$proof"' EXIT HUP INT TERM
# A root proof cannot reuse the ordinary runner's portable core cache.
export XDG_CACHE_HOME="$proof/cache"
export COSMIC_PORTABLE_CACHE="$proof/cores"
"$driver" --standalone "$root/ci/run_local_proof.tl" "$root" "$driver"
