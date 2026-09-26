#!/bin/sh
# Says which `docker create` options let the Linux legs' containers run
# spawn's sandbox (core/process.h's `Sandbox`): for each set of options,
# build/sandbox_probe.tl itself, run by the cosmic release
# ci/cosmic-driver.pin names, as an unprivileged user in each image.
# ci.yml's sandbox-options job runs it on the runner host itself, where
# the platform job's container options take effect, from the checkout's
# root:
#
#     sh .github/scripts/sandbox-options.sh IMAGE...
#
# A report goes to the run's summary ($GITHUB_STEP_SUMMARY, else stdout):
# the host's switches, then for each image and set of options the
# probe's report, or what stopped it. It reports and fails nothing: an
# option the host refuses is a finding.
set -u

[ $# -ge 1 ] || { echo "usage: sandbox-options.sh IMAGE..." >&2; exit 2; }
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=${RUNNER_TEMP:-/tmp}/sandbox-options
rm -rf "$work"
mkdir -p "$work/probe"

# A switch's value, or "absent" where the host has none.
switch() {
  if [ -r "$1" ]; then tr -d '\n' < "$1"; else printf absent; fi
}

# The release the driver pins, checked against its digest, runs the
# tree's probe outside the tree, where no tree calls it stale.
{ read -r _; read -r release_url; read -r release_digest; } < ci/cosmic-driver.pin
cosmic="(not fetched)"
if curl -fsSL --max-time 60 --retry 2 "$release_url" -o "$work/probe/cosmic" 2>/dev/null; then
  if [ "$(sha256sum "$work/probe/cosmic" | cut -d' ' -f1)" = "$release_digest" ]; then
    cp build/sandbox_probe.tl "$work/probe/"
    chmod 755 "$work/probe" "$work/probe/cosmic"
    chmod 644 "$work/probe/sandbox_probe.tl"
    cosmic=$release_url
  else
    cosmic="(refused: its digest is not the pin's)"
  fi
fi

# Each image, pulled before any is run, so no pull's progress is taken
# for what a container said.
unpulled=""
for image in "$@"; do
  docker pull -q "$image" >/dev/null 2>&1 || unpulled="$unpulled $image"
done

# The probe runs from a copy in the container's /tmp: cosmic keeps what
# it builds from a script beside it.
run='mkdir /tmp/probe && cp /probe/cosmic /probe/sandbox_probe.tl /tmp/probe/ &&
  cd /tmp/probe && ./cosmic sandbox_probe.tl'

# The probe's report from a container of image $1 with options $2, run
# as nobody, or what stopped it.
probed() {
  case $cosmic in "("*) printf 'Not probed: the pinned cosmic was %s.\n' "$cosmic"; return ;; esac
  case " $unpulled " in *" $1 "*) printf 'Not probed: the image could not be pulled.\n'; return ;; esac
  # shellcheck disable=SC2086 # $2 is a list of options, split on purpose
  said=$(timeout 120 docker run --rm --init --user 65534:65534 -e HOME=/tmp -e TMPDIR=/tmp \
    -w /tmp -v "$work/probe:/probe:ro" $2 "$1" sh -e -c "$run" 2>&1) ||
    { printf 'The probe did not finish:\n\n```\n%s\n```\n' "$(printf '%s' "$said" | tail -n 20)"; return; }
  printf '%s\n' "$said"
}

# The narrowest seccomp profile to try: Docker's own default, which
# allows unshare, mount and the like only to a container holding
# CAP_SYS_ADMIN and pivot_root to none, with just the calls the sandbox
# makes allowed outright. The default is the one this host's Docker
# version was released with (moby/moby's profiles/seccomp/default.json
# at its tag), or, for a Docker whose tree no longer holds it there,
# moby/profiles' current one.
version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)
profile=$work/seccomp.json
narrow=""
source="none found"
digest=-
for url in "https://raw.githubusercontent.com/moby/moby/v$version/profiles/seccomp/default.json" \
    "https://raw.githubusercontent.com/moby/profiles/main/seccomp/default.json"; do
  if curl -fsSL --max-time 30 --retry 2 "$url" -o "$profile.default" 2>/dev/null; then
    digest=$(sha256sum "$profile.default" | cut -d' ' -f1)
    if narrowed=$(python3 - "$profile.default" "$profile" 2>&1 <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
profile["syscalls"].append({"names": ["unshare", "mount", "umount2", "mount_setattr",
                                      "pivot_root"], "action": "SCMP_ACT_ALLOW"})
json.dump(profile, open(sys.argv[2], "w"))
PY
    ); then
      narrow="--security-opt seccomp=$profile"
      source=$url
    else
      source="$url, which could not be narrowed: $(printf '%s' "$narrowed" | tail -n 1 | tr '|' '/')"
    fi
    break
  fi
done

{
  printf '## Container options for a sandbox (%s)\n\n' "$(uname -m)"
  printf '| Host | |\n|---|---|\n'
  printf '| kernel | %s |\n' "$(uname -r)"
  printf '| docker | %s |\n' "$version"
  printf '| cosmic probing | %s |\n' "$cosmic"
  printf '| default seccomp profile narrowed | %s |\n' "$source"
  printf '| its sha256 | %s |\n' "$digest"
  printf '| AppArmor enabled | %s |\n' "$(switch /sys/module/apparmor/parameters/enabled)"
  for name in kernel/apparmor_restrict_unprivileged_userns kernel/unprivileged_userns_clone \
      user/max_user_namespaces; do
    printf '| %s | %s |\n' "$(echo "$name" | tr / .)" "$(switch "/proc/sys/$name")"
  done
  for image in "$@"; do
    for options in "" "--security-opt seccomp=unconfined" "--security-opt apparmor=unconfined" \
        "--security-opt seccomp=unconfined --security-opt apparmor=unconfined" \
        "${narrow:-no-narrow-profile}" "${narrow:-no-narrow-profile} --security-opt apparmor=unconfined"; do
      label=$(echo "${options:-(none: Docker's defaults, as the platform job's)}" |
        sed -e "s|seccomp=$profile|seccomp=(Docker's default, and unshare, mount, umount2, mount_setattr, pivot_root)|" \
          -e 's|^no-narrow-profile|(no narrowed seccomp profile)|')
      printf '\n### %s: %s\n\n' "${image%@*}" "$label"
      case $options in
        no-narrow-profile*) printf 'Not probed: no narrowed profile.\n' ;;
        *) probed "$image" "$options" ;;
      esac
    done
  done
} >> "$summary"
