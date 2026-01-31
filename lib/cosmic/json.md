# json

 JSON encoding and decoding utilities.
 Wraps cosmo.EncodeJson and cosmo.DecodeJson with convenient Teal-typed interface.

## Types

### JsonModule

```teal
local record JsonModule
  decode: function(str: string): any
  encode: function(value: any): string
end
```

## Functions

### decode

```teal
function decode(str: string): any
```

 Decode a JSON string into a Lua value.
 Converts JSON strings, numbers, booleans, arrays, and objects into their Lua equivalents.

**Parameters:**

- `str` (string) - The JSON string to decode

**Returns:**

- any - The decoded Lua value (table, string, number, boolean, or nil)

### encode

```teal
function encode(value: any): string
```

 Encode a Lua value as a JSON string.
 Converts Lua tables, strings, numbers, booleans, and nil into JSON format.

**Parameters:**

- `value` (any) - The Lua value to encode

**Returns:**

- string - The JSON string representation

## Examples

### decode

 Example_decode demonstrates JSON decoding

```teal
  local json = require("cosmic.json")
  local result = json.decode('{"a":1}')
  -- result is now a Lua table
  print(json.encode(result))
```

Output:
```
{"a":1}

```

### encode

 Example_encode demonstrates JSON encoding

```teal
  local json = require("cosmic.json")
  local result = json.encode({a = 1})
  print(result)
```

Output:
```
{"a":1}

```
