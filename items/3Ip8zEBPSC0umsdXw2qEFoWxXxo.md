## Change

1. `docs/guides/make.md` "Environment variables" public table (lines 458-469): add rows for the public registry variables the BUILD reads and the table omits — `COSMIC_COVERAGE_ENV` ("`1` marks the `.cosmic-coverage` recording environment; `--baseline` refuses elsewhere"), and one folded row `COSMIC_FIXPOINT`, `COSMIC_FAIL_FAST`, `COSMIC_BENCHMARK_MIN_MS` ("gate knobs: the two-build fixpoint test, stop a batched compile at its first failure, `--benchmark`'s timing floor"). The file is at 498 lines of the 500 cap (D39, `docs/decisions/d39-no-prose-exemption-from-the-file-cap.md`; `git show origin/main:docs/guides/make.md | wc -l`): rewrap the `.gitattributes` paragraph at lines 447-450 (line 449 is 32 characters wide, measured with `awk '{print length}'`) so the file ends at or below 498 lines after the two rows land. Verify with `wc -l`.
2. `_build/env_vars_test.tl` (97 lines): add `test_the_guide_table_matches_the_builds_public_reads`. Parse `docs/guides/make.md` from the line `## Environment variables` to the next `## ` heading; a table row is a line starting with `| \``; collect every `COSMIC_[A-Z_]+` inside backticks on those rows into a set. Assert two directions: (a) every collected name is a row with `public = true` in `env_vars.rows` (`_cli/env_vars.tl:104-117` exports `rows`); (b) every public row whose name the build reads — reuse `scan()` restricted to `_make` and `_cli/build` — is in the collected set. Both failure messages list the offending names, the shape `test_every_read_variable_is_declared` (lines 67-81) uses. `docs/guides/make.md` must be added to the file's `--- reads:` header (line 2) so an edit to the guide re-runs the ratchet.

## Evidence

Public rows the build reads today (`git grep -oh "[\"']COSMIC_[A-Z_]*[\"']" origin/main -- '_make/*.tl' '_cli/build/*.tl' ':!*_test.tl' | tr -d "\"'" | sort -u`, intersected with `public = true` rows of `_cli/env_vars.tl:19-63`):
```
COSMIC_BENCHMARK_MIN_MS  COSMIC_COVERAGE  COSMIC_COVERAGE_ENV  COSMIC_FAIL_FAST
COSMIC_FENCE  COSMIC_FIXPOINT  COSMIC_JOBS  COSMIC_MAKE_ROOT
```
(`COSMIC_MAKE`, `COSMIC_MAKE_GEN`, `COSMIC_MAKE_STEP`, `COSMIC_EXEC_ROOT` are `public = false` and belong to the guide's internal paragraph, already there.) The table today (`sed -n 462,470p`) names `COSMIC_FENCE`, `COSMIC_JOBS`, `COSMIC_MAKE_ROOT`, `COSMIC_COVERAGE`, `COSMIC_VERSION`, `COSMIC_INSTRUMENTATION`, `COSMIC_LOG_LEVEL`, `COSMIC_NO_WELCOME`, `COSMIC_NO_REQUIRE_HINTS`, `COSMIC_FULL_TRACEBACK` — four of the eight build-read names are missing, `COSMIC_COVERAGE_ENV` among them (`git grep -n COSMIC_COVERAGE_ENV origin/main -- docs` prints nothing). The existing ratchet checks only registry-vs-code in both directions (`git show origin/main:_build/env_vars_test.tl | grep -n 'local function test_'` → lines 67, 83); no test reads the guide.

## Non-goals

`sys/help.md`'s env section is rendered from `env_vars.help_lines()` (`_cli/env_vars.tl:84-101`) and already carries the new row; nothing to change there.
