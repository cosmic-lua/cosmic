#!/bin/sh
# Deletes the copies of main's verdicts keyed by a commit
# (`verdicts-...-sha-<commit>`, which ci.yml saves beside each
# content-keyed entry so a branch restores its merge base's) once they
# are older than HOURS (24 by default): each is some 11 MB a leg a main
# push, and the repository's 10 GB cache, once full, evicts the least
# recently used entries, the zig outputs and the fuzz corpora among them
# (ci/README.md's "the caches"). A branch based on a commit older than
# that restores main's newest verdicts, as every branch once did.
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
if ! ids=$(api --paginate "repos/${REPOSITORY-}/actions/caches?key=verdicts-&per_page=100" \
    --jq ".actions_caches[] | select(.key | test(\"-sha-[0-9a-f]{40}\$\")) | select((.created_at | sub(\"[.][0-9]+\"; \"\") | fromdateiso8601) < $cutoff) | .id"); then
  echo "could not list the cache's entries: none pruned"
  exit 0
fi
deleted=0 failed=0
for id in $ids; do
  if api -X DELETE "repos/${REPOSITORY-}/actions/caches/$id" >/dev/null; then
    deleted=$((deleted + 1))
  else
    failed=$((failed + 1))
  fi
done
echo "pruned $deleted commit-keyed verdict entries older than $hours h ($failed failed)"
exit 0
