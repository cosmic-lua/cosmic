# url

 URL encoding and decoding utilities.
 Wraps cosmo.EscapeParam for encoding; manual decode for percent-encoded strings.

## Types

### UrlModule

```teal
local record UrlModule
  encode: function(str: string): string
  decode: function(str: string): string, string
end
```

## Functions

### encode

```teal
function encode(str: string): string
```

 Encode a string for use in URL query parameters.
 Spaces become %20, special characters become %XX.

**Parameters:**

- `str` (string) - The string to encode

**Returns:**

- string - The percent-encoded string

### decode

```teal
function decode(str: string): string, string
```

 Decode a percent-encoded string.
 Handles %XX sequences and + as space.

**Parameters:**

- `str` (string) - The percent-encoded string

**Returns:**

- string - The decoded string, or nil on error
- string? - Error message if decoding failed
