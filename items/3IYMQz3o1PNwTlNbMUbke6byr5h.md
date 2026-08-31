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

3. **Zero outside what the checker itself permits.** A third shape, decided
   purely on types rather than on a count or a location: `x as T` is legal
   only when `x`'s static type is one the checker cannot see into — `any`, a
   userdata declared in a `.d.tl`, or a type variable bound by the enclosing
   generic — and refused otherwise, carried as a fourth group in
   `3p/tl/tl_patch/`. The two refused halves are each independently
   indefensible: a cast whose operand already relates to the target asserts
   nothing, and one whose operand does not relate is a lie. Both pass silently
   today (`"hi" as integer`, `A as B`, `a as A` and `a as any` all type-check
   on the pinned checker), so this tightens nothing that currently holds.

   The virtue is that "floor" stops being a number anyone can grow: the
   boundary is a property of each site's types, re-decided by the checker on
   every build, and it lands where werror already lives rather than at CI. It
   also forces the probe-helper compression the other candidates only request
   — a helper whose parameters are `any` removes the call-site cast entirely,
   leaving one cast inside the helper whose operand is `any`.

   The cost is that it is not free for the floor as it stands: the 53 sites
   casting to an open map are refused (22 of them in floor classes), and
   metatable access is refused outright because `getmetatable` is not typed
   `any`, so it needs a wrapper that returns one. **This wording cannot be
   priced from the evidence in this item** — choosing it needs the census from
   `pZcc2Wyy` (prototype a type-decided cast rule in the tl patch set), which
   reports refusals joined to these 21 classes. Candidates 1 and 2 can be
   decided today; candidate 3 cannot.

## What this item does

Decide between them, then land the `docs/goals.md`
amendment as its own PR. The evidence is `docs/design/casts.md`'s
`## The floor` section and `docs/design/cast-sites.tsv`; the floor
arithmetic assumes generic T is incompressible at 8, which its own
closure item is tasked with proving. Nothing else in the tree changes.
