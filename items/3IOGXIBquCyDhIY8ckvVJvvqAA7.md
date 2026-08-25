Expand cosmic.literal's domain with the array part: positional
entries (`{"a", "b", 3}`), mixed tables (`{name = "x", "y"}`), and
integer bracket keys (`[1] = x`, `[-3] = y`). The domain stays a
strict subset of Lua's literal shapes — no new tokens, no
computation — so NaN/inf, expressions, and nil entries stay refused.
The evidence that lists are needed is the tree's own consumers
faking them today (measured 2026-08-25): gitboard encodes multiple
blockers as a space-joined string — `["blocked_by"] =
"<ksuid> <ksuid>"`, built by `table.concat(ids, " ")` at
_work/store.tl:301 on the board branch — a private encoding that
cannot hold values containing spaces; and the cosmos pin's
`platforms` table is a map keyed `["*"]` where a list was wanted.
The rules the expansion carries: sparseness refused by name (a hole
can only arise from explicit `[n] =` mixing, since nil is not in
the domain, so the rule is checkable); the positional/bracket
collision (`{"a", [1] = "b"}`, Lua last-wins) refused by both
positions, consistent with the duplicate-key stance; float, NaN,
and negative-zero keys refused. The public return type widens from
`{string: any}` to admit integer keys — a breaking change the
right-to-break doctrine covers. Both readers (Teal reference and C)
move in the same change with the differential fuzz extended to the
new shapes; the format half admits exactly what parse admits, with
array rendering keeping the pin layout a fmt fixpoint. Sequenced
after the round-trip property (its generator extends to arrays
rather than growing a second harness) and after the depth-boundary
fix. A follow-up on the board branch migrates gitboard's
blocked_by to a real list.
