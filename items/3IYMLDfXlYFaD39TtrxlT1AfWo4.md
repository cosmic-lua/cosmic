## Goal

G3 — an honest type layer, no escape hatches. From the census in
`docs/design/casts.md`: the **tl compiler surface** class, 18 sites.
Files: `_tool/coverage/lines.tl` 3; `_tool/discover.tl` 3;
`cosmic/_teal_ast_test.tl` 3; `cosmic/_teal_discard.tl` 3;
`cosmic/_teal_engine.tl` 3; `_types/tlast.tl` 2; `_types/tlast_test.tl`
1. The narrowed tl API types a parsed program, its statements and its
environment as `any`, so every field read, every array view over a
statement list and every method past the curated surface costs a cast;
the values are real structures with real shapes, and nothing in this
tree describes them because `_types/gentl.tl` erases the AST types by
rule — the upstream records carry internal fields no consumer should
depend on. The census verdict is **what closes it upstream**: tl is
where the node types live, so the fix is a published node type in tl,
or a curated one added to `_types/gentl.tl`'s verified field subsets,
after which every read here becomes an ordinary field access. Either
route arrives as a tl pin bump and stages behind a release under the
cold-build rule, so the checker lands first, `bin/cosmic.pin` moves to a
release carrying it, and only then do the reads lose their casts. This
item's own diff is the upstream change plus the pin bump; the follow-on
that deletes the casts lowers the affected `_build/casts_baseline.tl`
rows. The class description and exemplar citations are the
`### tl compiler surface` section of `docs/design/casts.md`; the
per-site list is `docs/design/cast-sites.tsv`.
