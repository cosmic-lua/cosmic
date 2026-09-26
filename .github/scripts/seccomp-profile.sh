#!/bin/sh
# Writes the seccomp profile ci.yml's Linux legs run their container
# under: Docker's own default, with just the calls spawn's sandbox
# (core/process.h's `Sandbox`) makes allowed outright -- unshare, mount,
# umount2, mount_setattr and pivot_root. The default allows the first
# four only to a container holding CAP_SYS_ADMIN and pivot_root to none,
# so a confined child's new user namespace is refused with EPERM; every
# other rule of the default stays as it is.
#
#     sh .github/scripts/seccomp-profile.sh OUT       narrow the default into OUT
#     sh .github/scripts/seccomp-profile.sh --fetch   fetch the default again
#
# The default is .github/seccomp/default.json: moby/profiles'
# seccomp/default.json (where Docker's default lives since moby moved it
# out of its own tree) at the commit below, kept in the tree so a leg
# fetches nothing, and checked by its sha256 before it is narrowed.
# `--fetch` writes it again from that commit, checked the same way: a
# newer default is taken by moving both below, fetching, and committing
# what it wrote.
set -eu

commit=85e237f1fe229a0c61c9c7d8e743fa780d3b97ca
url=https://raw.githubusercontent.com/moby/profiles/$commit/seccomp/default.json
digest=785b2429264afba4d594320337cb17f144f3c7d51585f9805eef72e28f4f9334
default=$(dirname "$0")/../seccomp/default.json

# Refuses `$1` unless it is the pinned default, byte for byte.
check() {
  got=$(sha256sum "$1" | cut -d' ' -f1)
  if [ "$got" != "$digest" ]; then
    echo "seccomp-profile.sh: $1 has sha256 $got, not moby/profiles@$commit's $digest" >&2
    exit 1
  fi
}

[ $# -eq 1 ] || { echo "usage: seccomp-profile.sh OUT | --fetch" >&2; exit 2; }

if [ "$1" = --fetch ]; then
  curl -fsSL --max-time 60 --retry 3 "$url" -o "$default.new"
  check "$default.new"
  mv "$default.new" "$default"
  echo "seccomp default: $url at $default"
  exit 0
fi

out=$1
check "$default"
python3 - "$default" "$out" <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
profile["syscalls"].append({"names": ["unshare", "mount", "umount2", "mount_setattr",
                                      "pivot_root"], "action": "SCMP_ACT_ALLOW"})
json.dump(profile, open(sys.argv[2], "w"))
PY
echo "seccomp profile: moby/profiles@$commit's default (sha256 $digest), with unshare, mount, umount2, mount_setattr and pivot_root allowed, at $out"
