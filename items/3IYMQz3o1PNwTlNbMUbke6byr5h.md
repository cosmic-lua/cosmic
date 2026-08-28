## Goal

G3 — an honest type layer, no escape hatches. This item does not decide
anything; it puts a measured number in front of the goal owner and asks
for a wording, because the outcome is theirs and an outcome changes by
PR to `docs/goals.md`.

## The measurement

`docs/design/casts.md` now classifies every one of the tree's 214
justified `as` casts into 21 disjoint classes, each carrying exactly
one verdict: closable here, closable upstream, or a floor. Five classes
carry **why it is a floor** — type-defeating test probe (26 sites),
userdata boundary (22), runtime capability probe (10), metatable access
(10), and generic T (8) — holding 76 sites between them. Four of the
five compress hard, because the shape repeats and one helper can carry
it. Summing each class's smallest reachable count — six wrap points,
two probe helpers, five probed shapes, two metatable helpers, and eight
generic bodies — puts the measured floor at **23**. That number
supersedes the 2026-08-15 census's estimate of 56, which was taken
against a different class cut and before the from-any work drained most
of its members.

## The question

G3's win condition in `docs/goals.md` is zero `as` casts. These 23 are
not casts standing in for work nobody has done: they are the places
where a type system that cannot see userdata, cannot see a metatable,
cannot see another binary's surface, and cannot see inside its own
generics has to be told. Reaching literal zero means deleting what they
serve — the tests that prove the runtime guards refuse bad input, the
typed wrappers over `cosmo.*` handles, the generic copy and merge. Two
candidate wordings:

1. **Keep it literal.** "Zero `as` casts", unchanged, accepting that
   the last 23 are reached by deleting the thing each one serves, and
   that the goal is therefore not reachable while the tree keeps those
   capabilities. The virtue is that the measure stays a single number
   nobody can negotiate with.
2. **Zero outside a named floor.** "Zero `as` casts outside a declared
   floor: the justified casts no mechanism closes, held per class in
   `docs/design/casts.md` and ratcheted per file by
   `_build/casts_baseline.tl`", with a further condition on the test
   half — 26 of the 76 floor sites are test probes, and a probe behind
   one named helper is a different thing from a probe written by hand
   at each site, so the wording can require the helper. The virtue is
   that the measure stays honest and still ratchets; the cost is that
   "floor" becomes a thing someone can grow.

## What this item does

Decide between them (or a third), then land the `docs/goals.md`
amendment as its own PR. The evidence is `docs/design/casts.md`'s
`## The floor` section and `docs/design/cast-sites.tsv`; the floor
arithmetic assumes generic T is incompressible at 8, which its own
closure item is tasked with proving. Nothing else in the tree changes.
