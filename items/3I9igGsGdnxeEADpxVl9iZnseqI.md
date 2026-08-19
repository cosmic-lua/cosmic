Observed 2026-08-19 reviewing PR #1290: one session branch
(claude/peaceful-bohr-h8nhpe) carried TWO independently-specced board
slices (3I9TqfLm cast wave 6a, 3I7PCerj fuzz child 2) as two commits on
one PR. Both items' `pr` fields named #1290. Review worked only because
both were accepted: the squash-merge collapses both diffs into one main
commit, so accepting one and rejecting the other would have stranded
both — there is no way to land half a PR. `move ID check --pr N` accepted
the same PR number for a second in-flight item without comment. The
skill says one slice at a time with the PR opened per slice; either the
tool should refuse a `--pr` already carried by another open item, or the
skill's slice loop should say a fresh branch per pull is mandatory.
