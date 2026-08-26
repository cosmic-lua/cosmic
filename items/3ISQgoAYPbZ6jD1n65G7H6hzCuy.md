`_types/gentl.tl`'s `KEEP` set gained `FILE = true` in PR #1406 (board
item 3ISJKfRg) without the explanatory comment that item's `## Change`
asked for, so the set now contradicts the doc comment directly above
it. `_types/gentl.tl:14-16` reads "Erasure rules: primitives pass
through; upstream enums/aliases of string become string; the records
this file re-declares keep their names; everything else (internal
records, interfaces) becomes any" — and `FILE` is none of those: it is
a Lua stdlib type the Teal prelude declares, kept because naming it
is honest where erasing it to `any` forced a cast at
`cosmic/teal.tl`'s `search_module`.

Why it is worth a line rather than nothing: 3ISJKfRg's own Non-goal
was "do not widen `KEEP` beyond `FILE` — every other name `erase`
sends to `any` is an internal tl record or interface that this
curation deliberately does not re-declare, and adding one silently
freezes an upstream internal into our surface." The comment was the
guard rail that carries that reasoning to whoever next wants to add a
name. Without it, `FILE` reads as precedent for widening rather than
as the one exception it is.

The fix is one or two lines at `_types/gentl.tl:17`: extend the
erasure-rules comment so it covers Lua stdlib types the prelude
already declares, and say that everything else falling through to
`any` is an internal tl record or interface this curation will not
re-declare. No behavior change, no regen.

Found while reviewing PR #1406 at head `5fdff54d`; accepted rather
than bounced because the diff was otherwise exactly the spec and a
rework round would have stranded a live claim over one comment.
