#!/bin/sh
# Prints the first 16 hex digits of a sha256 of what of this host every
# sandboxed verdict's key holds and differs between runners of one leg
# (build/declared_key.tl's `host_identity` and `host_features`, which
# answer the same digest): the processor's features, by the names
# /proc/cpuinfo lists them under ("flags" on x86, "Features" on arm),
# each once, in byte order, a line each, less those a core on this
# machine chooses no code by (`keep` below) -- on macOS, where there is
# no /proc, those of core/syscalls.c's `cpu_features` that sysctl
# answers 1 for (`features` below); then the kernel's release and version, as their files hold
# them -- on macOS, where there is no /proc, the system volume's
# SystemVersion.plist, which names its build, and nothing
# (`darwin_system` there).
# ci.yml names a leg's verdict cache by it, so a runner restores the
# newest cache written on a host whose keys it can reach.
#
#     sh .github/scripts/host-features.sh [CPUINFO [OSRELEASE [VERSION [MACHINE [SYSNAME]]]]]
#
# Each argument moves where that part is read from, MACHINE (`uname -m`
# by default) which features are kept, and SYSNAME (`uname -s` by
# default) where OSRELEASE and VERSION are read from when they are not
# given (empty), for a test; CPUINFO given, it is read on macOS too. A
# file that is missing is read as empty, as is none (macOS's VERSION).
set -eu

# The sha256 of standard input, as hex: sha256sum where there is one
# (coreutils, busybox), shasum on a macOS without it, as place-tree.sh
# does.
digest() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

sysname=${5:-$(uname -s 2>/dev/null || true)}
case $sysname in
  Darwin) system=/System/Library/CoreServices/SystemVersion.plist kernel='' ;;
  *) system=/proc/sys/kernel/osrelease kernel=/proc/sys/kernel/version ;;
esac
cpuinfo=${1:-}
osrelease=${2:-$system}
version=${3:-$kernel}
machine=${4:-$(uname -m 2>/dev/null || true)}

# The features a core on this machine chooses code by, as
# build/declared_key.tl's `dispatched` lists them, where `host_identity`
# says which code reads each: a feature added there is added here. A
# machine no audit has read keeps every feature.
case $machine in
  x86_64) keep='aes pclmulqdq sse4_1 ssse3' ;;
  aarch64) keep='aes asimd crc32 pmull' ;;
  *) keep='' ;;
esac
kept() {
  if [ -z "$keep" ]; then cat; return; fi
  while IFS= read -r flag; do
    case " $keep " in *" $flag "*) printf '%s\n' "$flag" ;; esac
  done
}

# The processor's features, a line or a line of them each: CPUINFO's, or
# on macOS, where there is no /proc/cpuinfo, each sysctl name
# core/syscalls.c's `cpu_features` asks there that answers 1, by the
# feature's name.
features() {
  if [ -z "$cpuinfo" ] && [ "$sysname" = Darwin ]; then
    for pair in aes:hw.optional.arm.FEAT_AES asimd:hw.optional.AdvSIMD \
        crc32:hw.optional.armv8_crc32 pmull:hw.optional.arm.FEAT_PMULL; do
      if [ "$(sysctl -n "${pair#*:}" 2>/dev/null || true)" = 1 ]; then
        printf '%s\n' "${pair%%:*}"
      fi
    done
    return 0
  fi
  sed -nE 's/^(flags|Features)[[:space:]]*:[[:space:]]*//p' "${cpuinfo:-/proc/cpuinfo}" 2>/dev/null || true
}

# Into a variable, then checked: `set -e` sees only a pipeline's last
# command, so a digest tool missing would otherwise print a blank name
# and exit 0.
named=$({
  features |
    tr -s ' \t' '\n\n' | sed '/^$/d' | LC_ALL=C sort -u | kept
  if [ -n "$osrelease" ]; then cat "$osrelease" 2>/dev/null || true; fi
  if [ -n "$version" ]; then cat "$version" 2>/dev/null || true; fi
} | digest 2>/dev/null | cut -c1-16)
case $named in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "host-features.sh: no sha256 of the host's features: neither sha256sum nor shasum on PATH?" >&2; exit 1 ;;
esac
echo "$named"
