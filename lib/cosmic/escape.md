# escape

 HTML and URL component escaping utilities.
 Provides functions for safely escaping strings for use in HTML and various URL components.

## Types

### EscapeModule

```teal
local record EscapeModule
  html: function(str: string): string
  host: function(str: string): string
  path: function(str: string): string
  segment: function(str: string): string
  fragment: function(str: string): string
  literal: function(str: string): string
  user: function(str: string): string
  pass: function(str: string): string
  ip: function(str: string): string
end
```

## Functions

### html

```teal
function html(str: string): string
```

 Escape HTML special characters.
 Converts <, >, &, ", and ' to their HTML entity equivalents.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- string - The HTML-safe string

### host

```teal
function host(str: string): string
```

 Escape a hostname for use in a URL.

**Parameters:**

- `str` (string) - The hostname to escape

**Returns:**

- string - The escaped hostname

### path

```teal
function path(str: string): string
```

 Escape a URL path.
 Escapes characters that are not allowed in URL paths.

**Parameters:**

- `str` (string) - The path to escape

**Returns:**

- string - The escaped path

### segment

```teal
function segment(str: string): string
```

 Escape a single URL path segment.
 More aggressive than path() - also escapes forward slashes.

**Parameters:**

- `str` (string) - The path segment to escape

**Returns:**

- string - The escaped segment

### fragment

```teal
function fragment(str: string): string
```

 Escape a URL fragment.

**Parameters:**

- `str` (string) - The fragment to escape

**Returns:**

- string - The escaped fragment

### literal

```teal
function literal(str: string): string
```

 Escape a string for literal URL matching.

**Parameters:**

- `str` (string) - The string to escape

**Returns:**

- string - The escaped string

### user

```teal
function user(str: string): string
```

 Escape a username for use in a URL.

**Parameters:**

- `str` (string) - The username to escape

**Returns:**

- string - The escaped username

### pass

```teal
function pass(str: string): string
```

 Escape a password for use in a URL.

**Parameters:**

- `str` (string) - The password to escape

**Returns:**

- string - The escaped password

### ip

```teal
function ip(str: string): string
```

 Escape an IP address for use in a URL.

**Parameters:**

- `str` (string) - The IP address to escape

**Returns:**

- string - The escaped IP address
