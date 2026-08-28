## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **dynamic name lookup** class, 8 sites.
Files: `_make/init.tl` 7; `cosmic/searcher_test.tl` 1. The shape is a
table indexed by a name computed at runtime, where the declared type
cannot say what any single name maps to. Seven of the eight are one
thing: `_make/init.tl` resolving a build verb through `by_name("build")`
and friends, each result re-typed `as Verb` with the reason
`the registry defines it`. The census verdict is **what closes it
here**, and the mechanism is ordinary: the registry is this tree's own
data, so a `by_name` that returns `Verb | nil` rather than a loosely
typed row closes all seven outright, and the guard that necessarily
follows it is one the checker already narrows — a truthiness test or an
`assert` on a plain local both narrow `T | nil` under the carried
patch, so no cast replaces the cast. The eighth site is
`cosmic/searcher_test.tl` reaching into a `package.searchers` slot,
which wants a declared record for what that table holds; that is a type
declaration and nothing more. Note what is NOT in this class: the
`E*`/`SIG*` constant lookups off `cosmo.unix` are the separate
**binding constant by name** class, they close upstream in
`whilp/cosmopolitan`, and an open item already covers them
(`3ISJHfNY`) — do not fold them in here. The closure diff lowers the
affected `_build/casts_baseline.tl` rows. The class description and
exemplar citation are the `### dynamic name lookup` section of
`docs/design/casts.md`; the per-site list is
`docs/design/cast-sites.tsv`.
