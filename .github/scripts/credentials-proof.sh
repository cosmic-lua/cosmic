#!/bin/sh
# Runs only the credential-transition proof as root. The candidate and
# helper were built by the ordinary unprivileged CI step.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'credentials proof requires root' >&2; exit 1; }
root=$(pwd -P)
proof=$(mktemp -d)
trap 'rm -rf "$proof"' EXIT HUP INT TERM
chmod 755 "$proof"
mkdir "$proof/secret" "$proof/target" "$proof/cache"
chmod 700 "$proof/secret" "$proof/target" "$proof/cache"
# The candidate and helper are where the build step built them, under
# its own environment (credentials-build.sh): resolved here, as root
# with the cache below, the build directory would be another.
output=${COSMIC_CREDENTIALS_BUILD:?set by .github/scripts/credentials-build.sh}
# The root proof must not reuse or re-own the ordinary runner's cache.
export XDG_CACHE_HOME="$proof/cache"
export COSMIC_PORTABLE_CACHE="$proof/cache/cores"
# The proof driver needs cosmic.* alone: run it as `--standalone` does,
# so root builds nothing, in this user's build directory or its own.
export COSMIC_STANDALONE=1
printf 'grant\n' > "$proof/secret/file"
chmod 600 "$proof/secret/file"
chown 65532:65532 "$proof/target"
# The build directory is its user's alone (0700): the target user runs
# the helper from a copy here, as it does the setuid one.
cp "$output/credentials-probe" "$proof/helper"
chmod 755 "$proof/helper"
cp "$output/credentials-probe" "$proof/setuid-probe"
chmod 4755 "$proof/setuid-probe"
export COSMIC_AUTO_BOOT=0
for mode in success groups gid uid caps nnp capture restore; do
  timeout 20 "$output/credentials-probe" setup "$mode" "$output/bin/cosmic" \
    "$root/build/credentials_proof.tl" "$proof/helper" "$proof"
done
