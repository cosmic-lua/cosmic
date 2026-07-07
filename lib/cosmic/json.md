# json

 JSON encoding and decoding utilities.
 Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.

 NULL POLICY (lossy — read before round-tripping):
 Lua tables cannot hold nil values, so JSON `null` does not survive a
 decode/encode round-trip:
 - `{"a":null,"b":1}` decodes with `a` absent and re-encodes as `{"b":1}`.
 - `[1,null,2]` decodes with a hole at index 2; re-encoding sees a table
   of length 1 and truncates to `[1]`.
 - NaN encodes as `null`; +/-Inf encodes as the out-of-range literal
   `1e5000`/`-1e5000`, which this module decodes back to +/-Inf but
   stricter JSON parsers may reject.
 If null-preserving round-trips matter, restructure the data (e.g. encode
 explicit sentinel values) rather than relying on this module.

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
end
```

### JsonModule

```teal
local record JsonModule
  decode: function(str: string): any, string
  encode: function(value: any, options?: EncodeOptions): string | nil, string
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
 NaN encodes as `null`, +/-Inf as `1e5000`/`-1e5000`; nil-valued table
 entries are absent (see the module-level null policy above).

**Parameters:**

- `value` (any) - The Lua value to encode
- `options` (EncodeOptions?) - pretty, sorted, indent, maxdepth

**Returns:**

- string - | nil The JSON string representation
- string? - Error message if encoding failed
