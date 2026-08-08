# deep

 Deep table operations.
 Recursive copy, structural equality, and recursive merge for
 nested tables (#994: was cosmic.table, whose name collided with
 Lua's `table` global and whose map/filter/reduce battery read
 worse under Teal annotations than the loops it replaced). All
 functions are pure: inputs are never mutated, and results share no
 tables with their arguments. All functions are infallible.

 Example usage:
   local deep = require("cosmic.deep")
   local copy = deep.copy(config)
   local merged = deep.merge(defaults, overrides)
   if deep.equal(expected, actual) then ... end

 Semantics, frozen here so they never re-open: copy copies table
 keys and values recursively and preserves shared references and
 cycles within the input; metatables are NOT copied or attached —
 the result is plain tables. equal compares structurally (same key
 sets, deep-equal values); table-valued keys are matched by
 identity, not structure. merge recurses where both sides hold
 tables and lets the override win otherwise — array-like tables
 therefore merge by index like any other key (an override list does
 not truncate a longer base list).

## Types

### DeepModule

```teal
local record DeepModule
  copy: function(value: any): any
  equal: function(a: any, b: any): boolean
  merge: function(base: {any: any}, override: {any: any}): {any: any}
end
```

## Functions

### copy

```teal
function copy(value: any): any
```

 Deep-copy a value. Tables are copied recursively (keys included);
 shared references and cycles in the input are preserved in the
 copy. Metatables are not copied: the result is plain tables.
 Non-table values are returned as-is.

**Parameters:**

- `value` (any) - The value to copy

**Returns:**

- any - A copy sharing no tables with the input

### equal

```teal
function equal(a: any, b: any): boolean
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

### merge

```teal
function merge(base: {any: any}, override: {any: any}): {any: any}
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
