## Evidence

`git show pull/1656/head:_make/generate.tl | wc -l` → 499. The cap is
500, enforced by `cosmic --check lint` (CLAUDE.md, file length). The
file went 483 → 499 in PR #1656 (the seed pass call sites, +16), so
the next one-line change to `sources()`, `closure_argv`, or the stamp
digest fails the lint before it can be reviewed. Its shape today:
`closure_argv` (generate.tl:145-217, the strict closure compile and
its argv), `run_generator` (218-231), the stamp digest (286-335),
`sources()` (363 onward).

## Change

Move `closure_argv` and the include-path helpers it owns (the block at
:108-217, including the comment block that documents the seed
fallback) into a new `_make/closure.tl` exposing `argv(...)` with the
same signature; `generate.tl` requires it and keeps `run_generator`,
the stamp digest and `sources()`. No behaviour change: the existing
`_make/generate_test.tl` cases that spy on `closure_argv`'s returned
flags (`test_closure_compile_includes_the_seed_dir_when_present` and
its neighbours) move to `_make/closure_test.tl` unchanged except for
the module name. Target: `generate.tl` under 400 lines, `closure.tl`
under 150.

## Non-goals

No change to what the closure compiles or in which order generators
run.
