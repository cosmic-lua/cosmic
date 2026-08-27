The `call-after-define` lint fails a correct test file when a `test_*`
function declares a nested `local record` or `local enum`: the block-depth
walk behind the rule counts every block opener EXCEPT Teal's type
declarations, so the record's `end` decrements depth to zero and the walk
reports the function as ending there.

## Evidence

Found 2026-08-25 while refining board item `3IOK542Q`, whose spec wanted a
typed case record declared inside the test that uses it. Measured against
`1dc5aa14` with a binary built from it. This eight-line file is correct —
the call is on the line after the function's `end` — and fails:

```teal
local function test_nested_record()
  local record Case
    want: string
  end
  local c: Case = {want = "x"}
  assert(c.want == "x")
end
test_nested_record()
```

```
$ o/bin/cosmic --check lint /tmp/nested_record_test.tl
/tmp/nested_record_test.tl:1:1: call-after-define: /tmp/nested_record_test.tl:1:
  'test_nested_record' must be called immediately after its definition, so a
  failing run names the function
    | local function test_nested_record()
```

The same file with a `local enum` in place of the record fails
identically. A nested `if ... end` and a nested `local function ... end`
both PASS, so this is not general block confusion.

**Root cause, read from the source.** `end_line_of`
(`_cli/lint.tl:163-193`) walks tokens from the `function` keyword,
incrementing depth on `for`, `while`, `do`, `function`, `if` and `repeat`
(lines 173-186) and returning the line where an `end` brings depth back to
zero. `record`, `enum` and `interface` open a block that closes with `end`
and are in none of those branches, so a nested one lands the walk on the
wrong `end`. `check_call_after_define` (`_cli/lint.tl:211`) then reads the
line after that wrong `end` and, finding a declaration rather than the
call, reports the function.

## Why it might matter

The rule is a gate every `_test.tl` in the tree must pass, and the failure
names the wrong problem: the diagnostic points at the function definition
and says the call is misplaced, when the call is exactly where it must be.
A session that writes the natural thing — a type declared where it is used
— has no way to read the fix out of the message, and the workaround
(hoisting the declaration to file scope) is not obviously related to what
the lint said.

## Direction, not a decision

Add `record`, `enum` and `interface` to the openers `end_line_of` counts,
and make the repro above a case in `_cli/lint_test.tl` alongside the
hoisted version, which must keep passing. Worth checking whether any other
consumer of `end_line_of` exists before changing it, and whether Teal's
lexer gives these tokens a distinguishable kind rather than matching on
the word.

## Escalation, 2026-08-27T05:3xZ — this now blocks the runner-mode migration

Found while implementing 3IU6AZEx (batch 1/7 of the all-runner
migration) and bounced there. The same counter now sits under D29's
compile seam, and its failure mode there is worse than a false lint
failure: a definition `end_line_of` cannot close is SKIPPED by
`_tool/discover.tl` (its own comment at :113-118 says so, "verbatim
until 3IP9ijhv fixes the counter"), so the generated tail omits that
case and **the test silently stops running** once its file is
migrated.

The type-position `function` token is a second shape of the same bug,
alongside the nested `record`/`enum` this item was filed for: it opens
no block and has no `end`, so the walk never closes. Measured on
`_types/tlast_test.tl`, whose second test contains
`assert(thaw is function(any): (any, any), …)` — discover reports one
case where the file has two, on unmodified main as much as after
migration.

**Tree-wide today** — `discover`'s case count against a count of
`local function test_*`, over all 275 test files:

```
./_make/resolution_test.tl:        11 definitions, discover found 10
./_tool/seam_test.tl:               8 definitions, discover found  4
./_types/tlast_test.tl:             2 definitions, discover found  1
./cosmic/_teal_ast_test.tl:         3 definitions, discover found  2
./cosmic/fd_read_test.tl:           6 definitions, discover found  5
./cosmic/fs/find_close_test.tl:     3 definitions, discover found  2
./cosmic/sandbox/init_test.tl:     12 definitions, discover found 10
./cosmic/searcher_test.tl:          8 definitions, discover found  6
./cosmic/sqlite/advanced_test.tl:  23 definitions, discover found 21
./cosmic/sqlite/close_test.tl:      9 definitions, discover found  7
10 files under-counted, 17 definitions invisible to the seam
```

All seven migration batches (3IU6AZEx, 3IU6AgNN, 3IU6AsZC, 3IU6B7LD,
3IU6BPFg, 3IU6BiCH, 3IU6BjUI) now carry a blocker edge on this item.

**A note on placement**: this sits at band 3 as a lint-ergonomics
defect. That was right when it only produced a false failure on a
correct file. It now gates a migration in band 6 and can silently drop
tests, so the pair "this counter fix" versus "the runner-mode
migration" is worth re-asking — a blocker cannot usefully be ranked
below what it blocks.

**Whatever fixes it should be proved against both shapes**: a nested
`local record`/`local enum` (this item's original evidence) and a
`function` token in type position (`x is function(any): (any, any)`,
a `local f: function(string): integer` annotation). The check that
catches a regression is the equality above — discover's case count
must equal the file's `local function test_*` count — asserted over
the whole tree, not a fixture.
