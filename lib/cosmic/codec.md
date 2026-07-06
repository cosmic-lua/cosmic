# codec

 Encoding and decoding utilities for various formats.
 Provides hex and Lua serialization codecs with consistent error handling.

## Types

### CodecModule

```teal
local record CodecModule
  encode_hex: function(data: string): string
  decode_hex: function(hex: string): string | nil, string
  encode_lua: function(value: any, opts?: {string: any}): string
  decode_lua_unsafe: function(code: string): any | nil, string
  encode_base64: function(data: string): string
  decode_base64: function(str: string): string | nil, string
  encode_base32: function(data: string): string
  decode_base32: function(str: string): string | nil, string
  encode_latin1: function(str: string): string | nil, string
  decode_latin1: function(data: string): string
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
function decode_hex(hex: string): string | nil, string
```

 Decode a hexadecimal string to binary data.
 Accepts both uppercase and lowercase hex characters.

**Parameters:**

- `hex` (string) - The hexadecimal string to decode

**Returns:**

- string - | nil The decoded binary data, or nil on error
- string? - Error message if decoding failed

### encode_lua

```teal
function encode_lua(value: any, opts?: {string: any}): string
```

 Encode a Lua value as Lua source code.
 The output can be loaded with decode_lua to reconstruct the value.

**Parameters:**

- `value` (any) - The Lua value to encode (table, string, number, boolean, or nil)
- `opts` ({string:any}?) - Optional encoding options

**Returns:**

- string - The Lua source code representation

### decode_lua_unsafe

```teal
function decode_lua_unsafe(code: string): any | nil, string
```

 Decode Lua source code to a value with a restricted environment.
 Only loads the code in text mode with an empty environment table,
 preventing access to globals like os, io, and require.
 Table constructors and literal values still work.
 WARNING: This still executes Lua code. Only use with trusted input.

**Parameters:**

- `code` (string) - The Lua source code to decode

**Returns:**

- any - | nil The decoded Lua value, or nil on error
- string? - Error message if decoding failed

### encode_base64

```teal
function encode_base64(data: string): string
```

 Encode binary data as base64.
 Uses standard base64 encoding (RFC 4648).

**Parameters:**

- `data` (string) - The binary data to encode

**Returns:**

- string - The base64 encoded string

### decode_base64

```teal
function decode_base64(str: string): string | nil, string
```

 Decode a base64 string to binary data.
 Accepts standard base64 encoding with or without padding.

**Parameters:**

- `str` (string) - The base64 string to decode

**Returns:**

- string - | nil The decoded binary data, or nil on error
- string? - Error message if decoding failed

### encode_base32

```teal
function encode_base32(data: string): string
```

 Encode binary data as base32.
 Uses lowercase base32 alphabet (0-9a-v excluding i, l, o, u).

**Parameters:**

- `data` (string) - The binary data to encode

**Returns:**

- string - The base32 encoded string

### decode_base32

```teal
function decode_base32(str: string): string | nil, string
```

 Decode a base32 string to binary data.
 Uses lowercase base32 alphabet (0-9a-z excluding i, l, o, u).

**Parameters:**

- `str` (string) - The base32 string to decode

**Returns:**

- string - | nil The decoded binary data, or nil on error
- string? - Error message if decoding failed

### encode_latin1

```teal
function encode_latin1(str: string): string | nil, string
```

 Encode a UTF-8 string as Latin-1 (ISO-8859-1).
 Characters outside the Latin-1 range will cause an error.

**Parameters:**

- `str` (string) - The UTF-8 string to encode

**Returns:**

- string - | nil The Latin-1 encoded bytes, or nil on error
- string? - Error message if encoding failed

### decode_latin1

```teal
function decode_latin1(data: string): string
```

 Decode Latin-1 (ISO-8859-1) bytes to a UTF-8 string.

**Parameters:**

- `data` (string) - The Latin-1 bytes to decode

**Returns:**

- string - The UTF-8 string
