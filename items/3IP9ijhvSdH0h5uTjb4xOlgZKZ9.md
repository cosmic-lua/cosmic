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
