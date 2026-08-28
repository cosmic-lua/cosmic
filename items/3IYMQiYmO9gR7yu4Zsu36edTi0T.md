## Goal

G3 — an honest type layer, no escape hatches. This is the TAIL of the
census in `docs/design/casts.md`: every class holding fewer than eight
sites that no other open item covers, 32 sites across six classes,
gathered here because none is a session's work alone and each wants a
different mechanism. **decoded data shaping** (7):
`_tool/coverage/baseline.tl` 2, `cmd/cosmic/embed_gen.tl` 2,
`_build/casts.tl` 1, `_tool/coverage/baseline_test.tl` 1,
`cosmic/literal_example.tl` 1 — closes HERE, because `cosmic.shape`
already validates a value against a declared spec and returns it typed,
which is the decode-into-a-record step these sites hand-roll.
**record union after guard** (7): `_make/generate.tl`, `_make/stage.tl`,
`_perf/bench/micro_bench.tl`, `cosmic/check.tl`, `cosmic/fs/walk.tl`,
`cosmic/quicksand/box/run.tl`, `cosmic/quicksand/proxy.tl`, one each —
closes UPSTREAM, in `3p/tl/tl_patch/` or tl, because record-FIELD
narrowing is the named gap. **incremental record construction** (7):
`cosmic/sqlite/init.tl` 2, then `cosmic/fetch/init.tl`,
`cosmic/format/init.tl`, `cosmic/quicksand/box/merge.tl`,
`cosmic/signal.tl`, `cosmic/sqlite/row_iter.tl` — closes HERE, mostly
by writing record literals the checker verifies field by field.
**pcall return shape** (5): `cosmic/shm.tl` 2,
`cosmic/sqlite/extras.tl` 2, `cosmic/_teal_engine.tl` 1 — closes
UPSTREAM, since tl knows the callee's type at the call site and could
type `pcall`'s success arm from it. **map view of a declared value**
(4): `cosmic/coverage/init.tl` 2, `cosmic/fetch/init.tl` 1,
`cosmic/quicksand/box/merge.tl` 1 — closes HERE; declaring the type is
the whole fix. **sqlite row column read** (2):
`cosmic/sqlite/extras_test.tl`, `cosmic/sqlite/lifecycle_test.tl` —
closes HERE with typed column accessors on `Row`, the residue of the
completed accessor work. First refinement should cut children along the
here/upstream line rather than treating this as one diff; every closure
lowers the affected `_build/casts_baseline.tl` rows. Class descriptions
and exemplar citations are the matching `###` sections of
`docs/design/casts.md`; per-site lists are
`docs/design/cast-sites.tsv`. Do not re-mint what `3IQtewgN`,
`3ISJHfNY`, `3IOK2cxG`, `3IOmhR2S` or `3IQCrJpB` already cover.
