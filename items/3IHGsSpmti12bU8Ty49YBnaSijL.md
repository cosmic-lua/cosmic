## Goal

G8 — the flow system. The verdict/land pair assumes the PR is
unmerged when the accept arrives; a maintainer merging directly
breaks that assumption and strands the item.

## Evidence

2026-08-22, live: 3ICG8WcG sat in check with PR #1313 when the
maintainer merged the PR to main (08998b0e) ahead of any board
verdict. The accept path now has nothing to do at land — `verdict ID
accept` would move the item to land, where `gitboard land ID` tries
to squash-merge an already-merged PR. Today the only exits are a
hand-noted spec (done here) or a forced move; neither is the tool
saying what happened. The adjacent hardening items (3ICDNJmQ
verdict_head at merge, 3ICDNqdv ungated land) cover other seams of
the same trust boundary but not this one.

## Direction

At `verdict ID accept`, read the PR's state: MERGED means the landing
half is already done — record the verdict and the merge sha and end
the item (completed) in the same mutation, skipping land. A CLOSED
(unmerged) PR at accept is a contradiction to refuse. Review distance
is unchanged: the verdict still comes from a non-claimant session;
only the redundant merge step is elided.
