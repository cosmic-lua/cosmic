## Evidence

Re-measured 2026-09-03 against `origin/main` (`96afd807`), from the
committed inventory:

    git show origin/main:docs/design/cast-sites.tsv | tail -n +2 | cut -f3 | sort | uniq -c
    7 decoded data shaping        6 record union after guard
    7 incremental record construction   5 pcall return shape
    17 map view of a declared value     2 sqlite row column read

The earlier tail (32) is gone: `map view` grew from 4 to 17 (13 of
them are the sandbox/quicksand test doubles — `casts-map-view`, a
sibling item), and `record union after guard` is 6, of which
`cosmic/quicksand/proxy.tl:141` closes with `respec 6sv6`. What is
left here is 30 sites in five classes; per-site rows
(`awk -F'\t' '$3=="<class>"{print $1":"$2}'` over the tsv):

- decoded data shaping (7, HERE): `_build/casts.tl:90`,
  `_tool/coverage/baseline.tl:132,138`, `_tool/coverage/baseline_test.tl:486`,
  `cmd/cosmic/embed_gen.tl:294,334`, `cosmic/literal_example.tl:20` —
  `cosmic.shape` already validates a decoded value against a spec and
  returns it typed.
- incremental record construction (7, HERE): `cosmic/fetch/init.tl:220`,
  `cosmic/format/init.tl:118`, `cosmic/quicksand/box/merge.tl:138`,
  `cosmic/signal.tl:287`, `cosmic/sqlite/init.tl:214,295`,
  `cosmic/sqlite/row_iter.tl:64` — record literals the checker verifies.
- map view of a declared value, library half (4, HERE):
  `cosmic/coverage/init.tl:92,93`, `cosmic/fetch/init.tl:388`,
  `cosmic/quicksand/box/merge.tl:135` — declare the type.
- sqlite row column read (2, HERE): `cosmic/sqlite/extras_test.tl:48`,
  `cosmic/sqlite/lifecycle_test.tl:12` — typed accessors on `Row`.
- record union after guard (5, UPSTREAM): `_make/generate.tl:99`,
  `_make/stage.tl:183`, `_perf/bench/micro_bench.tl:192`,
  `cosmic/check.tl:298`, `cosmic/quicksand/box/run.tl:254` — record-field
  narrowing is the checker gap (`3p/tl/tl_patch/narrow.tl`).
- pcall return shape (5, UPSTREAM): `cosmic/_teal_engine.tl:256`,
  `cosmic/shm.tl:146,171`, `cosmic/sqlite/extras.tl:63,106`.

## Change

This item is a container; its deliverable is children, not a diff.
File five items under G3, one per class above, each spec carrying:
that class's rows verbatim (re-run the `awk` at filing time), the
mechanism named above, the `_build/casts_baseline.tl` rows it lowers,
the tsv reconcile step, and — when the class empties — deletion of its
`###` heading from `docs/design/casts.md` (precedent
`git show cf416d85 -- docs/design/casts.md | grep '^-###'`). The two
UPSTREAM children are checker-patch items: their spec names the
`3p/tl/tl_patch/` entry shape (`narrow.tl:28-32`: named `find`/
`replace` with a `note`), the upstream tl issue to open (D21's
maturity clause), and a `blocks:` on a `bin/cosmic.pin` bump before
any cast is deleted (CLAUDE.md's cold-build rule). Then end this item
`completed`.

Do not re-mint what `3IQtewgN`, `3ISJHfNY`, `3IOK2cxG`, `3IOmhR2S`,
`3IQCrJpB`, `casts-map-view` or `respec 6sv6` already cover.
