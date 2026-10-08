#!/bin/sh
# Runs only the credential-transition proof as root. The candidate and
# helper were built by the ordinary unprivileged CI step.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'credentials proof requires root' >&2; exit 1; }
root=$(pwd -P)
output=$(cat "${RUNNER_TEMP:?}/cosmic-credentials-output")
case "$output" in /*) ;; *) echo 'credential output must be absolute' >&2; exit 1 ;; esac
[ -x "$output/bin/cosmic" ] && [ -x "$output/credentials-probe" ]
proof=$(mktemp -d)
trap 'rm -rf "$proof"' EXIT HUP INT TERM
chmod 755 "$proof"
mkdir "$proof/secret" "$proof/target" "$proof/cache"
chmod 700 "$proof/secret" "$proof/target" "$proof/cache"
# The root proof must not reuse or re-own the ordinary runner's cache.
export XDG_CACHE_HOME="$proof/cache"
export COSMIC_PORTABLE_CACHE="$proof/cache/cores"
export COSMIC_BUILD_HOME="$proof/build-home"
printf 'grant\n' > "$proof/secret/file"
chmod 600 "$proof/secret/file"
chown 65532:65532 "$proof/target"
cp "$output/credentials-probe" "$proof/probe"
chmod 755 "$proof/probe"
cp "$proof/probe" "$proof/setuid-probe"
chmod 4755 "$proof/setuid-probe"
export COSMIC_AUTO_BOOT=0
for mode in success groups gid uid caps nnp capture restore; do
  timeout 20 "$proof/probe" setup "$mode" "$output/bin/cosmic" \
    "$root/build/credentials_proof.tl" "$proof/probe" "$proof"
done
