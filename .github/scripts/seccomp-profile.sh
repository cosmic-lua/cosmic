#!/bin/sh
# Writes the seccomp profile ci.yml's Linux legs run their container
# under: Docker's own default, with just the calls spawn's sandbox
# (core/process.h's `Sandbox`) makes allowed outright -- unshare, mount,
# umount2, mount_setattr and pivot_root. The default allows the first
# four only to a container holding CAP_SYS_ADMIN and pivot_root to none,
# so a confined child's new user namespace is refused with EPERM; every
# other rule of the default stays as it is.
#
#     sh .github/scripts/seccomp-profile.sh OUT
#
# The default is moby/profiles' seccomp/default.json (where Docker's
# default lives since moby moved it out of its own tree) at a fixed
# commit, checked by its sha256 before it is narrowed: a newer default
# is taken by moving both below, not by whatever the branch holds.
set -eu

[ $# -eq 1 ] || { echo "usage: seccomp-profile.sh OUT" >&2; exit 2; }
out=$1

url=https://raw.githubusercontent.com/moby/profiles/85e237f1fe229a0c61c9c7d8e743fa780d3b97ca/seccomp/default.json
digest=785b2429264afba4d594320337cb17f144f3c7d51585f9805eef72e28f4f9334

curl -fsSL --max-time 60 --retry 3 "$url" -o "$out.default"
got=$(sha256sum "$out.default" | cut -d' ' -f1)
if [ "$got" != "$digest" ]; then
  echo "seccomp-profile.sh: $url has sha256 $got, not the pinned $digest" >&2
  exit 1
fi
python3 - "$out.default" "$out" <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
profile["syscalls"].append({"names": ["unshare", "mount", "umount2", "mount_setattr",
                                      "pivot_root"], "action": "SCMP_ACT_ALLOW"})
json.dump(profile, open(sys.argv[2], "w"))
PY
rm "$out.default"
echo "seccomp profile: $url (sha256 $digest), with unshare, mount, umount2, mount_setattr and pivot_root allowed, at $out"
