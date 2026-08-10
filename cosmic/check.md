# check

 Assertion helpers for tests with auto-formatted failure messages.
 Functions in this module throw on failure (level 2) so the error points
 at the caller's line, not inside this module. This is the one module
 exempt from the never-throw doctrine, and `needs`/`reap` may exit
 the process because the runner grades exit codes — the record is
 docs/decisions/d23-check-throws.md; no other cosmic.* module may
 throw or exit, so never require check from library code.

## Types

### CheckModule

```teal
local record CheckModule
  EXIT_SKIP: integer
  equal: function<T>(actual: T, expected: T, label?: string)
  not_equal: function<T>(actual: T, expected: T, label?: string)
  truthy: function(value: any, label?: string)
  must: function<T>(value: T | nil, err?: string): T
  failed: function(value: any, err: string, label?: string)
  enforcing: function(): boolean
  enforce_skip: function(reason: string, strict?: boolean)
  needs: function(what: string, present: boolean)
  reap: function(pid: integer, what: string)
  enforced: function(label: string)
end
```

## Functions

### equal

```teal
function equal(actual: T, expected: T, label?: string)
```

 Assert deep equality between actual and expected.
 Uses deep comparison for tables, == for all other types.
 Throws with a formatted message when the assertion fails.
 Generic over the compared type: comparing values of different types
 (a Stat against a string, a number against a boolean) fails at
 check time instead of always-unequal at runtime.

**Parameters:**

- `actual` (T) - The value produced by the code under test
- `expected` (T) - The value it should equal
- `label` (string?) - Optional label prepended to the failure message

### not_equal

```teal
function not_equal(actual: T, expected: T, label?: string)
```

 Assert that actual and expected are NOT equal.
 Uses deep comparison for tables, == for all other types.
 Throws with a formatted message when the assertion fails.

**Parameters:**

- `actual` (T) - The value produced by the code under test
- `expected` (T) - The value it should not equal
- `label` (string?) - Optional label prepended to the failure message

### truthy

```teal
function truthy(value: any, label?: string)
```

 Assert that value is truthy (not nil and not false).
 Throws with a formatted message when the assertion fails.

**Parameters:**

- `value` (any) - The value to test for truthiness
- `label` (string?) - Optional label prepended to the failure message

### failed

```teal
function failed(value: any, err: string, label?: string)
```

 Assert that a (value, err) pair represents failure.
 Expects value to be nil and err to be a non-nil, non-empty string,
 matching the standard cosmic error-return convention.

**Parameters:**

- `value` (any) - The first return value (expected to be nil)
- `err` (string) - The second return value (expected to be a non-empty string)
- `label` (string?) - Optional label prepended to the failure message

### must

```teal
function must(value: T | nil, err?: string): T
```

 Assert a fallible return and narrow away nil.
 Since #1065 plain `assert` narrows here too — the carried tl patch
 declares that it strips nil — so this is no longer the only way to
 get past a `T | nil` in a test. What it still buys: Lua passes
 multiple returns through, so `must(fs.read(path))` fails with
 fs.read's own error string rather than a message the call site had
 to write; and it narrows nil ONLY, so a `false` value passes
 through where `assert` would throw on it.
 Declares ONE return (#1064), so it composes exactly where `assert`
 does: `return check.must(sqlite.open(":memory:"))` and
 `table.insert(parts, check.must(chunk))` both type-check, with no
 parenthesis-truncation anywhere. There is nothing to forward past
 slot 2, because a fallible return has two slots and no more (D20
 rule 11, enforced by the `fallible-returns` lint) — a resource that
 must be released rides on the returned record's `__close`, the way
 `fs.find_iter` and `sqlite.Rows` do.

**Parameters:**

- `value` (T?) - The fallible value (nil on failure)
- `err` (string?) - Failure message; a `nil, err` pair fills this in

**Returns:**

- T - The value, known non-nil

### enforcing

```teal
function enforcing(): boolean
```

 Report whether the enforcement lane is active.
 True when COSMIC_ENFORCE=1. In that mode a sandbox test that cannot
 exercise real enforcement must fail loudly rather than skip silently,
 since there is no outer sandbox left to blame.
 NOTHING SETS IT YET. `--make enforce` — a privileged, unsandboxed
 lane — is a named, planned verb, and this is the mechanism waiting
 for it, exercised by `check_assertions_test.tl` and by hand. Said
 plainly because a switch that reads as live and is not is worse
 than no switch: the skips it would escalate are silently tolerated
 in every lane that runs today.

**Returns:**

- boolean - True when strict enforcement is required

### enforce_skip

```teal
function enforce_skip(reason: string, strict?: boolean)
```

 Record that a sandbox test could not exercise real enforcement.
 Writes a machine-readable marker to stderr so the enforce-lane tripwire
 can see the skip (a silent `return` is indistinguishable from a pass).
 When `strict` is set and enforcement is required (COSMIC_ENFORCE=1) the
 skip is escalated to a hard failure — use `strict=true` only where the
 mechanism was probed *available* yet the operation was still blocked,
 which on the unsandboxed lane can only mean an outer sandbox is present.
 Callers still `return` after calling this; it does not exit the
 process — it only RECORDS the enforcement gap (`needs` is the one
 that exits).

**Parameters:**

- `reason` (string) - Why enforcement could not run
- `strict` (boolean?) - Escalate to failure under COSMIC_ENFORCE=1

### needs

```teal
function needs(what: string, present: boolean)
```

 Declare a precondition a test needs, and say what to do without it.
 The trap this closes: a test that prints "skip: …" and returns exits
 0, and the runner counts 0 as a PASS -- `status_of` reserves exit 2
 for skip. So a suite whose fixtures went missing reports green while
 testing nothing, which is how a gate quietly becomes decorative.
 Locally the skip stands: a cold checkout should not fail for lacking
 a build. In CI it is a hard failure, because there the precondition
 is always provisioned and its absence means the provisioning broke,
 not that the developer is mid-setup.
 Say so by EXITING — which this function does itself: when the
 precondition is missing it prints the skip and exits EXIT_SKIP, so
 a caller cannot forget the exit and turn a skip into a silent
 pass. When it returns at all, the precondition held.
     check.needs("the make engine", fs.is_file(make_bin))

**Parameters:**

- `what` (string) - What is missing, named for the message
- `present` (boolean) - Whether the precondition holds

### reap

```teal
function reap(pid: integer, what: string)
```

 Reap a forked child and grade what its exit code said.
 An exit code is the ONLY thing a forked child can tell its parent,
 and a parent that discards it makes the fork a hole in the runner's
 grading -- the runner grades the PARENT, and the parent exited 0.
 Both faces of that are silent:
 - a child exiting `EXIT_SKIP` has announced that its environment
   cannot run the test, and the run reports a pass instead;
 - a child exiting nonzero has failed, and what surfaces upstream is
   whatever the parent trips over next -- an EOF from `recv` names
   the wrong end of the connection.
 A skip ends the FILE rather than the test, by the same argument
 `needs` makes: the parent is asserting on half a conversation, and
 the runner's grading reads only the exit code.

**Parameters:**

- `pid` (integer) - The child to reap
- `what` (string) - What the child was, for the message

### enforced

```teal
function enforced(label: string)
```

 Record that a sandbox test actually exercised real enforcement.
 Writes a marker the enforce-lane tripwire counts to confirm the lane is
 not a silent no-op (every test skipping would otherwise look green).

**Parameters:**

- `label` (string) - Short name of the mechanism that enforced
