## Goal

3HyRdABz — the lint tells the truth about a correct file; and this
counter now sits under D29's compile seam, where a definition it cannot
close is a test that silently stops running, so it gates all seven
3IU6* runner-migration batches under 3IU6AZEx.

## Change

Replace the token depth walk in `_tool/discover.tl` (`end_line_of`,
lines 56-93) with the parser's own end positions: lex as today, then
`tl.parse_program(tokens, errs, file)` (exposed by the narrowed API,
`o/_types/types_gen/tl.d.tl:70`), walk the returned program node's
top-level statements, and for each node with `kind == "local_function"`
whose `name.tk` matches `^test_`, read `y` (definition line) and `yend`
(the line of the closing `end`). The parser sets `yend` from the `end`
token itself (`end_at`/`verify_end`, `o/3p/tl/tl.lua:2537,2551`), so a
nested `record`/`enum`/`interface` body cannot pull it early and a
type-position `function` token cannot lose it — both shapes of this
defect die together. Delete `end_line_of` entirely (discover is its
only holder: `grep -rn "end_line_of" --include='*.tl' . | grep -v ^./o/`
returns only `_tool/discover.tl` today — re-measure at pull) and drop
the now-dead skip comment at `_tool/discover.tl:113-118`. Keep the rest
of `discover` — the called-scan over lines, the referenced-elsewhere
token scan, the mode classification — unchanged. AST node access on the
`any`-typed program needs `as` casts; each carries a `-- cast:` reason.

In `_tool/discover_test.tl`, add cases for: a nested `local record`, a
nested `local enum`, a nested `local interface`; a type-position
`function` token both as `x is function(any): (any, any)` and as a
`local f: function(string): integer` annotation; and a tree-wide
equality test in the `_build/casts.tl` TREES idiom (`fs.find` per tree,
`--- reads:` grants, skip `testdata/`): for every committed `*_test.tl`,
`#discover(path, src, lines).cases` equals the file's count of lines
matching `^local function test_[%w_]*%(`.

Measured now (2026-08-27, main head `4b55a888`, binary built from it):

- the eight-line nested-record repro from this item's Evidence and its
  enum twin both fail `o/bin/cosmic --check lint` (exit 1,
  `call-after-define`, "not called immediately after its definition");
- tree-wide, discover under-counts 10 files / 17 definitions invisible
  (probe: for each `git ls-files '*_test.tl'`, compare
  `#discover(...).cases` with the `^local function test_[%w_]*%(` line
  count) — the file list matches this item's escalation table verbatim;
- the fix shape is prototyped: `tl.parse_program` on the nested-record
  repro yields a `local_function` node with `y=1 yend=7`, and on
  `_types/tlast_test.tl` finds both definitions (`yend=32`, `yend=60`),
  with 0 parse errors on either file;
- `wc -l` — `_tool/discover.tl` 181, `_tool/discover_test.tl` 113: both
  have headroom under the 500-line cap for this change.

## Non-goals

No change to the mode vocabulary (legacy/runner/mixed/empty), to the
immediacy rule (the call sits on the next non-blank line after `end`),
or to the referenced-elsewhere disqualifier. No edits to
`_tool/seam.tl` or `_cli/lint.tl` — both consume `discover.discover`
and inherit the fix. No test file migrates to runner mode here (that is
3IU6AZEx and its siblings). The formatter's separate keyword walk
(`cosmic/format/types.tl`) was fixed by 3ISWuGko and is not touched.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/discover_test.tl` passes, including the
  new nested-record/enum/interface cases, the two type-position
  `function` cases, and the tree-wide equality test (which fails on
  today's tree with 10 under-counted files, 17 definitions invisible).
- `grep -c "end_line_of" _tool/discover.tl` = 0.

## Enablement

none needed — the change is self-contained in `_tool/discover.tl` plus
its test file; nothing has to land first. The seven 3IU6* migration
batches wait on THIS item and resume when it lands.
