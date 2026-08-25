G3 — close the **dynamic-value boundary** class of `from any` casts: 38
of the tree's 192, measured 2026-08-25 against `d3e59de7` and mapped in
`docs/design/casts.md`. These are values whose type genuinely is not
knowable where they cross: a `pcall`, `load`, `require`,
`coroutine.resume` or `package.loaded` return, and the `any`-typed
parameters cosmic's own APIs declare. The files and their site counts:
_cli/main_handlers.tl (1), _docs/publish_test.tl (1), _eval/stage.tl
(1), _perf/harness_test.tl (3), _perf/perf_test.tl (1), _perf/run.tl
(3), _tool/benchmark.tl (1), cmd/cosmic/main.tl (2),
cosmic/_script_cache.tl (1), cosmic/_seal_coverage.tl (3),
cosmic/_teal_engine.tl (1), cosmic/coverage/init.tl (3),
cosmic/doc/query.tl (1), cosmic/fetch/extras.tl (2),
cosmic/fs/path_test.tl (1), cosmic/init.tl (2),
cosmic/quicksand/box/init.tl (2), cosmic/quicksand/box/run.tl (1),
cosmic/rand_test.tl (1), cosmic/searcher_test.tl (1),
cosmic/sqlite/bind.tl (2), cosmic/sqlite/extras.tl (4). Three different
closures, which is why this needs decomposing before it is worked. The
repeated `pcall(require, "cosmic._version")` sites want one typed
helper returning the module or nil — that alone is five sites in five
files (_eval/stage.tl:239, _perf/run.tl:151, cosmic/_script_cache.tl:93,
cosmic/init.tl:51-52). The `any`-typed parameters want the API to
declare what it accepts, a union or a record rather than `any`. What is
left — `load` of an arbitrary chunk, a resumed coroutine's values —
closes only with an `is` guard at the point of use. The closure diffs
must lower the affected rows in `_build/casts_baseline.tl` — run
exactly the regen command the gate prints and commit the result.
