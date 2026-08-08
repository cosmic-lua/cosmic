# json

 JSON encoding and decoding utilities.
 Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.

 NULL POLICY: Lua tables cannot hold nil values, so by default JSON
 `null` decodes to nil and a null-valued object key simply vanishes —
 `{"a":null,"b":1}` re-encodes as `{"b":1}`. That is the one lossy
 case left, and both escape hatches are opt-in:
 - `decode(s, {null_value = json.null})` substitutes a sentinel for
   every `null`, so keys and array slots survive; `json.null`
   re-encodes as `null`, closing the round trip.
 - an array with holes is an ERROR on encode, never a silent
   truncation; `sparse_as_null = true` encodes each hole as `null`,
   which round-trips `[1,null,2]` losslessly with no sentinel at all.
 - NaN and +/-Inf fail encode() with an error unless `nan_as_null=true`
   is given, which serializes them as `null` (the v8 behavior).

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
  --  Encode array holes as `null` instead of failing with nil, error
  --  (default false). With it, an array that decoded from JSON
  --  containing `null` re-encodes losslessly.
  sparse_as_null: boolean
end
```

### DecodeOptions

 Options accepted by decode(). All fields are optional.

```teal
local record DecodeOptions
  --  A value to stand in for JSON `null`, so nulls survive the decode
  --  as something a Lua table can hold. Pass `json.null` to make the
  --  round trip lossless: it re-encodes as `null`. Without it, `null`
  --  decodes to nil (null-valued keys vanish, arrays get holes).
  null_value: any
end
```

### JsonModule

```teal
local record JsonModule
  --  The null sentinel: pass it as decode's `null_value` to keep JSON
  --  nulls, and it encodes back as `null`. An empty marked table, so
  --  `v == json.null` is the test.
  null: any
  decode: function(str: string, opts?: DecodeOptions): any, string
  decode_object: function(str: string): {string: any} | nil, string
  decode_array: function(str: string): {any} | nil, string
  encode: function(value: any, opts?: Options): string | nil, string
  array: function(t?: {any}): {any}
end
```

## Functions

### decode

```teal
function decode(str: string, opts?: DecodeOptions): any, string
```

 Decode a JSON string into a Lua value.
 Converts JSON strings, numbers, booleans, arrays, and objects into their Lua equivalents.
 A successful decode of JSON `null` returns `nil, nil` — success the
 house `if not v then` guard cannot tell from failure — so when the
 input may be `null`, test the ERROR, not the value. Better, when
 the top-level shape is known, use decode_object/decode_array: their
 nil always means failure. JSON `null` becomes Lua nil by default, so
 null-valued object keys vanish and arrays containing null decode
 with holes; `opts.null_value` (typically `json.null`) substitutes a
 sentinel instead, which also makes the value non-nil and so tells
 success from failure by itself.

**Parameters:**

- `str` (string) - The JSON string to decode
- `opts` (DecodeOptions?) - null_value: stand-in for JSON null

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
 given, and an array with holes fails unless `sparse_as_null=true`
 is; nil-valued table entries are absent (see the module-level null
 policy above).

**Parameters:**

- `value` (any) - The Lua value to encode
- `opts` (Options?) - pretty, sorted, indent, max_depth, nan_as_null, sparse_as_null

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
