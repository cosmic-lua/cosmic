# json

 JSON encoding and decoding utilities.
 Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.

 NULL POLICY (lossy — read before round-tripping):
 Lua tables cannot hold nil values, so JSON `null` does not survive a
 decode/encode round-trip:
 - `{"a":null,"b":1}` decodes with `a` absent and re-encodes as `{"b":1}`.
 - `[1,null,2]` decodes with a hole at index 2; re-encoding sees a table
   of length 1 and truncates to `[1]`.
 - NaN and +/-Inf fail encode() with an error unless `nan="null"` is
   given, which serializes them as `null` (the v8 behavior).
 If null-preserving round-trips matter, restructure the data (e.g. encode
 explicit sentinel values) rather than relying on this module.

 Decoded arrays carry a shared marker metatable so an empty `[]`
 re-encodes as `[]` instead of `{}`; use array() to mark empty tables
 you build yourself.

## Types

### EncodeOptions

 Options accepted by encode(). All fields are optional.

```teal
local record EncodeOptions
  --  Format across multiple lines for readability (default false).
  pretty: boolean
  --  Sort object keys for deterministic output (default true). Setting
  --  sorted=false can speed up serialization when ordering is irrelevant.
  sorted: boolean
  --  Indentation string used when pretty is true (default " ").
  indent: string
  --  Maximum serializer recursion depth (default 64, max 32767).
  maxdepth: number
  --  The only accepted value is "null": encode NaN and Infinity as
  --  `null` (the v8 behavior) instead of failing with nil, error.
  nan: string
end
```

### JsonModule

```teal
local record JsonModule
  decode: function(str: string): any, string
  encode: function(value: any, options?: EncodeOptions): string | nil, string
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
 JSON `null` becomes nil, so null-valued object keys vanish and arrays
 containing null are truncated at the first null when re-encoded (see the
 module-level null policy above).

**Parameters:**

- `str` (string) - The JSON string to decode

**Returns:**

- any - The decoded Lua value (table, string, number, boolean, or nil)
- string? - Error message if decoding failed

### encode

```teal
function encode(value: any, options?: EncodeOptions): string | nil, string
```

 Encode a Lua value as a JSON string.
 Converts Lua tables, strings, numbers, booleans, and nil into JSON format.
 NaN and +/-Inf fail with an error unless `nan="null"` is given;
 nil-valued table entries are absent (see the module-level null policy
 above).

**Parameters:**

- `value` (any) - The Lua value to encode
- `options` (EncodeOptions?) - pretty, sorted, indent, maxdepth, nan

**Returns:**

- string - | nil The JSON string representation
- string? - Error message if encoding failed

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
