# table

 Table utilities.
 Deep operations (copy, merge, structural equality) for nested
 tables, and the classic list transforms (map, filter, reduce) with
 generic types. All functions are pure: inputs are never mutated,
 and the deep operations return results that share no tables with
 their arguments. All functions are infallible.

 The module name collides with Lua's `table` global; bind it as
 `tbl` (the convention used throughout this codebase, like `str`
 for cosmic.string) so the stdlib stays reachable.

 Example usage:
   local tbl = require("cosmic.table")
   local copy = tbl.deep_copy(config)
   local merged = tbl.deep_merge(defaults, overrides)
   local squares = tbl.map({1, 2, 3}, function(n: number): number
     return n * n
   end)

 Deep-operation semantics, frozen here so they never re-open:
 deep_copy copies table keys and values recursively and preserves
 shared references and cycles within the input; metatables are NOT
 copied or attached — the result is plain tables. deep_eq compares
 structurally (same key sets, deep-equal values); table-valued keys
 are matched by identity, not structure. deep_merge recurses where
 both sides hold tables and lets the override win otherwise —
 array-like tables therefore merge by index like any other key
 (an override list does not truncate a longer base list).

 Reserved names: keys, values, contains, invert, and group_by are
 reserved for a post-stable battery. Do not reuse these names for
 anything else.

## Types

### TableModule

```teal
local record TableModule
  deep_copy: function(value: any): any
  deep_eq: function(a: any, b: any): boolean
  deep_merge: function(base: {any: any}, override: {any: any}): {any: any}
  map: function<T, U>(list: {T}, fn: function(T): U): {U}
  filter: function<T>(list: {T}, fn: function(T): boolean): {T}
  reduce: function<T, A>(list: {T}, fn: function(A, T): A, init: A): A
end
```

## Functions

### deep_copy

```teal
function deep_copy(value: any): any
```

 Deep-copy a value. Tables are copied recursively (keys included);
 shared references and cycles in the input are preserved in the
 copy. Metatables are not copied: the result is plain tables.
 Non-table values are returned as-is.

**Parameters:**

- `value` (any) - The value to copy

**Returns:**

- any - A copy sharing no tables with the input

### deep_eq

```teal
function deep_eq(a: any, b: any): boolean
```

 Compare two values for deep structural equality: equal scalars, or
 tables with the same key sets and deep-equal values. Table-valued
 keys are matched by identity, not structurally. Handles cyclic
 inputs without looping.

**Parameters:**

- `a` (any) - First value
- `b` (any) - Second value

**Returns:**

- boolean - True when a and b are structurally equal

### deep_merge

```teal
function deep_merge(base: {any: any}, override: {any: any}): {any: any}
```

 Recursively merge two tables into a new one. Where both sides
 hold tables the merge recurses; otherwise the override value wins.
 Neither input is mutated and the result shares no tables with
 either. Array-like tables merge by index like any other key: an
 override list replaces base elements position by position but does
 not truncate a longer base list.

**Parameters:**

- `base` ({any:any}) - The base table (defaults)
- `override` ({any:any}) - The overriding table (wins on conflict)

**Returns:**

- {any:any} - A new deeply-merged table

### map

```teal
function map(list: {T}, fn: function(T): U): {U}
```

 Transform each element of a list, returning a new list of the
 results in the same order. The input is not mutated.

**Parameters:**

- `list` ({T}) - The input list
- `fn` (function(T):) - U Transform applied to each element

**Returns:**

- {U} - A new list of transformed elements

### filter

```teal
function filter(list: {T}, fn: function(T): boolean): {T}
```

 Keep the elements of a list for which the predicate returns true,
 preserving order. The input is not mutated.

**Parameters:**

- `list` ({T}) - The input list
- `fn` (function(T):) - boolean Predicate deciding which elements stay

**Returns:**

- {T} - A new list of the elements that passed

### reduce

```teal
function reduce(list: {T}, fn: function(A, T): A, init: A): A
```

 Fold a list into a single value, left to right, starting from
 init. An empty list returns init unchanged.

**Parameters:**

- `list` ({T}) - The input list
- `fn` (function(A,) - T): A Combiner of the accumulator and each element
- `init` (A) - The initial accumulator value

**Returns:**

- A - The final accumulator
