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
