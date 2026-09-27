#!/bin/sh
# Prints the first 16 hex digits of a sha256 of what of this host every
# sandboxed verdict's key holds and differs between runners of one leg
# (build/declared_key.tl's `host_identity` and `host_features`, which
# answer the same digest): the processor features /proc/cpuinfo lists
# ("flags" on x86, "Features" on arm), each once, in byte order, a line
# each; then the kernel's release and version, as their files hold them.
# ci.yml names a Linux leg's verdict cache by it, so a runner restores
# the newest cache written on a host whose keys it can reach.
#
#     sh .github/scripts/host-features.sh [CPUINFO [OSRELEASE [VERSION]]]
#
# Each argument moves where that part is read from, for a test. A file
# that is missing is read as empty: a host without /proc/cpuinfo prints
# the digest of no features, which every such host shares, as its key
# does.
set -eu

# The sha256 of standard input, as hex: sha256sum where there is one
# (coreutils, busybox), shasum on a macOS without it, as place-tree.sh
# does.
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

cpuinfo=${1:-/proc/cpuinfo}
osrelease=${2:-/proc/sys/kernel/osrelease}
version=${3:-/proc/sys/kernel/version}

# Into a variable, then checked: `set -e` sees only a pipeline's last
# command, so a digest tool missing would otherwise print a blank name
# and exit 0.
named=$({
  { sed -nE 's/^(flags|Features)[[:space:]]*:[[:space:]]*//p' "$cpuinfo" 2>/dev/null || true; } |
    tr -s ' \t' '\n\n' | sed '/^$/d' | LC_ALL=C sort -u
  cat "$osrelease" 2>/dev/null || true
  cat "$version" 2>/dev/null || true
} | digest 2>/dev/null | cut -c1-16)
case $named in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "host-features.sh: no sha256 of the host's features: neither sha256sum nor shasum on PATH?" >&2; exit 1 ;;
esac
echo "$named"
