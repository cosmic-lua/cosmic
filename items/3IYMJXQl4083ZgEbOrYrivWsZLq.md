## Goal

G3 — an honest type layer, no escape hatches. `docs/design/casts.md`
classifies the tree's 214 justified `as` casts into 21 disjoint
classes; this is the **type-defeating test probe** class, 26 sites, the
largest of the 21. Files: `cosmic/fd_read_test.tl` 3;
`cosmic/hash_test.tl` 3; `cosmic/log_test.tl` 3;
`cosmic/quicksand/box/merge_test.tl` 3; `cosmic/sandbox/init_test.tl` 3;
`cosmic/check_assertions_test.tl` 2; `cosmic/string_test.tl` 2;
`cosmic/check.tl` 1; `cosmic/compress_test.tl` 1;
`cosmic/fs/traps_test.tl` 1; `cosmic/fuzzy_test.tl` 1;
`cosmic/quicksand/init_test.tl` 1; `cosmic/quicksand/proxy/rules_test.tl`
1; `cosmic/rand_test.tl` 1. The class's verdict in the census is **why
it is a floor**: a test that proves a runtime guard refuses input the
type forbids must first defeat the type, so the cast cannot be deleted
without deleting the test. It is compressible rather than closable, and
that compression is this item's work: the invalid-input half already
has its helper in `cosmic/check.tl` (`check.refuses`, whose own cast is
the class's one library site), so route every hand-written invalid-input
probe through it; the absent-surface half — the probes asserting a
removed or private name really is gone — wants one more helper of the
same shape, taking a module and a name and answering whether the
surface is there, so the assertion stops needing a `{string: any}` view
per test. Two casts, one per helper, is the floor the census records;
the closure diff lowers every affected row in
`_build/casts_baseline.tl` toward it. Full class description, exemplar
citations and the tie-break against neighbouring classes are the
`### type-defeating test probe` section of `docs/design/casts.md`, and
the per-site list is `docs/design/cast-sites.tsv` filtered on that class
name.
