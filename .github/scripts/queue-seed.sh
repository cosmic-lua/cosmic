#!/bin/sh
# The merge queue's result, which a push to main reuses rather than
# testing the same commit again (ci/README.md's "the queue's result").
#
#     sh .github/scripts/queue-seed.sh find
#     sh .github/scripts/queue-seed.sh stage
#     sh .github/scripts/queue-seed.sh ahead
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
# holds, where the driver check ran and passed; and `zig-build` (from
# $RUNNER_TEMP/zig-build, as `zig-build.tar`: an artifact keeps no
# file's mode, and zig's cache holds programs it runs), under
# ZIG_BUILD_KEY, the restore's primary key, where ZIG_BUILD_EXACT, the
# prefix of an entry built from this very core and vendor part, does
# not begin ZIG_BUILD_RESTORED, the entry restored (a job that saves no
# zig build outputs, ci.yml's `checked`, sets no ZIG_BUILD_*).
#
# ahead, a merge_group run's job before its suite (ci.yml's "find the
# run ahead in the queue"): finds the run ahead of this one in the
# queue, the merge_group run of ci.yml on a gh-readonly-queue/main/
# branch whose head_sha is BASE, this run's base
# (github.event.merge_group.base_sha), asking the API as `find` does,
# and writes `run=<id>` to $GITHUB_OUTPUT where that run holds an
# unexpired ARTIFACT, the verdicts its job JOB keeps once its suite
# passes, for this run to take (ci.yml's `verdicts-ahead`); `run=`
# where it does not. While that run is in progress and JOB in it has
# not completed, or while the API fails, it asks again every
# WAIT_SECONDS until WITHIN_SECONDS have passed since it started; a
# round makes at most three calls, each cut off as `find`'s are, so it
# ends within WITHIN_SECONDS + 3 * CALL_SECONDS, which ci.yml holds
# under the step's timeout (build/workflows_test.tl). Where READY_SECONDS
# is set, JOB is taken to keep ARTIFACT that long after it started: one
# not started yet, or that would keep it only after the wait ends, is
# not waited for. None is found at once where the checkout's change
# moves build/harness_epoch.tl from BASE's, when every suite runs every
# test (--all) and stands on no verdict; where BASE heads no queue run
# (it is main's already: ci.yml skips the step where the restore took
# BASE's own entry, and a base that landed after the restore finds its
# run, whose verdicts merge as rows mostly held already); and where
# the run, or JOB, completed without ARTIFACT. Either way it exits 0:
# none costs time, never a result.
set -eu

usage="usage: queue-seed.sh find|stage|ahead"
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

# Whether $1 is a whole commit id.
is_commit() {
  case $1 in
    "" | *[!0-9a-f]*) return 1 ;;
  esac
  [ ${#1} -eq 40 ]
}

ahead() {
  { [ -n "${ARTIFACT-}" ] && [ -n "${JOB-}" ]; } ||
    { echo "queue-seed.sh ahead: no ARTIFACT or JOB" >&2; exit 2; }
  base=${BASE-} found= said=
  deadline=$(($(date +%s) + ${WITHIN_SECONDS:-150}))
  if ! is_commit "$base"; then
    said="no base to find the run ahead by: the restore's verdicts alone."
  elif git cat-file -e "$base^{commit}" 2>/dev/null; then
    # 1 where the file differs; anything else (no git, a refusal) is
    # no sign it moved.
    moved=0
    git diff --quiet "$base" HEAD -- build/harness_epoch.tl 2>/dev/null || moved=$?
    [ "$moved" -ne 1 ] ||
      said="build/harness_epoch.tl moved from $base's: every test runs (--all), and stands on no verdict."
  fi
  while [ -z "$said" ]; do
    # At most three calls a round, each cut off at CALL_SECONDS.
    pending= run= status=
    if runs=$(api "repos/$REPOSITORY/actions/workflows/ci.yml/runs?event=merge_group&head_sha=$base&per_page=20" \
        --jq '.workflow_runs[] | select(.event == "merge_group") | "\(.id) \(.status) \(.head_sha) \(.head_branch)"'); then
      # The newest, where a run was retried.
      while read -r id state sha branch; do
        [ "$sha" = "$base" ] && [ -z "$run" ] || continue
        case $branch in gh-readonly-queue/main/*) run=$id status=$state ;; esac
      done <<EOF
$runs
EOF
      [ -n "$run" ] || said="$base is no merge queue run's head: the restore's verdicts alone."
    else
      pending=1
    fi
    if [ -n "$run" ]; then
      if names=$(api "repos/$REPOSITORY/actions/runs/$run/artifacts?per_page=100" \
          --jq '.artifacts[] | select(.expired | not) | .name'); then
        if printf '%s\n' "$names" | grep -qx "$ARTIFACT"; then
          found=$run
        elif [ "$status" = completed ]; then
          said="the run ahead, $run, completed without $ARTIFACT: the restore's verdicts alone."
        elif jobs=$(api "repos/$REPOSITORY/actions/runs/$run/jobs?per_page=100" \
            --jq '.jobs[] | "\(.status) \(.started_at // "" | if . == "" then "none" else fromdateiso8601 end) \(.name)"'); then
          job=$(printf '%s\n' "$jobs" | while read -r state started name; do
            [ "$name" != "$JOB" ] || { echo "$state $started"; break; }
          done)
          case $job in
            "completed "*)
              said="$JOB of the run ahead, $run, completed without $ARTIFACT: the restore's verdicts alone." ;;
            *)
              pending=1
              if [ -n "${READY_SECONDS-}" ]; then
                started=${job#* }
                case $started in
                  "" | none | *[!0-9]*)
                    said="$JOB of the run ahead, $run, has not started: the restore's verdicts alone." ;;
                  *)
                    [ $((started + READY_SECONDS)) -le "$deadline" ] ||
                      said="$JOB of the run ahead, $run, keeps $ARTIFACT only after the wait: the restore's verdicts alone." ;;
                esac
              fi ;;
          esac
        else
          pending=1
        fi
      else
        pending=1
      fi
    fi
    if [ -n "$found" ] || [ -n "$said" ] || [ -z "$pending" ] ||
        [ $(($(date +%s) + wait)) -gt "$deadline" ]; then break; fi
    sleep "$wait"
  done
  echo "run=$found" >> "$out"
  if [ -n "$found" ]; then
    said="the run ahead, $found, holds $ARTIFACT: this run takes its verdicts."
  elif [ -z "$said" ]; then
    said="the run ahead of $base left no $ARTIFACT in time: the restore's verdicts alone."
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

# zig's build outputs under KEY, unless EXACT is empty or begins
# RESTORED: an entry of this core and vendor part answers already.
zig_build() {
  key=$1 exact=$2 restored=$3
  [ -n "$key" ] && [ -n "$exact" ] && [ -d "$RUNNER_TEMP/zig-build" ] || return 0
  case $restored in "$exact"*) return 0 ;; esac
  tar -cf "$seed/zig-build.tar" -C "$RUNNER_TEMP" zig-build
  echo "zig-build=$key" >> "$seed/seed.keys"
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
  zig_build "${ZIG_BUILD_KEY-}" "${ZIG_BUILD_EXACT-}" "${ZIG_BUILD_RESTORED-}"
  if [ -f "$RUNNER_TEMP/driver-checked/key" ]; then
    cp -R "$RUNNER_TEMP/driver-checked" "$seed/driver-checked"
    echo "driver-checked=$(cat "$RUNNER_TEMP/driver-checked/key")" >> "$seed/seed.keys"
  fi
  cat "$seed/seed.keys"
}

case $1 in
  find) find_run ;;
  stage) stage ;;
  ahead) ahead ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
