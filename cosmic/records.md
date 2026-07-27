# records

 The records a build writes, and the one grammar they are written in.

 Four things leave a run for something other than a person to read:
 a per-target **row**, a stage **summary**, a verb's **verdict**, and
 the **exit code** each maps to. CI greps them, `ci` grades the
 summaries its own stages wrote, and the verdict line is documented
 as the record that survives a truncated log. That makes them an
 interface, and an interface assembled at four call sites with
 `..` is one that drifts a word at a time.

 So it lives here, once. A printer imports it; a test asserting on
 output imports it too, which is what stops a test from freezing a
 spelling the printer has already left behind.

 The grammar:

     ✓ cosmic/fs/init_test.tl (7 test functions)  12ms   <- row
     19 checks: 18 passed, 1 failed                      <- summary
     wall: 73148ms  slowest: fixpoint_test.tl (48022ms)  <- summary
     test: FAIL (1 of 19 files)                          <- verdict

 Exit codes are the same three everywhere: 0 pass, 2 skip, anything
 else fail. `skip` is NOT a pass — a stage that stopped checking and
 said nothing is the failure this distinction exists to make visible.

## Types

### RecordsModule

```teal
local record RecordsModule
  EXIT_OK: integer
  EXIT_SKIP: integer
  ICONS: {string: string}
  status_of: function(exit_code: integer): string
  display: function(base: string): string
  stage_of: function(base: string): string
  row: function(status: string, name: string, count: integer, unit: string, wall_ms: integer): string
  counts: function(passed: integer, failed: integer, skipped: integer): string
  parse_counts: function(text: string): integer, integer, integer
  detail: function(failed: integer, total: integer, unit: string): string
  stage_detail: function(summary_path: string, total: integer, unit: string): string
  verdict: function(verb: string, ok: boolean, what: string): integer
end
```

## Functions

### status_of

```teal
function status_of(exit_code: integer): string
```

 Classify the exit code recorded in a `.got` file.

**Parameters:**

- `exit_code` (integer) - Exit code from the .got file

**Returns:**

- string - "pass" (0), "skip" (2), or "fail" (anything else)

### display

```teal
function display(base: string): string
```

 The name a row carries: the SOURCE this result is about.
 A basename is not a name in a project with directory modules. Eleven
 files are called `init_test.tl` in this tree, and eleven rows called
 `init_test.tl` name none of them -- a failing row you cannot resolve
 to a file costs a grep, and the grep has eleven hits. The build
 directory mirrors the source tree, so dropping `o/` and the stage
 suffix leaves the path the user typed, which is also the path an
 editor will open.
 The coverage lane keeps its `coverage/` segment, because that is a
 true statement about which run produced the row.

**Parameters:**

- `base` (string) - A `.got` base path, e.g. `o/cosmic/fs/init_test.tl.test`

**Returns:**

- string - The source path, e.g. `cosmic/fs/init_test.tl`

### stage_of

```teal
function stage_of(base: string): string
```

 Which stage a `.got` base belongs to, "" when it names none.

**Parameters:**

- `base` (string) - A `.got` base path

**Returns:**

- string - The stage name, or ""

### row

```teal
function row(status: string, name: string, count: integer,
    unit: string, wall_ms: integer): string
```

 One result row.
 The annotation is the count of things the target actually ran, and
 it is only ever attached to a status that ran them: a `skip` with
 "(7 test functions)" describes work that did not happen, and a
 `fail` row's useful number is in the failure block below it.

**Parameters:**

- `status` (string) - "pass", "fail" or "skip"
- `name` (string) - The row's name, from `display`
- `count` (integer) - How many units ran, 0 when unrecorded
- `unit` (string) - What the count counts ("test functions")
- `wall_ms` (integer) - Duration, negative when unrecorded

**Returns:**

- string - The row, without its newline

### counts

```teal
function counts(passed: integer, failed: integer,
    skipped: integer): string
```

 The counts line: `N checks: P passed[, F failed][, S skipped]`.

**Parameters:**

- `passed` (integer)
- `failed` (integer)
- `skipped` (integer)

**Returns:**

- string - The line, without its newline

### parse_counts

```teal
function parse_counts(text: string): integer, integer, integer
```

 Read a stage summary back: what its counts line says.
 The inverse of `counts`, and the reason the two live together. A
 verb's verdict is a claim about the stage that just ran, and the
 only thing that counted that stage is the summary it wrote.
 Guessing from the size of the file list instead makes
 `test: FAIL (7 files)` mean "seven files were selected" while
 reading as "seven failed".

**Parameters:**

- `text` (string) - A summary file's contents

**Returns:**

- integer - Passed, -1 when the text carries no counts line
- integer - Failed
- integer - Skipped

### detail

```teal
function detail(failed: integer, total: integer, unit: string): string
```

 A verb's verdict detail: what it did, or what went wrong with it.
 `N unit` when everything passed, `M of N unit` when it did not, so
 the one line that survives truncation says how much of the stage
 failed rather than how much of it there was.

**Parameters:**

- `failed` (integer) - How many targets failed
- `total` (integer) - How many targets there were
- `unit` (string) - The singular noun ("file")

**Returns:**

- string - The detail, ready for `verdict`

### stage_detail

```teal
function stage_detail(summary_path: string, total: integer,
    unit: string): string
```

 The verdict detail for a stage, read from the summary it wrote.
 Falls back to the plain count when there is no summary to read: a
 stage that failed before writing one (a validation error, a make
 that never started) has no per-target counts, and inventing them
 would be worse than saying how big the stage was.

**Parameters:**

- `summary_path` (string) - Path to the stage's summary file
- `total` (integer) - How many targets the stage had
- `unit` (string) - The singular noun ("file")

**Returns:**

- string - The detail

### verdict

```teal
function verdict(verb: string, ok: boolean, what: string): integer
```

 Print a verb's verdict line and return the exit code it means.
 Every verb ends in one, so a caller that reads only the last line
 still knows what happened.

**Parameters:**

- `verb` (string) - The verb
- `ok` (boolean) - Whether it succeeded
- `what` (string) - Parenthetical detail, empty for none

**Returns:**

- integer - 0 when ok, 1 otherwise
