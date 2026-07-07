# string

 String utilities.
 Common string manipulation functions for trimming, splitting, and case conversion.

 Example usage:
   local str = require("cosmic.string")
   str.capitalize("hello")           -- "Hello"
   str.trim("  hello  ")             -- "hello"
   str.split("a,b,c", ",")           -- {"a", "b", "c"}
   str.starts_with("hello", "he")    -- true

## Types

### StringModule

```teal
local record StringModule
  capitalize: function(s: string): string
  trim: function(s: string): string
  ltrim: function(s: string): string
  rtrim: function(s: string): string
  split: function(s: string, sep: string): {string}
  starts_with: function(s: string, prefix: string): boolean
  ends_with: function(s: string, suffix: string): boolean
end
```

## Functions

### capitalize

```teal
function capitalize(s: string): string
```

 Capitalize the first character of a string.
 Converts the first character to uppercase, leaving the rest unchanged.

**Parameters:**

- `s` (string) - The string to capitalize

**Returns:**

- string - The string with first character capitalized

### trim

```teal
function trim(s: string): string
```

 Trim whitespace from both ends of a string.

**Parameters:**

- `s` (string) - The string to trim

**Returns:**

- string - The trimmed string

### ltrim

```teal
function ltrim(s: string): string
```

 Trim whitespace from the left side of a string.

**Parameters:**

- `s` (string) - The string to trim

**Returns:**

- string - The left-trimmed string

### rtrim

```teal
function rtrim(s: string): string
```

 Trim whitespace from the right side of a string.

**Parameters:**

- `s` (string) - The string to trim

**Returns:**

- string - The right-trimmed string

### split

```teal
function split(s: string, sep: string): {string}
```

 Split a string by a separator.
 If separator is empty string, splits into individual characters.
 Trailing empty fields (from a trailing separator) are preserved.

**Parameters:**

- `s` (string) - The string to split
- `sep` (string) - The separator to split on

**Returns:**

- {string} - Array of substrings

### starts_with

```teal
function starts_with(s: string, prefix: string): boolean
```

 Check if a string starts with a prefix.

**Parameters:**

- `s` (string) - The string to check
- `prefix` (string) - The prefix to look for

**Returns:**

- boolean - True if s starts with prefix

### ends_with

```teal
function ends_with(s: string, suffix: string): boolean
```

 Check if a string ends with a suffix.

**Parameters:**

- `s` (string) - The string to check
- `suffix` (string) - The suffix to look for

**Returns:**

- boolean - True if s ends with suffix
