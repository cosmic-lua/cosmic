## Problem

`_cli/citations_test.tl` brackets its cases with a process-wide chdir:
it captures `local ORIGINAL < const > = check.must(fs.cwd())` (line
32), chdirs into a fixture with `assert(fs.set_cwd(ROOT), "chdir into
the fixture")` (line 41), and restores with
`assert(fs.set_cwd(ORIGINAL), "restore the original cwd")` on the
file's LAST line (line 171). Its cited paths resolve against the
process cwd, so every case that reads the fixture needs ROOT to be
current while it runs.

Legacy mode runs each case from its own self-call line, between the
chdir and the restore. Runner mode does not: D29's seam appends
`os.exit(require("cosmic.test").main({...}))` after the source's final
newline, so the restore executes BEFORE any case does and the cases
run in the original cwd.

**Measured** (2026-08-27, `origin/main` at `267c2a4d`), by applying
the batch-2 deletion to a scratch mirror and running the scope:

```
grep -rln '^test_[A-Za-z0-9_]*()$' --include='*_test.tl' _cli _make \
  | grep -v /testdata/ | xargs sed -i -E '/^test_[A-Za-z0-9_]*\(\)$/d'
./bin/cosmic --make build && ./o/bin/cosmic --make test _cli _make
```

→ `test: FAIL (1 of 49 files)`, `_cli/citations_test.tl` reporting
`14 checks: 7 passed, 7 failed`, e.g.
`test_snapshot_leaves_positions_unjudged` failing with
`a snapshot's line numbers and quotes describe a commit this check
cannot read: equal failed: expected 0, got 2`. Every other file in the
scope passes. This is why batch 2 (3IU6AgNN) excludes this one file.

## Change

Migrate `_cli/citations_test.tl` to runner mode so its cases still run
inside the fixture cwd. The naive deletion is not enough here — the
chdir/restore pair has to stop bracketing the file and start bracketing
the RUN. Settle the shape during refinement; the two candidates:

- Drop the restore and the now-unused `ORIGINAL` (both deletions), and
  rewrite the header comment at lines 28-31 that promises a restore.
  A trailing blank line is left at EOF by the deletion and must go, or
  `fmt` fails with `have: <blank>  want: <eof>` on line 156.
- Move the chdir into a helper each case calls, leaving no
  process-wide cwd change at module scope.

## Non-goals

No change to `_cli/citations.tl` itself, to `cosmic/test.tl`,
`_tool/seam.tl` or `_tool/discover.tl`. No change to any other
`*_test.tl` — the seven migration batches own those. No new assertions
and no cases added or removed: the file must still report 14.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- No self-call survives:
  `grep -c '^test_[A-Za-z0-9_]*()$' _cli/citations_test.tl` → `0`.
- `bin/cosmic --make test _cli/citations_test.tl` ends
  `test: PASS (1 file)` and prints `14 tests: 14 passed`.
- Measured for comparison on `267c2a4d` today: with this file still
  legacy, `bin/cosmic --make test _cli _make` (after batch 2) prints
  `455 tests: 455 passed`; with this file migrated it must print
  `469 tests: 469 passed` — the same 49 files, 14 more reported cases.
  (Verified in a scratch mirror by the candidate fix above:
  `ci` reached `fmt: FAIL (1 of 549 files)` on the trailing blank and
  `coverage: FAIL` on `_cli/citations.tl` declining — both are work
  this item owns, and both are why it is not folded into batch 2.)

## Enablement

none needed — the seam and `_tool/discover` already handle this file's
shape; only the file's own cwd bracket has to move.
