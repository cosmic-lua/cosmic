#!/bin/sh
# Watches this workflow run's jobs and cancels the run once one has
# failed, so the gate (`ci`) reports at once. It reads the jobs of
# attempt $ATTEMPT of run $RUN_ID in $REPOSITORY with $GH_TOKEN, every
# $INTERVAL seconds, and stops at the first of: the gate starting (every
# job it needs has finished: nothing is left to cancel), a failed job
# (named in an error annotation, then the cancel), or $LIMIT seconds.
# $SELF is this job's name; $EXEMPT lists, comma-separated, the names of jobs whose failure cancels nothing (an informational
# job: `continue-on-error`, waited on by no one). It always exits 0: a failed call is asked
# again, and the watcher is no check that matters.
set -u

interval=${INTERVAL:-30}
limit=${LIMIT:-2880}
waited=0

# The first failed job other than this one, the gate and the exempt. A job that
# failed keeps its conclusion: the cancel comes after it finished.
failed='($exempt | split(",")) as $skip | [.jobs[] | select(.name != $self and .name != "ci" and .conclusion == "failure" and (.name as $n | $skip | any(.[]; . == $n) | not)) | .name] | first // empty'
# The gate starts when its needs have all finished. It is asked first: a
# leg that fails as the gate starts must not cancel a running gate.
gate='[.jobs[] | select(.name == "ci" and .status != "queued" and .status != "waiting" and .status != "pending")] | length'

while [ "$waited" -lt "$limit" ]; do
  if jobs=$(gh api "repos/$REPOSITORY/actions/runs/$RUN_ID/attempts/$ATTEMPT/jobs?per_page=100"); then
    if [ "$(printf '%s' "$jobs" | jq "$gate" 2>/dev/null)" = 1 ]; then
      exit 0
    fi
    name=$(printf '%s' "$jobs" | jq -r --arg self "$SELF" --arg exempt "${EXEMPT:-}" "$failed") || name=
    if [ -n "$name" ]; then
      echo "::error::$name failed; cancelling the run, so its other jobs show as cancelled."
      if gh run cancel "$RUN_ID" --repo "$REPOSITORY"; then
        exit 0
      fi
      echo "could not cancel run $RUN_ID: asking again"
    fi
  else
    echo "could not read the run's jobs: asking again"
  fi
  sleep "$interval"
  waited=$((waited + interval))
done
