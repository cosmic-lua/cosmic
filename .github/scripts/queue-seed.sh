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
# `run=<id>` and `url=<its page>` of the newest whose head_sha is SHA,
# on a gh-readonly-queue/main/ branch, that completed with success and
# holds an unexpired seed-<leg> artifact for each of LEGS (the names of
# the platform legs and of the checked job, blank-separated, each a job
# that keeps a cache; a re-run a day later finds them
# expired); `run=` and `url=` where it did not, and the push runs the
# full scope. The queue lands its merge the moment the `ci` check
# passes, a moment before its run completes, so while such a run is
# still queued or in progress, or while the API fails, it asks again,
# every WAIT_SECONDS, up to TRIES times. Each call to `gh` is cut off
# after CALL_SECONDS where there is a `timeout`, and a round makes at
# most two, so the lookup takes at most
# TRIES * (WAIT_SECONDS + 2 * CALL_SECONDS), under the `reuse` job's
# timeout-minutes (build/workflows_test.tl holds the defaults below to
# it). Either way it exits 0: a full run costs time, never a result.
#
# stage, a merge_group run's platform leg that passed: copies into
# $RUNNER_TEMP/seed what a push to main would have saved, and writes
# there `seed.keys`, a line `<cache>=<key>` for each, the key it saves
# under: `verdicts` (from $RUNNER_TEMP/verdicts) and `compiles` (from
# $RUNNER_TEMP/build-cache), each as <X>_PREFIX and <X>_DIGEST, where
# the digest is not empty and the key is not <X>_RESTORED, the entry the
# run restored (a job that saves no compiles, ci.yml's `checked`, sets
# no COMPILES_*); `verdicts-sha`, the verdicts' copy keyed by the commit,
# <VERDICTS_PREFIX>sha-<SHA>, where the digest is not empty, even where it
# names the entry restored (the commit's own key is saved on every push
# to main, for a branch based on it: .github/scripts/merge-base.sh); and
# `driver-checked` (from $RUNNER_TEMP/driver-checked), the key its marker
# holds, where the driver check ran and passed.
set -eu

usage="usage: queue-seed.sh find|stage"
[ $# -eq 1 ] || { echo "$usage" >&2; exit 2; }
out=${GITHUB_OUTPUT:-/dev/stdout}

tries=${TRIES:-6} wait=${WAIT_SECONDS:-20} call=${CALL_SECONDS:-15}

# gh's API, cut off after CALL_SECONDS where the system has a timeout.
api() {
  if command -v timeout >/dev/null 2>&1; then timeout "$call" gh api "$@"; else gh api "$@"; fi
}

find_run() {
  [ -n "${LEGS-}" ] || { echo "queue-seed.sh find: no LEGS" >&2; exit 2; }
  round=0
  while :; do
    round=$((round + 1))
    found= url= pending= candidate= candidate_url=
    if runs=$(api "repos/$REPOSITORY/actions/workflows/ci.yml/runs?event=merge_group&head_sha=$SHA&per_page=20" \
        --jq '.workflow_runs[] | "\(.id) \(.status) \(.conclusion // "none") \(.head_sha) \(.head_branch) \(.html_url)"'); then
      while read -r id status conclusion sha branch page; do
        [ "$sha" = "$SHA" ] || continue
        case $branch in gh-readonly-queue/main/*) ;; *) continue ;; esac
        if [ "$status" != completed ]; then
          pending=1
        elif [ "$conclusion" = success ] && [ -z "$candidate" ]; then
          candidate=$id candidate_url=$page
        fi
      done <<EOF
$runs
EOF
    else
      pending=1
    fi
    # The newest passing run, where it holds every leg's seed.
    if [ -n "$candidate" ]; then
      if names=$(api "repos/$REPOSITORY/actions/runs/$candidate/artifacts?per_page=100" \
          --jq '.artifacts[] | select(.expired | not) | .name'); then
        missing=
        for leg in $LEGS; do
          printf '%s\n' "$names" | grep -qx "seed-$leg" || missing="$missing $leg"
        done
        if [ -z "$missing" ]; then
          found=$candidate url=$candidate_url
        else
          echo "run $candidate has no seed for:$missing"
        fi
      else
        pending=1
      fi
    fi
    if [ -n "$found" ] || [ -z "$pending" ] || [ "$round" -ge "$tries" ]; then break; fi
    sleep "$wait"
  done
  echo "run=$found" >> "$out"
  echo "url=$url" >> "$out"
  if [ -n "$found" ]; then
    said="$SHA passed the merge queue in $url: its legs' caches and products are reused."
  else
    said="$SHA has no passing merge queue run with every leg's seed to reuse: the full scope runs."
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
  entry verdicts verdicts "${VERDICTS_PREFIX-}" "${VERDICTS_DIGEST-}" "${VERDICTS_RESTORED-}"
  entry compiles build-cache "${COMPILES_PREFIX-}" "${COMPILES_DIGEST-}" "${COMPILES_RESTORED-}"
  if [ -n "${VERDICTS_DIGEST-}" ] && [ -n "${SHA-}" ]; then
    [ -d "$seed/verdicts" ] || cp -R "$RUNNER_TEMP/verdicts" "$seed/verdicts"
    echo "verdicts-sha=${VERDICTS_PREFIX-}sha-$SHA" >> "$seed/seed.keys"
  fi
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
