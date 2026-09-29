#!/bin/sh
# The merge queue's result, which a push to main reuses rather than
# testing the same commit again (ci/README.md's "the queue's result").
#
#     sh .github/scripts/queue-seed.sh find
#     sh .github/scripts/queue-seed.sh stage
#
# find, ci.yml's `reuse` job on a push to main: asks the API, through
# `gh` (GH_TOKEN, with actions: read), for REPOSITORY's merge_group runs
# of ci.yml whose head_sha is SHA, and writes to $GITHUB_OUTPUT
# `run=<id>` and `url=<its page>` of one whose head_sha is SHA, on a
# gh-readonly-queue/main/ branch, that completed with success and
# uploaded a seed-<leg> artifact not yet expired (a re-run a day
# later finds none); `run=` and `url=` where none did, and the push
# runs the full scope. The queue lands its merge the moment the
# `ci` check passes, a moment before its run completes, so while such a
# run is still queued or in progress it asks again, every WAIT_SECONDS
# (10), up to TRIES (18) times; an API that fails every time finds none.
# Either way it exits 0: a full run costs time, never a result.
#
# stage, a merge_group run's platform leg that passed: copies into
# $RUNNER_TEMP/seed what a push to main would have saved, and writes
# there `seed.keys`, a line `<cache>=<key>` for each, the key it saves
# under: `verdicts` (from $RUNNER_TEMP/verdicts) and `compiles` (from
# $RUNNER_TEMP/build-cache), each as <X>_PREFIX and <X>_DIGEST, where
# the digest is not empty and the key is not <X>_RESTORED, the entry the
# run restored; and `driver-checked` (from $RUNNER_TEMP/driver-checked),
# the key its marker holds, where the driver check ran and passed.
set -eu

usage="usage: queue-seed.sh find|stage"
[ $# -eq 1 ] || { echo "$usage" >&2; exit 2; }
out=${GITHUB_OUTPUT:-/dev/stdout}

find_run() {
  tries=0
  while :; do
    tries=$((tries + 1))
    found= url= pending=
    if runs=$(gh api "repos/$REPOSITORY/actions/workflows/ci.yml/runs?event=merge_group&head_sha=$SHA&per_page=20" \
        --jq '.workflow_runs[] | "\(.id) \(.status) \(.conclusion // "none") \(.head_sha) \(.head_branch) \(.html_url)"'); then
      while read -r id status conclusion sha branch page; do
        [ "$sha" = "$SHA" ] || continue
        case $branch in gh-readonly-queue/main/*) ;; *) continue ;; esac
        if [ "$status" != completed ]; then
          pending=1
        elif [ "$conclusion" = success ] && [ -z "$found" ] &&
            gh api "repos/$REPOSITORY/actions/runs/$id/artifacts?per_page=100" \
              --jq '.artifacts[] | select(.expired | not) | .name' | grep -q '^seed-'; then
          found=$id url=$page
        fi
      done <<EOF
$runs
EOF
    else
      pending=1
    fi
    if [ -n "$found" ] || [ -z "$pending" ] || [ "$tries" -ge "${TRIES:-18}" ]; then break; fi
    sleep "${WAIT_SECONDS:-10}"
  done
  echo "run=$found" >> "$out"
  echo "url=$url" >> "$out"
  if [ -n "$found" ]; then
    said="$SHA passed the merge queue in $url: its legs' caches and products are reused."
  else
    said="$SHA has no passing merge queue run to reuse: the full scope runs."
  fi
  echo "$said"
  [ -z "${GITHUB_STEP_SUMMARY-}" ] || echo "$said" >> "$GITHUB_STEP_SUMMARY"
}

# The entry NAME, from DIR, under PREFIX and DIGEST, unless the digest is
# empty or the key is RESTORED.
entry() {
  name=$1 dir=$2 prefix=$3 digest=$4 restored=$5
  [ -n "$digest" ] && [ "$prefix$digest" != "$restored" ] || return 0
  cp -R "$RUNNER_TEMP/$dir" "$seed/$dir"
  echo "$name=$prefix$digest" >> "$seed/seed.keys"
}

stage() {
  seed=$RUNNER_TEMP/seed
  rm -rf "$seed"
  mkdir -p "$seed"
  : > "$seed/seed.keys"
  entry verdicts verdicts "$VERDICTS_PREFIX" "$VERDICTS_DIGEST" "${VERDICTS_RESTORED-}"
  entry compiles build-cache "$COMPILES_PREFIX" "$COMPILES_DIGEST" "${COMPILES_RESTORED-}"
  if [ -f "$RUNNER_TEMP/driver-checked/key" ]; then
    cp -R "$RUNNER_TEMP/driver-checked" "$seed/driver-checked"
    echo "driver-checked=$(cat "$RUNNER_TEMP/driver-checked/key")" >> "$seed/seed.keys"
  fi
  cat "$seed/seed.keys"
}

case $1 in
  find) find_run ;;
  stage) stage ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
