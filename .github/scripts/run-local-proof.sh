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
# COSMIC_GRAMMAR=new: the pinned release reads the new grammar of ci/ as Teal
# otherwise. Not bin/cosmic-bootstrap's args form, which would fetch the pin
# again into the cache exported above. The proof sets it again for the runner
# it starts with the same binary.
env COSMIC_GRAMMAR=new "$driver" --standalone "$root/ci/run_local_proof.tl" "$root" "$driver"
