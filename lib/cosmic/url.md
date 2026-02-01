# url

 URL encoding, decoding, and query string parsing utilities.
 Wraps cosmo.EscapeParam for encoding and cosmo.ParseParams for query string parsing.

## Types

### Url

 Parsed URL components.

```teal
local record Url
  scheme: string
  user: string
  pass: string
  host: string
  port: integer
  path: string
  query: string
  fragment: string
end
```

### UrlModule

```teal
local record UrlModule
  Url: Url
  encode: function(str: string): string
  decode: function(str: string): string, string
  parse: function(query: string): {string:string}
  parse_url: function(url: string): Url
  parse_host: function(hostport: string): string, integer
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

### parse

```teal
function parse(query: string): {string:string}
```

 Parse a query string into key-value pairs.
 Handles URL-encoded keys and values.

**Parameters:**

- `query` (string) - The query string (without leading ?)

**Returns:**

- {string:string} - Table of key-value pairs

### parse_url

```teal
function parse_url(url: string): Url
```

 Parse a URL into its components.

**Parameters:**

- `url` (string) - The URL to parse

**Returns:**

- Url - The parsed URL components

### parse_host

```teal
function parse_host(hostport: string): string, integer
```

 Parse a host:port string into its components.

**Parameters:**

- `hostport` (string) - The host:port string (e.g., "example.com:8080")

**Returns:**

- string - The host
- integer? - The port, or nil if not specified
