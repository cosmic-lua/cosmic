#!/bin/sh
set -eu

if [ "$#" -ne 6 ]; then
  echo "usage: check-driver.sh PIN SOURCE_ROOT CACHE_DIR PROJECT_DIR RUNNER_PATH CANDIDATE_ROOT" >&2
  exit 2
fi
pin=$1
source=$2
cache=$3
project=$4
runner=$5
candidate=$6
here=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)

if [ -e "$project" ] || [ -L "$project" ]; then
  echo "driver project must be fresh: $project" >&2
  exit 1
fi
sh "$here/bootstrap-driver.sh" "$pin" "$source" "$cache" "$project" "$runner"
if output=$(cd "$project" && COSMIC_CI_SOURCE_ROOT=$candidate COSMIC_CI_HOST=$runner \
    COSMIC_CI_PROJECT=$project "$runner" test \
    "$project/cosmic_ci/bootstrap_test.tl" \
    "$project/cosmic_ci/state_test.tl" \
    "$project/cosmic_ci/fixture_test.tl" \
    "$project/cosmic_ci/pin_probe_test.tl" \
    "$project/cosmic_ci/runner_test.tl" \
    "$project/cosmic_ci/result_test.tl" \
    "$project/cosmic_ci/orchestration_test.tl"); then
  status=0
else
  status=$?
fi
printf '%s\n' "$output"
if [ "$status" -ne 0 ]; then exit "$status"; fi
printf '%s\n' "$output" |
  grep -E 'test: PASS \([^;]+; [1-9][0-9]* ran, 0 stood' >/dev/null
