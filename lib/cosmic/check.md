# check

 Assertion helpers for tests with auto-formatted failure messages.
 Functions in this module throw on failure (level 2) so the error points
 at the caller's line, not inside this module.

## Types

### CheckModule

```teal
local record CheckModule
  eq: function<T>(actual: T, expected: T, label?: string)
  ne: function<T>(actual: T, expected: T, label?: string)
  ok: function(value: any, label?: string)
  must: function<T>(v: T | nil, e?: string, ...: any): T, string, any ...
  err: function(value: any, e: string, label?: string)
  enforcing: function(): boolean
  skip: function(reason: string, strict?: boolean)
  enforced: function(label: string)
end
```

## Functions

### eq

```teal
function eq(actual: T, expected: T, label?: string)
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

### ne

```teal
function ne(actual: T, expected: T, label?: string)
```

 Assert that actual and expected are NOT equal.
 Uses deep comparison for tables, == for all other types.
 Throws with a formatted message when the assertion fails.

**Parameters:**

- `actual` (T) - The value produced by the code under test
- `expected` (T) - The value it should not equal
- `label` (string?) - Optional label prepended to the failure message

### ok

```teal
function ok(value: any, label?: string)
```

 Assert that value is truthy (not nil and not false).
 Throws with a formatted message when the assertion fails.

**Parameters:**

- `value` (any) - The value to test for truthiness
- `label` (string?) - Optional label prepended to the failure message

### err

```teal
function err(value: any, e: string, label?: string)
```

 Assert that a (value, err) pair represents failure.
 Expects value to be nil and err to be a non-nil, non-empty string,
 matching the standard cosmic error-return convention.

**Parameters:**

- `value` (any) - The first return value (expected to be nil)
- `e` (string) - The second return value (expected to be a non-empty string)
- `label` (string?) - Optional label prepended to the failure message

### must

```teal
function must(v: T | nil, e?: string, ...: any): T, string, any ...
```

 Assert a fallible return and narrow away nil.
 The one sanctioned narrowing hole for tests and examples: tl 0.24.8 does
 not flow-narrow record unions through `assert`, so fallible calls used to
 need `assert(x) as T` at every site. `must` centralizes that unsoundness
 behind a runtime nil check. Lua passes multiple returns through, so
 `must(fs.read(path))` fails with fs.read's own error string.
 Like `assert`, must forwards extra returns past the second, so
 `for p in check.must(fs.files(d)) do` keeps the 4th return — the
 to-be-closed guard that releases directory handles on early break.
 A plain `value, err` pair still collapses to the value alone, so
 `print(check.must(fs.read(p)))` prints no trailing nil. The checker,
 though, sees the declared three-value tuple: when must is the LAST
 argument to another call, parenthesize to truncate it —
 `table.insert(parts, (check.must(chunk)))`.

**Parameters:**

- `v` (T?) - The fallible value (nil on failure)
- `e` (string?) - Failure message; a `nil, err` pair fills this in
- `...` (any) - Extra returns (iterator state, closing guard, ...)

**Returns:**

- T - The value, known non-nil
- string - The second argument, forwarded when extras exist
- any... - The extra returns, forwarded unchanged

### enforcing

```teal
function enforcing(): boolean
```

 Report whether the enforcement lane is active.
 True when COSMIC_ENFORCE=1, which the privileged, unsandboxed CI lane
 (`bin/make enforce`) sets. In that mode a sandbox test that cannot
 exercise real enforcement must fail loudly rather than skip silently,
 since there is no outer sandbox left to blame.

**Returns:**

- boolean - True when strict enforcement is required

### skip

```teal
function skip(reason: string, strict?: boolean)
```

 Record that a sandbox test could not exercise real enforcement.
 Writes a machine-readable marker to stderr so the enforce-lane tripwire
 can see the skip (a silent `return` is indistinguishable from a pass).
 When `strict` is set and enforcement is required (COSMIC_ENFORCE=1) the
 skip is escalated to a hard failure — use `strict=true` only where the
 mechanism was probed *available* yet the operation was still blocked,
 which on the unsandboxed lane can only mean an outer sandbox is present.
 Callers still `return` after calling this; it does not exit the process.

**Parameters:**

- `reason` (string) - Why enforcement could not run
- `strict` (boolean?) - Escalate to failure under COSMIC_ENFORCE=1

### enforced

```teal
function enforced(label: string)
```

 Record that a sandbox test actually exercised real enforcement.
 Writes a marker the enforce-lane tripwire counts to confirm the lane is
 not a silent no-op (every test skipping would otherwise look green).

**Parameters:**

- `label` (string) - Short name of the mechanism that enforced
