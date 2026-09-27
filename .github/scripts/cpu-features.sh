#!/bin/sh
# Prints the first 16 hex digits of a sha256 of the processor features
# this host lists in /proc/cpuinfo ("flags" on x86, "Features" on
# arm), each once, sorted: the set build/declared_key.tl's
# `host_identity` keys every sandboxed verdict by. ci.yml names a Linux
# leg's verdict cache by it, so a runner restores the newest cache
# written on a host of the same features rather than one whose every
# key its own host cannot reach: GitHub's x86_64 runners of one image
# land on processors of more than one feature set.
#
#     sh .github/scripts/cpu-features.sh
set -eu

sed -nE 's/^(flags|Features)[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo |
  tr -s ' \t' '\n\n' | sed '/^$/d' | sort -u | sha256sum | cut -c1-16
