# url

 URL encoding, decoding, parsing, formatting, and escaping utilities.

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
  decode: function(str: string): string | nil, string
  parse: function(url: string): Url | nil, string
  format: function(u: Url): string
  parse_query: function(query: string): {string: {string}}
  parse_host: function(hostport: string): string | nil, integer, string
  escape_host: function(str: string): string
  escape_path: function(str: string): string
  escape_segment: function(str: string): string
  escape_fragment: function(str: string): string
  escape_literal: function(str: string): string
  escape_user: function(str: string): string
  escape_pass: function(str: string): string
  escape_ip: function(str: string): string
end
```

## Functions

### encode

```teal
function encode(str: string): string
```

 Percent-encode a string for use as a URL query parameter value.
 Use this when building query strings manually: `"q=" .. url.encode(search_term)`.
 Spaces become %20, special characters become %XX hex sequences.
 For other URL components, use the specific escape functions:
 - `escape_path()`: encode a URL path (preserves slashes)
 - `escape_segment()`: encode a single path segment (escapes slashes)
 - `escape_host()`: encode a hostname
 - `escape_fragment()`: encode a URL fragment

**Parameters:**

- `str` (string) - The string to encode

**Returns:**

- string - The percent-encoded string

### decode

```teal
function decode(str: string): string | nil, string
```

 Decode a percent-encoded string.
 Handles %XX sequences and + as space.

**Parameters:**

- `str` (string) - The percent-encoded string

**Returns:**

- string - | nil The decoded string, or nil on error
- string? - Error message if decoding failed

### parse_query

```teal
function parse_query(query: string): {string: {string}}
```

 Parse a query string into its key-value pairs, keeping every value.
 Keys and values are percent-decoded; a repeated key's values arrive
 in order. A flag-style key with no `=` yields one empty-string value.

**Parameters:**

- `query` (string) - The query string (without leading ?)

**Returns:**

- {string:{string}} - Decoded keys, each with all its values in order

### parse

```teal
function parse(url: string): Url | nil, string
```

 Parse a URL into its components.
 The query field is re-encoded so delimiters inside values survive
 (e.g. `?a=x%26y` stays one parameter); decode it with `parse_query`.

**Parameters:**

- `url` (string) - The URL to parse

**Returns:**

- Url - | nil The parsed URL components, or nil on error
- string? - Error message if parsing failed

### format

```teal
function format(u: Url): string
```

 Format a Url back into a string — the inverse of `parse`.
 Each component is escaped for its position, so a parse/format round
 trip yields an equivalent URL.

**Parameters:**

- `u` (Url) - The URL components to format

**Returns:**

- string - The formatted URL

### parse_host

```teal
function parse_host(hostport: string): string | nil, integer, string
```

 Parse a host:port string into its components.
 IPv6 hosts must be bracketed ("[::1]" or "[::1]:8080"); a port, when
 present, must be an integer in 1..65535.

**Parameters:**

- `hostport` (string) - The host:port string (e.g., "example.com:8080")

**Returns:**

- string - | nil The host, or nil on error
- integer? - The port, or nil if not specified
- string? - Error message if parsing failed

### escape_host

```teal
function escape_host(str: string): string
```

 Escape a hostname for use in a URL.
 Handles internationalized domain names and special characters.

**Parameters:**

- `str` (string) - The hostname to escape

**Returns:**

- string - The escaped hostname

### escape_path

```teal
function escape_path(str: string): string
```

 Escape a URL path, preserving forward slashes.
 Use for paths like `/users/john doe` -> `/users/john%20doe`.
 To escape a single segment (including slashes), use `escape_segment()`.

**Parameters:**

- `str` (string) - The path to escape

**Returns:**

- string - The escaped path

### escape_segment

```teal
function escape_segment(str: string): string
```

 Escape a single URL path segment, including forward slashes.
 Use when the segment itself may contain slashes: `file/name.txt` -> `file%2Fname.txt`.
 For full paths where slashes should be preserved, use `escape_path()`.

**Parameters:**

- `str` (string) - The path segment to escape

**Returns:**

- string - The escaped segment

### escape_fragment

```teal
function escape_fragment(str: string): string
```

 Escape a URL fragment (the part after #).

**Parameters:**

- `str` (string) - The fragment to escape

**Returns:**

- string - The escaped fragment

### escape_literal

```teal
function escape_literal(str: string): string
```

 Escape a string for literal URL matching.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- string - The escaped string

### escape_user

```teal
function escape_user(str: string): string
```

 Escape a username for use in a URL.

**Parameters:**

- `str` (string) - The username to escape

**Returns:**

- string - The escaped username

### escape_pass

```teal
function escape_pass(str: string): string
```

 Escape a password for use in a URL.

**Parameters:**

- `str` (string) - The password to escape

**Returns:**

- string - The escaped password

### escape_ip

```teal
function escape_ip(str: string): string
```

 Escape an IP address for use in a URL.

**Parameters:**

- `str` (string) - The IP address to escape

**Returns:**

- string - The escaped IP address
