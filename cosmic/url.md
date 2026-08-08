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

### HostPort

 A parsed host:port pair; port is nil when the input carried none.
 A record rather than (host, port, err) returns: the error is in
 slot 2, where check.must and `local h, err = ...` can see it.

```teal
local record HostPort
  host: string
  port: integer
end
```

### UrlModule

```teal
local record UrlModule
  escape_param: function(str: string): string
  unescape_param: function(str: string): string | nil, string
  unescape: function(str: string): string | nil, string
  parse: function(url: string): Url | nil, string
  format: function(u: Url): string
  parse_query: function(query: string): {string: {string}}
  format_query: function(params: {string: {string} | string}): string
  parse_host: function(hostport: string): HostPort | nil, string
  escape_host: function(str: string): string
  escape_path: function(str: string): string
  escape_segment: function(str: string): string
  escape_fragment: function(str: string): string
  format_host: function(hp: HostPort): string
end
```

## Functions

### escape_param

```teal
function escape_param(str: string): string
```

 Percent-encode a string for use as a URL query parameter value
 (escape/unescape is the syntax-safety verb pair, D20).
 Spaces become %20, specials become %XX.
 Use this when building query strings manually:
 `"q=" .. url.escape_param(term)` — or format_query() for whole maps.
 For other URL components, use the specific escape functions:
 - `escape_path()`: encode a URL path (preserves slashes)
 - `escape_segment()`: encode a single path segment (escapes slashes)
 - `escape_host()`: encode a hostname
 - `escape_fragment()`: encode a URL fragment
 and `unescape()` as their shared inverse.

**Parameters:**

- `str` (string) - The string to encode

**Returns:**

- string - The percent-encoded string

### unescape_param

```teal
function unescape_param(str: string): string | nil, string
```

 Decode a percent-encoded query parameter.
 Handles %XX sequences and + as space — the param rules.
 For other components (paths, hosts, fragments), where + is a
 literal plus, use unescape().

**Parameters:**

- `str` (string) - The percent-encoded string

**Returns:**

- string - | nil The decoded string, or nil on error
- string? - Error message if decoding failed

### unescape

```teal
function unescape(str: string): string | nil, string
```

 Decode %XX sequences with NO plus-as-space conversion: the shared
 inverse of escape_path/escape_segment/escape_host/escape_fragment,
 where `+` is an ordinary character.

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

### format_query

```teal
function format_query(params: {string: {string} | string}): string
```

 Format a query map back into a query string: the inverse of
 parse_query. Keys are sorted (deterministic output) and each of a
 key's values becomes its own k=v pair, in order; both halves are
 percent-encoded with the param rules (spaces become %20). A value
 may be a plain string as well as a list — so a parsed query feeds
 back in unchanged, and the common one-value-per-key map (e.g.
 fetch's query option) needs no wrapping.

**Parameters:**

- `params` ({string:{string}) - | string} Keys with one value or all values in order

**Returns:**

- string - The query string (no leading ?)

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
function parse_host(hostport: string): HostPort | nil, string
```

 Parse a host:port string into its components.
 IPv6 hosts must be bracketed ("[::1]" or "[::1]:8080"); a port, when
 present, must be an integer in 1..65535.

**Parameters:**

- `hostport` (string) - The host:port string (e.g., "example.com:8080")

**Returns:**

- HostPort - | nil The parsed host (port nil when absent)
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

### format_host

```teal
function format_host(hp: HostPort): string
```

 Format a HostPort back into a host:port string: the inverse of
 parse_host. An IPv6 host (any host carrying a colon) is bracketed,
 which is exactly the rule parse_host knows and callers were left to
 rediscover; a nil port yields the bare host.

**Parameters:**

- `hp` (HostPort) - The host (port optional)

**Returns:**

- string - The host:port string
