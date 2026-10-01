#!/bin/sh
# Deletes the copies of main's verdicts keyed by a commit
# (`verdicts-...-sha-<commit>`, which ci.yml saves beside each
# content-keyed entry so a branch restores its merge base's) once they
# are older than HOURS (24 by default): each is some 11 MB a leg a main
# push, and the repository's 10 GB cache, once full, evicts the least
# recently used entries, the zig outputs and the fuzz corpora among them
# (ci/README.md's "the caches"). A branch based on a commit older than
# that restores main's newest verdicts.
#
# It deletes too the compiles a branch's push saves for its later pushes
# (`compiles-branch-...`, some 5 MB a leg, saved where a change to the
# compiler moved every compile's key) once they are older than HOURS: a
# later push of that branch restores main's, and saves its own again.
#
#     sh .github/scripts/prune-commit-verdicts.sh
#
# ci.yml's `prune` job runs it on a push to main, through `gh`
# (GH_TOKEN, with actions: write), against REPOSITORY. Each call to
# `gh` is cut off after CALL_SECONDS where there is a `timeout`. It
# always exits 0: an entry left is only space, which the cache's own
# eviction reclaims.
set -u

hours=${HOURS:-24} call=${CALL_SECONDS:-15}

# gh's API, cut off after CALL_SECONDS where the system has a timeout.
api() {
  if command -v timeout >/dev/null 2>&1; then timeout "$call" gh api "$@"; else gh api "$@"; fi
}

cutoff=$(($(date +%s) - hours * 3600))

# Deletes each entry of PREFIX that FILTER names (by id) of the listing,
# and says how many as WHAT.
prune() {
  prefix=$1 filter=$2 what=$3
  if ! ids=$(api --paginate "repos/${REPOSITORY-}/actions/caches?key=$prefix&per_page=100" --jq "$filter"); then
    echo "could not list the cache's $what entries: none pruned"
    return 0
  fi
  deleted=0 failed=0
  for id in $ids; do
    if api -X DELETE "repos/${REPOSITORY-}/actions/caches/$id" >/dev/null; then
      deleted=$((deleted + 1))
    else
      failed=$((failed + 1))
    fi
  done
  echo "pruned $deleted $what entries older than $hours h ($failed failed)"
}

prune verdicts- ".actions_caches[] | select(.key | test(\"-sha-[0-9a-f]{40}\$\")) | select((.created_at | sub(\"[.][0-9]+\"; \"\") | fromdateiso8601) < $cutoff) | .id" "commit-keyed verdict"
prune compiles-branch- ".actions_caches[] | select(.key | startswith(\"compiles-branch-\")) | select((.created_at | sub(\"[.][0-9]+\"; \"\") | fromdateiso8601) < $cutoff) | .id" "branch compiles"
exit 0
