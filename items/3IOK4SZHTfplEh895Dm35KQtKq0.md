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

## Outcome verified 2026-08-26

All three closures landed (`3IOuRHzP` the typed `cosmic._version`
lookup, `3IOuS3IE` the honest parameters, `3IOuSKFx` the residue). The
container's own observable test — not its children's — re-run against
main `3053b87d`:

```text
git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"
```

11 sites remain tree-wide, and **none of them is in any of the 22 files
this item enumerated**: `_build/casts_test.tl:69,75` (fixture strings
inside the lint's own test, not casts), `cosmic/errno.tl:52`,
`cosmic/fd.tl:187`, `cosmic/fetch/init.tl:238,366,384`,
`cosmic/quicksand/proc.tl:262`, `cosmic/surface_test.tl:92`,
`cosmic/teal.tl:166`, `cosmic/zip.tl:222`. Those belong to other
classes in `docs/design/casts.md` — the fetch trio is board item
`3IQCrJpB` — so the dynamic-value boundary is closed: 38 → 0.

The whole-tree cast count is 220 (`git ls-files '*.tl' | xargs grep -c
-- "-- cast: " | awk -F: '$2>0'` summed), against the 402 the design
doc measured at `d3e59de7`.
