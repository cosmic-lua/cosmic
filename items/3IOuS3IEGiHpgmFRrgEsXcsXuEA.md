G3, under `3IOK4SZH` — the second of the dynamic-value boundary's three
closures: the 15 sites where the value's type IS knowable and an API
simply declares `any`.

Two shapes, both closed by making a declaration honest rather than by
guarding at the point of use. Measured 2026-08-25 against `dbca9e77` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`:

**Our own `any`-typed parameters and returns (7).**
`cosmic/sqlite/bind.tl:50,52` (`bind_at(raw_stmt, i, v: any)` — the value
is a `Blob` marker or a bindable scalar, a union the signature could
state); `cosmic/fs/path_test.tl:180` (the walk callback's context);
`cosmic/sqlite/extras.tl:44` (`db_any as Db`);
`cosmic/fetch/extras.tl:273,298` (`opts_any`, `res_any`);
`_perf/harness_test.tl:40` (`ctx as {string: string}`).

**A `require` of a non-literal name, cast to the module's record (8).**
`cosmic/quicksand/box/init.tl:43,150`; `cosmic/quicksand/box/run.tl:68`;
`_docs/publish_test.tl:58`; `cosmic/searcher_test.tl:41`;
`_perf/perf_test.tl:49`; `_perf/run.tl:167`; `cosmic/doc/query.tl:39`.
Each names the record it wants, so the type is known — what is missing is
a typed way to require a module the checker cannot resolve statically.

Refinement should decide whether these are one slice or two: the second
shape may collapse into the same helper `3IOK4SZH`'s version-lookup child
produces, in which case it belongs there or behind it as a `blocked_by`,
and this item shrinks to the seven honest-parameter sites.
