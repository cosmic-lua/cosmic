Split out of `3IOCdZCA` during refinement, because the flag has nowhere to be
spelled. D29 promises `--make test <path> --filter <substring>`, narrowing by
test name inside a file with the plain-substring contract the benchmark and
example runners honour, passed to the child as `COSMIC_TEST_FILTER`. Half of
that already works by accident: `_tool/testrun.tl:59-69` copies the whole
parent environment to the child except `COSMIC_COVERAGE` and
`COSMIC_MAKE_ROOT`, and `cosmic/test.tl:47-62` already reads
`COSMIC_TEST_FILTER`, so an ambient value reaches the cases today. Two things
are missing and both are blocked. (1) The spelling: the flag needs a value
entry in `_cli/args.tl` plus a field, a mapping and a dispatch line in
`cmd/cosmic/main.tl`, and a flag branch in `_make/init.tl` beside `--baseline`
and `--fix` (`_make/init.tl:351-384`). Measured 2026-08-27: `wc -l
cmd/cosmic/main.tl` is 499 and `wc -l _make/init.tl` is 498, against the hard
500-line cap `_tool/lint.tl:31` enforces as `n > limit` — one and two lines of
headroom, so a file split has to come first. (2) Graph invalidation: nothing
declares `COSMIC_TEST_FILTER`, so `_make/envstamp.tl` never makes its value a
prerequisite and a re-run under a new filter replays cached `.got` files —
the same hazard that module was built for `FUZZ_ITERS`. Refining this item
should decide which file to split (or what to remove) before specifying the
flag.
