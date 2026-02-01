# json

 JSON encoding and decoding utilities.
 Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.

## Types

### JsonModule

```teal
local record JsonModule
  decode: function(str: string): any, string
  encode: function(value: any): string, string
end
```

## Functions

### decode

```teal
function decode(str: string): any, string
```

 Decode a JSON string into a Lua value.
 Converts JSON strings, numbers, booleans, arrays, and objects into their Lua equivalents.

**Parameters:**

- `str` (string) - The JSON string to decode

**Returns:**

- any - The decoded Lua value (table, string, number, boolean, or nil)
- string? - Error message if decoding failed

### encode

```teal
function encode(value: any): string, string
```

 Encode a Lua value as a JSON string.
 Converts Lua tables, strings, numbers, booleans, and nil into JSON format.

**Parameters:**

- `value` (any) - The Lua value to encode

**Returns:**

- string - The JSON string representation
- string? - Error message if encoding failed
