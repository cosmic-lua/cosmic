#!/bin/sh
# Says which `docker create` options let an unprivileged user in a job
# container do what spawn's sandbox does (core/process.h's `Sandbox`):
# make a user and network namespace, and mount and pivot_root in it.
# ci.yml's sandbox-options job runs it on the runner host itself, where
# the platform job's container options are chosen, for the image the
# Linux legs run in:
#
#     sh .github/scripts/sandbox-options.sh IMAGE
#
# A table goes to the run's summary ($GITHUB_STEP_SUMMARY, else stdout):
# the host's switches, then for each set of options whether each step
# held, or what the container said. It reports and fails nothing: an
# option the host refuses is a finding.
set -u

[ $# -eq 1 ] || { echo "usage: sandbox-options.sh IMAGE" >&2; exit 2; }
image=$1
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}

# A switch's value, or "absent" where the host has none.
switch() {
  if [ -r "$1" ]; then tr -d '\n' < "$1"; else printf absent; fi
}

# What a command run as nobody in a container with options $1 said: "held"
# when it exited 0, else its last line, with no pipe to end a table cell.
tried() {
  # shellcheck disable=SC2086 # $1 is a list of options, split on purpose
  said=$(docker run --rm --user 65534:65534 $1 "$image" sh -c "$2" 2>&1) &&
    { printf held; return; }
  printf '%s' "$said" | tail -n 1 | tr '|' '/'
}

namespaces='unshare --user --net true'
# unshare(1) makes the new mount namespace's propagation private, as
# spawn's sandbox does before it builds a root.
mounts='unshare --user --map-root-user --mount --net sh -e -c "mount -t tmpfs t /tmp; mkdir /tmp/old; pivot_root /tmp /tmp/old"'

# The narrowest seccomp profile to try: Docker's own default, which
# allows unshare, mount and the like only to a container holding
# CAP_SYS_ADMIN and pivot_root to none, with just the calls the sandbox
# makes allowed outright. The default is the one this host's Docker
# version was released with (moby/moby's profiles/seccomp/default.json
# at its tag), or, for a Docker whose tree no longer holds it there,
# moby/profiles' current one.
version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)
profile=${RUNNER_TEMP:-/tmp}/sandbox-seccomp.json
narrow=""
source=""
for url in "https://raw.githubusercontent.com/moby/moby/v$version/profiles/seccomp/default.json" \
    "https://raw.githubusercontent.com/moby/profiles/main/seccomp/default.json"; do
  if curl -fsSL "$url" -o "$profile.default" 2>/dev/null; then
    python3 - "$profile.default" "$profile" <<'PY' && narrow="--security-opt seccomp=$profile" && source=$url
import json, sys
profile = json.load(open(sys.argv[1]))
profile["syscalls"].append({"names": ["unshare", "mount", "umount2", "mount_setattr",
                                      "pivot_root"], "action": "SCMP_ACT_ALLOW"})
json.dump(profile, open(sys.argv[2], "w"))
PY
    break
  fi
done

{
  printf '## Container options for a sandbox (%s)\n\n' "$(uname -m)"
  printf '| Host | |\n|---|---|\n'
  printf '| kernel | %s |\n' "$(uname -r)"
  printf '| docker | %s |\n' "$version"
  printf '| default seccomp profile narrowed | %s |\n' "${source:-none found}"
  printf '| AppArmor enabled | %s |\n' "$(switch /sys/module/apparmor/parameters/enabled)"
  for name in kernel/apparmor_restrict_unprivileged_userns kernel/unprivileged_userns_clone \
      user/max_user_namespaces; do
    printf '| %s | %s |\n' "$(echo "$name" | tr / .)" "$(switch "/proc/sys/$name")"
  done
  printf '\n| Options | user and network namespace | mount and pivot_root in it |\n'
  printf '|---|---|---|\n'
  for options in "" "--security-opt seccomp=unconfined" "--security-opt apparmor=unconfined" \
      "--security-opt seccomp=unconfined --security-opt apparmor=unconfined" \
      "${narrow:-no-narrow-profile}" "${narrow:-no-narrow-profile} --security-opt apparmor=unconfined"; do
    case $options in
      no-narrow-profile*)
        printf '| %s | %s | %s |\n' "$(echo "$options" | sed 's/^no-narrow-profile/(no default seccomp profile found)/')" - -
        continue ;;
    esac
    label=$(echo "${options:-(none: Docker's defaults, as the platform job's)}" |
      sed "s|seccomp=$profile|seccomp=(Docker's default, and unshare, mount, umount2, mount_setattr, pivot_root)|")
    printf '| %s | %s | %s |\n' "$label" \
      "$(tried "$options" "$namespaces")" "$(tried "$options" "$mounts")"
  done
} >> "$summary"
