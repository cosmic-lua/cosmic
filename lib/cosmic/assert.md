# assert

 Assertion helpers for tests with auto-formatted failure messages.
 Functions in this module throw on failure (level 2) so the error points
 at the caller's line, not inside this module.

## Types

### AssertModule

```teal
local record AssertModule
  eq: function(actual: any, expected: any, label?: string)
  ne: function(actual: any, expected: any, label?: string)
  ok: function(value: any, label?: string)
  err: function(value: any, e: string, label?: string)
end
```

## Functions

### eq

```teal
function eq(actual: any, expected: any, label?: string)
```

 Assert deep equality between actual and expected.
 Uses deep comparison for tables, == for all other types.
 Throws with a formatted message when the assertion fails.

**Parameters:**

- `actual` (any) - The value produced by the code under test
- `expected` (any) - The value it should equal
- `label` (string?) - Optional label prepended to the failure message

### ne

```teal
function ne(actual: any, expected: any, label?: string)
```

 Assert that actual and expected are NOT equal.
 Uses deep comparison for tables, == for all other types.
 Throws with a formatted message when the assertion fails.

**Parameters:**

- `actual` (any) - The value produced by the code under test
- `expected` (any) - The value it should not equal
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
- `err` (string) - The second return value (expected to be a non-empty string)
- `label` (string?) - Optional label prepended to the failure message
