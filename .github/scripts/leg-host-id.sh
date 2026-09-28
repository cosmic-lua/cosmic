#!/bin/sh
# Names a CI leg's host, for ci.yml's "name the leg's host": what of it
# no file on it tells, which every declared-key verdict's key holds
# (build/declared_key.tl's `host_identity`, through COSMIC_HOST_ID), and
# the name of the leg's verdict cache, which that and the host's
# features, FEATURES (what .github/scripts/host-features.sh prints),
# make.
#
#     sh .github/scripts/leg-host-id.sh NAME IMAGE RUNNER STARTED FEATURES
#
# NAME is the leg's (matrix.name). On a Linux leg, IMAGE is its
# container's image and STARTED a hash of how the container is started
# (ci.yml's hashFiles of leg-container.sh, seccomp-profile.sh and the
# seccomp profile), and COSMIC_HOST_ID is those two and the container
# engine's version. The macOS leg, which has no container (IMAGE
# empty), is named by RUNNER, the image label it runs on (macos-15),
# which names the OS release; its kernel and sealed system volume key
# themselves (SystemVersion.plist, read by host_identity and by
# host-features.sh), and what the image installs beside them -- Xcode,
# /opt/homebrew, /usr/local -- goes in COSMIC_SYSTEM_ID as the runner
# names the image ("$ImageOS $ImageVersion"), which only a key of a
# module given the system's paths holds (`system_identity`): an image
# update that moves only those restores the cache and reruns only such
# modules, and one that moves the OS build names a new cache.
#
# It appends COSMIC_HOST_ID, and COSMIC_SYSTEM_ID on macOS, to
# $GITHUB_ENV, and to $GITHUB_OUTPUT `prefix`,
# verdicts-NAME-<16 hex of COSMIC_HOST_ID's sha256>-, and `verdicts`,
# that, FEATURES and a `-`: the prefix a restore of the leg's verdicts
# falls back to. Each defaults to standard output, for a run by hand.
# FEATURES that are not 16 hex digits (host-features.sh failed, which
# the command substitution that passes them does not stop for) are
# refused, as are a leg with neither IMAGE nor RUNNER, and one with no
# IMAGE where the runner names no image (ImageOS or ImageVersion unset
# or empty), before anything is written.
set -eu

usage="usage: leg-host-id.sh NAME IMAGE RUNNER STARTED FEATURES"
[ $# -eq 5 ] || { echo "$usage" >&2; exit 2; }
name=$1 image=$2 runner=$3 started=$4 features=$5
env_file=${GITHUB_ENV:-/dev/stdout}
out=${GITHUB_OUTPUT:-/dev/stdout}
case $features in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "leg-host-id.sh: FEATURES are no 16 hex digits: '$features'" >&2; exit 2 ;;
esac
if [ -z "$image" ]; then
  [ -n "$runner" ] ||
    { echo "leg-host-id.sh: a leg with no image names no RUNNER" >&2; exit 2; }
  [ -n "${ImageOS:-}" ] && [ -n "${ImageVersion:-}" ] ||
    { echo "leg-host-id.sh: a leg with no image needs ImageOS and ImageVersion" >&2; exit 2; }
fi

# As host-features.sh's: sha256sum where there is one, else macOS's shasum.
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

if [ -n "$image" ]; then
  id="$image $started docker-$(docker version --format '{{.Server.Version}}')"
else
  id=$runner
  echo "COSMIC_SYSTEM_ID=$ImageOS $ImageVersion" >> "$env_file"
fi
echo "COSMIC_HOST_ID=$id" >> "$env_file"
hashed=$(printf %s "$id" | digest | cut -c1-16)
[ ${#hashed} -eq 16 ] ||
  { echo "leg-host-id.sh: no sha256: neither sha256sum nor shasum on PATH?" >&2; exit 1; }
prefix="verdicts-$name-$hashed-"
echo "prefix=$prefix" >> "$out"
echo "verdicts=$prefix$features-" >> "$out"
