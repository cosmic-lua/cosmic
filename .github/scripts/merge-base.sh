#!/bin/sh
# The main commit a run's tree grew from, whose own verdicts ci.yml's
# "restore test verdicts" takes before main's newest: main's push of
# each commit saves a copy of its verdicts keyed by the commit
# (`<prefix>sha-<commit>`), and a branch several commits behind main
# stands on far more of its base's verdicts than of main's newest, whose
# tree it does not have.
#
#     sh .github/scripts/merge-base.sh
#
# EVENT is the run's event (github.event_name) and REF its ref. A push
# to a branch other than main asks the API, through `gh` (GH_TOKEN, with
# contents: read), for the merge base of main and SHA in REPOSITORY,
# which needs no history in the checkout; the merge queue's run takes
# its base, QUEUE_BASE (github.event.merge_group.base_sha), with no call.
# It writes `sha=<base>` to $GITHUB_OUTPUT (standard output, for a run by
# hand), or nothing: on main, on another event, and wherever the lookup
# fails or answers no commit, the restore takes main's newest as before.
# The call to `gh` is cut off after CALL_SECONDS where there is a
# `timeout`. It always exits 0: a base not found costs time, never a
# result.
set -u

out=${GITHUB_OUTPUT:-/dev/stdout}
call=${CALL_SECONDS:-15}

# gh's API, cut off after CALL_SECONDS where the system has a timeout.
api() {
  if command -v timeout >/dev/null 2>&1; then timeout "$call" gh api "$@"; else gh api "$@"; fi
}

# Whether $1 is a whole commit id.
is_commit() {
  case $1 in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ ${#1} -eq 40 ]
}

base=
case ${EVENT-}:${REF-} in
  merge_group:*) base=${QUEUE_BASE-} ;;
  push:refs/heads/main) ;;
  push:*)
    base=$(api "repos/${REPOSITORY-}/compare/main...${SHA-}?per_page=1" \
      --jq '.merge_base_commit.sha' 2>/dev/null) || base=
    ;;
esac

if is_commit "$base"; then
  echo "sha=$base" >> "$out"
  echo "the tree's base on main: $base"
else
  echo "no base on main found: the restore takes main's newest verdicts"
fi
exit 0
