Observed during the 2026-08-17 board migration: the coverage report
(`_tool/coverage/report.tl`) walks directories on its own and needed a
hardcoded `items/` exclusion beside `testdata/`, even though the build
model already excludes `items/` via the root `.cosmicignore`. Two
exclusion vocabularies for one question. The report (and any other
tool that scans the tree independently) should derive its exclusions
from `.cosmicignore` so an ignored tree is ignored everywhere at once.

## Refinement pass, 2026-08-19 (measured at f420391; corrects the premise)

The "root `.cosmicignore`" that excludes `items/` is not this repo's —
main has NO committed `.cosmicignore` (`git ls-files | grep cosmicignore`
is empty). It is the BOARD branch's: its root `.cosmicignore` reads
`items/` under the comment "board state: literal data, not sources — the
model never sees it". So the duplication is: the cosmic BINARY's
`_tool/coverage/report.tl` hardcodes a board-branch-shaped exclusion
(`is_excluded`, lines 33–41: `/items/` by position, beside `testdata/`)
so that coverage runs on board checkouts skip item files — knowledge the
board project already declares for itself in the file the build model
reads.

What exists to reuse: `_make/project.tl` has the whole vocabulary —
`read_ignore(root)` (line 111, glob → anchored Lua patterns, `#`
comments, trailing-`/` tolerant) and `is_ignored(patterns, rel, name)`
(line 134) — but neither is exported through `ProjectModule` (line 451);
they are consumed only by the scanner (line 328/369).

Still to settle before ready (the next rung):

- the export: expose `read_ignore`/`is_ignored` from `_make.project`
  (or a small shared module), and whether `_tool/coverage/report.tl`
  requiring `_make.*` is an import direction the tree wants.
- root discovery: `is_excluded` judges bare chunk paths with no project
  root in hand; deriving from `.cosmicignore` needs the root (or the
  patterns) threaded into the report. Name the call sites.
- the `testdata/` and `_test.tl` exclusions stay hardcoded — they are
  coverage doctrine, not project configuration; only the `items/` clause
  is the duplication.
- Acceptance must include a board-worktree coverage run showing item
  files still excluded once the hardcode is gone.

## Refined to ready, 2026-08-19 (the settlements the pass above named)

- **The export**: `_make/project.tl`'s `read_ignore(root)` (line 111)
  and `is_ignored(patterns, rel, name)` (line 134) join `ProjectModule`
  (line 451) — no new module, no logic moves. The import direction has
  precedent: `_cli/reads_lint.tl` already requires `_make.imports`
  (landed via PR #1279), and both trees are embedded in the cosmic
  binary.
- **Root discovery**: the report already HAS the root — its scanner
  (`_tool/coverage/report.tl` line 143, the recursive dir walk) is
  handed the directory to scan, and `is_excluded`'s callers relativize
  against a cwd (line 75). Load `read_ignore(<that dir>)` once at the
  top of the walk and pass the patterns down; `is_excluded(path)`
  gains the patterns parameter (5 call sites, measured: lines 106,
  115, 128, 162 plus the walk).
- **What stays hardcoded**: `testdata/` and the `_test.tl`/`.lua`
  exclusions are coverage DOCTRINE, not project configuration — only
  the `items/` clause (lines 37–41, the board-branch special case)
  deletes, its knowledge now derived from the board branch's own
  committed `.cosmicignore` (`items/` under the comment "board state:
  literal data, not sources", measured on the board worktree).

## Change

1. `_make/project.tl` (451-line record at the end): export `read_ignore`
   and `is_ignored` through `ProjectModule`, doc comments included.
2. `_tool/coverage/report.tl`: the walk loads the scanned root's
   `.cosmicignore` patterns once; `is_excluded` takes them and drops
   the hardcoded `items/` branch; a path any pattern matches is
   excluded exactly as the build model would exclude it.
3. Tests: `_tool/coverage/report_test.tl` (or the suite's existing
   home for report tests) — a fixture tree with `.cosmicignore` naming
   a subdir: its files are excluded from the report; without the file,
   included; `testdata/` excluded regardless.

## Non-goals

- no other tool migrates in this slice (lint's file walk, doc's
  scanner) — each is its own item when its duplication is observed.
- no `.cosmicignore` grammar change; `_make`'s scanner behavior is
  untouched (exports only).

## Acceptance

- `bin/cosmic --make test _tool/coverage/` ends `test: PASS` over the
  coverage tests.
- `git grep -c "items/" -- _tool/coverage/report.tl` prints 0.
- on the board worktree (`o/board`): `bin/cosmic --make coverage` runs
  with no `items/*.tl` row in its report output — the derived exclusion
  doing the hardcode's old job.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — export lines, call sites, precedent, and the
board-worktree proof are measured above.
