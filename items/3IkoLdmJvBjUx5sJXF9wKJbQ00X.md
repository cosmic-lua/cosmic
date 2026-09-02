## Evidence

Observed by the builder of cosmic-lua/cosmic#1614 (item 3IkOouf3) on
`main` at 2026-09-02: `_make/fixtures_test.tl` spawns `o/bin/cosmic`
against fixture projects, so its verdict depends on the engine embedded
in that binary — but its test record is not invalidated when the engine
changes. After editing `_make/check.tl` (switching `check_files` to
`teal.check_file(f.path, ...)`) and rebuilding `o/bin/cosmic`,
`bin/cosmic --make test _make/fixtures_test.tl` reported the cached
`✓ ... 7658ms` result twice (identical wall time) and only re-ran after
`o/_make/fixtures_test.tl.test.*` was deleted. The file's `--- reads:`
header names only `_make/generate.tl _make/artifact.tl`, and the test
rule's prerequisites are the compiled lua, `o/.stamp/record`, `deps_*`
and `testrun_dep` — none of which move when the binary's engine
changes. CI is unaffected (it starts cold); locally an engine edit can
leave every spawned-binary test green from a stale record. Re-measure
at pull time: edit `_make/check.tl` trivially, `bin/cosmic --make
build`, then `bin/cosmic --make test _make/fixtures_test.tl` twice and
read whether the recorded time repeats.

## Change

Decide in refinement, then build: either a spawned-binary test declares
its dependency on the binary (a `reads:` form the make rule honours,
so `o/bin/cosmic` becomes a prerequisite of the test record), or the
test rule for every `*_test.tl` under `_make/` and `_cli/` gains
`o/bin/cosmic` as a prerequisite by position. Whichever way, the
measured sequence above must re-run the test after an engine rebuild,
and a test that does not spawn the binary must not be re-run by an
unrelated engine change (measure `_make/fixtures_test.tl` and one pure
unit test, e.g. `cosmic/string_test.tl`).

## Non-goals

- No change to what `_make/fixtures_test.tl` asserts.
