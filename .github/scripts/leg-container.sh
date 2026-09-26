#!/bin/sh
# Runs ci.yml's Linux legs in their image on a container of their own,
# started by a step rather than by the job's `container:`, which the
# runner creates before any step can set up its host (see the platform
# job's comment on the sandbox): the host's actions (checkout, caches,
# uploads) run on the host as before, and every `run` step runs in the
# container, through the shell this installs.
#
#     sh .github/scripts/leg-container.sh start IMAGE [OPTION...]
#     leg-shell [--root] SCRIPT
#
# `start`, from the checkout's root on the host, pulls IMAGE (logged in
# to ghcr.io as $ACTOR with $TOKEN, and out again) and starts it as the
# container `cosmic-leg` with the `docker run` OPTIONs given, then puts
# `leg-shell` on the job's PATH ($GITHUB_PATH). The container holds
# $GITHUB_WORKSPACE's parent and $RUNNER_TEMP at their host paths, so
# the checkout, the caches the host restored, the runner's script and
# file-command files (GITHUB_ENV, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY,
# ...) are where a step and an action alike find them; --init puts a
# reaper at PID 1, as the job's container had.
#
# `leg-shell SCRIPT`, a step's shell (`leg-shell {0}`), runs `sh -e
# SCRIPT` in the container as `runner`, the unprivileged builder a
# step creates first; `--root` runs it as root, for that step. It runs
# where the step does (its working-directory), and passes the step's
# variables whose names the runner, the job or the driver use --
# GITHUB_*, RUNNER_*, COSMIC_*, CI, TARGET, XDG_CACHE_HOME -- as a job
# container's steps took them; a step's variable named otherwise does
# not reach the container, so add its name below. PATH is the image's,
# after what earlier steps added to the job's ($GITHUB_PATH), as a job
# container's was.
set -eu

container=cosmic-leg
state=$RUNNER_TEMP/leg

if [ "${1-}" = start ]; then
  [ $# -ge 2 ] || { echo "usage: leg-container.sh start IMAGE [OPTION...]" >&2; exit 2; }
  image=$2
  shift 2
  echo "$TOKEN" | docker login ghcr.io -u "$ACTOR" --password-stdin
  pulled=0
  docker pull -q "$image" || pulled=$?
  docker logout ghcr.io
  [ "$pulled" -eq 0 ] || exit "$pulled"
  mkdir -p "$state/bin"
  work=$(dirname "$GITHUB_WORKSPACE")
  docker network create "$container" >/dev/null
  docker run -d --name "$container" --network "$container" --init \
    -v "$work:$work" -v "$RUNNER_TEMP:$RUNNER_TEMP" "$@" \
    --entrypoint tail "$image" -f /dev/null
  # What a later step's PATH adds to this one's is what earlier steps
  # added to the job's; the image's own follows it in the container.
  printf '%s' "$PATH" > "$state/host-path"
  docker exec "$container" sh -c 'printf %s "$PATH"' > "$state/container-path"
  cp .github/scripts/leg-container.sh "$state/bin/leg-shell"
  chmod 755 "$state/bin/leg-shell"
  echo "$state/bin" >> "$GITHUB_PATH"
  exit 0
fi

user=runner
if [ "${1-}" = --root ]; then
  user=root
  shift
fi
[ $# -eq 1 ] || { echo "usage: leg-shell [--root] SCRIPT" >&2; exit 2; }
script=$1

host_path=$(cat "$state/host-path")
case $PATH in
  *"$host_path") added=${PATH%"$host_path"} ;;
  *) echo "leg-shell: this step's PATH does not end with the job's first: $PATH" >&2; exit 2 ;;
esac

set --
for name in $(awk 'BEGIN { for (name in ENVIRON) print name }'); do
  case $name in
    GITHUB_* | RUNNER_* | COSMIC_* | CI | TARGET | XDG_CACHE_HOME) set -- "$@" -e "$name" ;;
  esac
done
exec docker exec -u "$user" -w "$(pwd)" -e "PATH=$added$(cat "$state/container-path")" "$@" \
  "$container" sh -e "$script"
