# codec

 Encoding and decoding utilities for various formats.
 Provides hex and Lua serialization codecs with consistent error handling.

## Types

### CodecModule

```teal
local record CodecModule
  encode_hex: function(data: string): string
  decode_hex: function(hex: string): string, string
  encode_lua: function(value: any, opts?: {string:any}): string
  decode_lua: function(code: string): any, string
end
```

## Functions

### encode_hex

```teal
function encode_hex(data: string): string
```

 Encode a string as hexadecimal.
 Each byte becomes two lowercase hex characters.

**Parameters:**

- `data` (string) - The binary data to encode

**Returns:**

- string - The hexadecimal representation

### decode_hex

```teal
function decode_hex(hex: string): string, string
```

 Decode a hexadecimal string to binary data.
 Accepts both uppercase and lowercase hex characters.

**Parameters:**

- `hex` (string) - The hexadecimal string to decode

**Returns:**

- string - The decoded binary data, or nil on error
- string? - Error message if decoding failed

### encode_lua

```teal
function encode_lua(value: any, opts?: {string:any}): string
```

 Encode a Lua value as Lua source code.
 The output can be loaded with decode_lua to reconstruct the value.

**Parameters:**

- `value` (any) - The Lua value to encode (table, string, number, boolean, or nil)
- `opts` ({string:any}?) - Optional encoding options

**Returns:**

- string - The Lua source code representation

### decode_lua

```teal
function decode_lua(code: string): any, string
```

 Decode Lua source code to a value.
 Only loads the code, does not execute arbitrary functions.
 WARNING: This executes Lua code. Only use with trusted input.

**Parameters:**

- `code` (string) - The Lua source code to decode

**Returns:**

- any - The decoded Lua value, or nil on error
- string? - Error message if decoding failed
