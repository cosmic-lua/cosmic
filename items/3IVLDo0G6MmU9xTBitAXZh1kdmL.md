# Problem

G9 may be the first outcome whose win condition holds, and nobody has
checked. The machinery is built end to end: the public-surface
ratchet gates per PR against a committed baseline
(`_build/public_surface_test.tl`, `_build/public_surface_baseline.tl`),
the size report measures per release and compares against the
previous one (`_build/size.tl`, wired into release.yml's "measure the
tree size" step, published as the `size.json` asset), and the report
carries the doctrine-size and cast-count columns the win condition
names. What has not been done is reading the win condition against
the evidence: does the surface ratchet hold, has the size report
shipped with every release since it landed, is doctrine size trending
down, and is pruning work being opened from the report's numbers
rather than taste (the current G9 backlog items are gate-honesty
bugs, which is close but not the same thing).

# Change

The verification slice for G9, in the form the held-outcome mechanism
defines: run each of G9's `measured by:` clauses against the release
history and the tree, quote the evidence in the spec trail, and
deliver a held / not-held-because verdict. If held: the goals.md
amendment and the root's transition per the mechanism. If not: the
gap becomes the item(s) that close it, filed under G9 with the
evidence.

# Non-goals

- Fixing any gate bug found along the way (file it).
- Declaring any other goal held.

# Acceptance

- every `measured by:` clause of G9 in docs/goals.md has a quoted,
  re-runnable evidence line in this item's trail.
- a recorded verdict: held (with the goals.md PR) or the named gaps
  as new G9 items.
