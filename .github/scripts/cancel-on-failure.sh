#!/bin/sh
# Watches this workflow run's jobs and cancels the run once one has
# failed, so the gate (`ci`) reports at once. It reads the jobs of
# attempt $ATTEMPT of run $RUN_ID in $REPOSITORY with $GH_TOKEN, every
# $INTERVAL seconds, and stops at the first of: a failed job (named in
# an error annotation, then the cancel), the gate starting (every job it
# needs has finished), or $LIMIT seconds. $SELF is this job's name.
# It always exits 0: a failed call is asked again, and the watcher
# is no check that matters.
set -u

interval=${INTERVAL:-20}
limit=${LIMIT:-2880}
waited=0

# The first job but this one and the gate that failed. A job that
# failed keeps its conclusion: the cancel comes after it finished.
failed='[.jobs[] | select(.name != $self and .name != "ci" and .conclusion == "failure") | .name] | first // empty'
# The gate is created when its needs have all finished.
gate='[.jobs[] | select(.name == "ci" and .status != "queued" and .status != "waiting" and .status != "pending")] | length'

while [ "$waited" -lt "$limit" ]; do
  if jobs=$(gh api "repos/$REPOSITORY/actions/runs/$RUN_ID/attempts/$ATTEMPT/jobs?per_page=100"); then
    name=$(printf '%s' "$jobs" | jq -r --arg self "$SELF" "$failed") || name=
    if [ -n "$name" ]; then
      echo "::error::$name failed; cancelling the run, so its other jobs show as cancelled."
      if gh run cancel "$RUN_ID" --repo "$REPOSITORY"; then
        exit 0
      fi
      echo "could not cancel run $RUN_ID: asking again"
    elif [ "$(printf '%s' "$jobs" | jq "$gate" 2>/dev/null)" = 1 ]; then
      exit 0
    fi
  else
    echo "could not read the run's jobs: asking again"
  fi
  sleep "$interval"
  waited=$((waited + interval))
done
