#!/bin/sh
set -eu
# This file is a template. pack.sh supplies the case arms and payload ranges.
die() { printf 'cosmic portable: %s\n' "$*" >&2; exit 1; }
case $0 in /*) artifact=$0;; *) artifact=$PWD/$0;; esac
case $(uname -s):$(uname -m) in
@TARGETS@
  *) die "unsupported target";;
esac
# A caller-supplied PRIVATE cache is deliberate for this experiment. Cache
# ownership/permissions and lifecycle are not yet a production interface.
cache=${COSMIC_PORTABLE_CACHE:?set COSMIC_PORTABLE_CACHE to a private directory}
[ -d "$cache" ] || die "cache directory does not exist: $cache"
core=$cache/$digest
sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f1
  else
    shasum -a 256 "$1" | cut -d ' ' -f1
  fi
}
if [ ! -x "$core" ]; then
  umask 077
  stage=$(mktemp -d "$cache/.stage.XXXXXXXX")
  trap 'rm -rf "$stage"' EXIT
  trap 'exit 1' HUP INT TERM
  # Aligned ranges avoid dd bs=1. Trim the final block: Mach-O signatures
  # must remain exactly the signed bytes, with no padding appended.
  dd if="$artifact" bs=16384 skip="$block" count="$blocks" 2>/dev/null |
    head -c "$length" > "$stage/core"
  [ "$(sha "$stage/core")" = "$digest" ] || die "extracted core checksum differs"
  chmod 500 "$stage/core"
  # Link, rather than overwrite: simultaneous cold starts keep the winner.
  if ! ln "$stage/core" "$core" 2>/dev/null; then
    [ -x "$core" ] || die "cannot publish core"
  fi
  rm -rf "$stage"
  trap - EXIT HUP INT TERM
fi
exec "$core" --artifact "$artifact" "$@"
exit 127
