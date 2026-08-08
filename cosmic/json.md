# json

 JSON encoding and decoding utilities.
 Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.

 NULL POLICY (lossy — read before round-tripping):
 Lua tables cannot hold nil values, so JSON `null` does not survive a
 decode/encode round-trip:
 - `{"a":null,"b":1}` decodes with `a` absent and re-encodes as `{"b":1}`.
 - `[1,null,2]` decodes with a hole at index 2; re-encoding sees a table
   of length 1 and truncates to `[1]`.
 - NaN and +/-Inf fail encode() with an error unless `nan_as_null=true`
   is given, which serializes them as `null` (the v8 behavior).
 If null-preserving round-trips matter, restructure the data (e.g. encode
 explicit sentinel values) rather than relying on this module.

 Decoded arrays carry a shared marker metatable so an empty `[]`
 re-encodes as `[]` instead of `{}`; use array() to mark empty tables
 you build yourself.

## Types

### Options

 Options accepted by encode(). All fields are optional.

```teal
local record Options
  --  Format across multiple lines for readability (default false).
  pretty: boolean
  --  Sort object keys for deterministic output (default true). Setting
  --  sorted=false can speed up serialization when ordering is irrelevant.
  sorted: boolean
  --  Indentation string used when pretty is true (default " ").
  indent: string
  --  Maximum serializer recursion depth (default 64, max 32767).
  max_depth: integer
  --  Encode NaN and +/-Inf as `null` (the v8 behavior) instead of
  --  failing with nil, error (default false).
  nan_as_null: boolean
end
```

### JsonModule

```teal
local record JsonModule
  decode: function(str: string): any, string
  decode_object: function(str: string): {string: any} | nil, string
  decode_array: function(str: string): {any} | nil, string
  encode: function(value: any, opts?: Options): string | nil, string
  array: function(t?: {any}): {any}
end
```

## Functions

### decode

```teal
function decode(str: string): any, string
```

 Decode a JSON string into a Lua value.
 Converts JSON strings, numbers, booleans, arrays, and objects into their Lua equivalents.
 A successful decode of JSON `null` returns `nil, nil` — success the
 house `if not v then` guard cannot tell from failure — so when the
 input may be `null`, test the ERROR, not the value. Better, when
 the top-level shape is known, use decode_object/decode_array: their
 nil always means failure. JSON `null` becomes Lua nil, so
 null-valued object keys vanish and arrays containing null decode
 with holes (see the module-level null policy above).

**Parameters:**

- `str` (string) - The JSON string to decode

**Returns:**

- any - The decoded Lua value (table, string, number, boolean, or nil — and nil for JSON null)
- string? - Error message if decoding failed

### encode

```teal
function encode(value: any, opts?: Options): string | nil, string
```

 Encode a Lua value as a JSON string.
 Converts Lua tables, strings, numbers, booleans, and nil into JSON format.
 NaN and +/-Inf fail with an error unless `nan_as_null=true` is
 given; nil-valued table entries are absent (see the module-level
 null policy above).

**Parameters:**

- `value` (any) - The Lua value to encode
- `opts` (Options?) - pretty, sorted, indent, max_depth, nan_as_null

**Returns:**

- string - | nil The JSON string representation
- string? - Error message if encoding failed

### decode_object

```teal
function decode_object(str: string): {string: any} | nil, string
```

 Decode a JSON object into a `{string: any}` map.
 Fails when the input is invalid JSON OR valid JSON whose top-level
 value is not an object, so the wrong-shape case is a real error
 instead of a downstream indexing surprise. Nested values are `any`;
 narrow uncertain shapes with `is`. Use decode() for the genuinely
 dynamic case.

**Parameters:**

- `str` (string) - The JSON string to decode

**Returns:**

- {string: - any} | nil The decoded object
- string? - Error message if decoding failed or the value is not an object

### decode_array

```teal
function decode_array(str: string): {any} | nil, string
```

 Decode a JSON array into a `{any}` list.
 Fails when the input is invalid JSON OR valid JSON whose top-level
 value is not an array. Elements are `any`; narrow uncertain shapes
 with `is`. Use decode() for the genuinely dynamic case.

**Parameters:**

- `str` (string) - The JSON string to decode

**Returns:**

- {any} - | nil The decoded array
- string? - Error message if decoding failed or the value is not an array

### array

```teal
function array(t?: {any}): {any}
```

 Mark a table as a JSON array so encode() serializes it as `[]` even
 when it is empty (an unmarked empty table encodes as `{}`). decode()
 applies the same marker to every array it decodes, which is how an
 empty `[]` round-trips. Passing no argument creates and returns a
 fresh marked table.

**Parameters:**

- `t` ({any}?) - The table to mark; a new empty table is created when omitted

**Returns:**

- {any} - The same table (or the new one), marked as an array
