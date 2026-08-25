# shape

 Validate a decoded value into a declared record.
 A value that comes out of json.decode, literal.parse, a loaded
 chunk or Response:json() is `any`: every field read off it costs a
 cast, and nothing checks that the field is the type the code
 assumes. `into` walks the value against a Spec built from the
 combinators below and hands it back typed, so the check happens
 once and the reads are ordinary typed reads.

 The target type comes from the CALLER's annotation, not from the
 Spec. Three shapes infer it and one does not:

   -- a function declared `T | nil, string`, returning it directly
   return shape.into(raw, SPEC)
   -- a local with its error
   local m, err: Meta | nil, string = shape.into(raw, SPEC)
   -- in tests
   local m: Meta = check.must(shape.into(raw, SPEC))
   -- and the one that FAILS, with "cannot infer declaration type":
   local m = check.must(shape.into(raw, SPEC))

 Example usage:
   local shape = require("cosmic.shape")
   local RELEASE <const> = shape.record({
     tag_name = shape.string,
     draft = shape.optional(shape.boolean),
   })
   local rel, err: Release | nil, string = shape.into(decoded, RELEASE)

 Semantics, frozen here so they never re-open:
 extra keys a Spec does not name are IGNORED, so a payload that
 grows a field does not start failing; a missing key and a JSON
 `null` are the same thing (both are nil) and `optional` is what
 admits either; validation is recursive and total over what the
 Spec names; nothing is coerced (`number` refuses `"1"`); errors are
 plain strings carrying the first mismatch and its dotted path.
 `into` returns the SAME table it was given, not a copy —
 `integer` normalizes a whole-valued float to an integer in place,
 which is the only write it makes.

## Types

### Spec

 One node of a shape description. Opaque to callers: build it with
 the combinators and pass it to `into`, never construct it directly.

```teal
local record Spec
  --  Which validator this node is: one of the primitive names
  --  ("string", "number", "integer", "boolean", "any") or a container
  --  name ("list", "map", "record").
  kind: string
  --  The element Spec, for "list" and "map".
  of: Spec
  --  The declared fields, for "record".
  fields: {string: Spec}
  --  Whether nil satisfies this node.
  optional: boolean
end
```

### ShapeModule

## Functions

### list

```teal
function list(of: Spec): Spec
```

 A list whose every element has shape `of`.

**Parameters:**

- `of` (Spec) - The element shape

**Returns:**

- Spec - The node

### map

```teal
function map(of: Spec): Spec
```

 A table with string keys whose every value has shape `of`.

**Parameters:**

- `of` (Spec) - The value shape

**Returns:**

- Spec - The node

### record

```teal
function record(fields: {string: Spec}): Spec
```

 An object with the declared fields. Keys the fields table does not
 name are ignored.

**Parameters:**

- `fields` ({string:Spec}) - The declared fields

**Returns:**

- Spec - The node

### optional

```teal
function optional(of: Spec): Spec
```

 The same shape as `of`, satisfied by nil as well.

**Parameters:**

- `of` (Spec) - The shape to make optional

**Returns:**

- Spec - The node

### into

```teal
function into(value: any, spec: Spec): T | nil, string
```

 Validate `value` against `spec` and return it typed.
 The returned table is the same table, not a copy. `T` comes from
 the caller's annotation — see the module doc comment for the three
 call shapes that infer it and the one that does not.

**Parameters:**

- `value` (any) - The decoded value to validate
- `spec` (Spec) - The shape it must have

**Returns:**

- T - | nil The value, typed, when it validates
- string - The first mismatch, with its path, when it does not
