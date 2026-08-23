# string

 String utilities.
 Common string manipulation functions for trimming, splitting, searching,
 padding, and quoting. All functions are infallible and treat their
 arguments as plain text (no Lua patterns). For pattern-based search
 and splitting see cosmic.re; for approximate (edit-distance)
 matching see cosmic.fuzzy.

 Example usage:
   local str = require("cosmic.string")
   str.capitalize("hello")           -- "Hello"
   str.trim("  hello  ")             -- "hello"
   str.split("a,b,c", ",")           -- {"a", "b", "c"}
   str.starts_with("hello", "he")    -- true
   str.contains("hello", "ell")      -- true
   str.replace("a-b-c", "-", "+")    -- "a+b+c"
   str.fields("  a  b  ")            -- {"a", "b"}

## Types

### StringModule

```teal
local record StringModule
  capitalize: function(s: string): string
  trim: function(s: string): string
  trim_left: function(s: string): string
  trim_right: function(s: string): string
  split: function(s: string, sep: string): {string}
  starts_with: function(s: string, prefix: string): boolean
  ends_with: function(s: string, suffix: string): boolean
  contains: function(s: string, sub: string): boolean
  count: function(s: string, sub: string): integer
  replace: function(s: string, old: string, new: string, max?: integer): string
  lines: function(s: string): {string}
  partition: function(s: string, sep: string): string, string, string
  fields: function(s: string): {string}
  pad_left: function(s: string, width: integer, pad?: string): string
  pad_right: function(s: string, width: integer, pad?: string): string
  dedent: function(s: string): string
  indent: function(s: string, prefix: string): string
  truncate: function(s: string, width: integer, suffix?: string): string
  shell_quote: function(s: string): string
  to_integer: function(s: string, base?: integer): integer | nil, string
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

### trim_left

```teal
function trim_left(s: string): string
```

 Trim whitespace from the left side of a string.

**Parameters:**

- `s` (string) - The string to trim

**Returns:**

- string - The left-trimmed string

### trim_right

```teal
function trim_right(s: string): string
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
 The empty string yields one empty field, {""} — the same answer
 re.split gives, so the two splits agree on the empty subject.

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

### contains

```teal
function contains(s: string, sub: string): boolean
```

 Check if a string contains a substring.
 Plain-text search; the substring is not a Lua pattern.
 The empty substring is contained in every string.

**Parameters:**

- `s` (string) - The string to search
- `sub` (string) - The substring to look for

**Returns:**

- boolean - True if s contains sub

### count

```teal
function count(s: string, sub: string): integer
```

 Count non-overlapping occurrences of a substring.
 Plain-text search; the substring is not a Lua pattern.
 The empty substring matches before every character and at the end,
 so it counts #s + 1 occurrences — agreeing with contains, which
 says the empty substring is contained in every string.

**Parameters:**

- `s` (string) - The string to search
- `sub` (string) - The substring to count

**Returns:**

- integer - Number of non-overlapping occurrences

### replace

```teal
function replace(s: string, old: string, new: string, max?: integer): string
```

 Replace occurrences of a substring with plain text.
 Both old and new are treated literally (no Lua patterns, unlike
 string.gsub). Replaces all occurrences unless max is given.
 An empty old string matches before every character and at the end,
 so new is inserted at each of the #s + 1 boundaries — the same
 positions count counts, and what Python and Go do.

**Parameters:**

- `s` (string) - The string to operate on
- `old` (string) - The substring to replace
- `new` (string) - The replacement text
- `max` (integer?) - Maximum number of replacements (default unlimited)

**Returns:**

- string - The string with replacements applied

### lines

```teal
function lines(s: string): {string}
```

 Split a string into lines.
 Lines are separated by "\n"; a trailing "\r" on each line (from
 "\r\n" endings) is removed. A final trailing newline does not
 produce an extra empty line. The empty string yields no lines.

**Parameters:**

- `s` (string) - The string to split

**Returns:**

- {string} - Array of lines without their line endings

### partition

```teal
function partition(s: string, sep: string): string, string, string
```

 Split the string at the first occurrence of a separator.
 Plain-text search. If the separator is not found (or is empty),
 returns the whole string followed by two empty strings.

**Parameters:**

- `s` (string) - The string to partition
- `sep` (string) - The separator to split at

**Returns:**

- string - The part before the separator (or all of s)
- string - The separator if found, otherwise ""
- string - The part after the separator, otherwise ""

### fields

```teal
function fields(s: string): {string}
```

 Split a string around runs of whitespace.
 Leading and trailing whitespace is ignored; the result contains
 no empty strings. A blank or empty string yields no fields.

**Parameters:**

- `s` (string) - The string to split

**Returns:**

- {string} - Array of whitespace-separated fields

### pad_left

```teal
function pad_left(s: string, width: integer, pad?: string): string
```

 Pad a string on the left to a minimum width.
 The pad string (default " ") is repeated as needed and truncated
 so the result is exactly width characters. Strings already at
 least width long are returned unchanged, as is any input when
 the pad string is empty.

**Parameters:**

- `s` (string) - The string to pad
- `width` (integer) - Minimum width of the result
- `pad` (string?) - Padding text (default " ")

**Returns:**

- string - The padded string

### pad_right

```teal
function pad_right(s: string, width: integer, pad?: string): string
```

 Pad a string on the right to a minimum width.
 The pad string (default " ") is repeated as needed and truncated
 so the result is exactly width characters. Strings already at
 least width long are returned unchanged, as is any input when
 the pad string is empty.

**Parameters:**

- `s` (string) - The string to pad
- `width` (integer) - Minimum width of the result
- `pad` (string?) - Padding text (default " ")

**Returns:**

- string - The padded string

### dedent

```teal
function dedent(s: string): string
```

 Remove common leading whitespace from all lines.
 The margin is the longest whitespace prefix shared by every
 non-blank line; blank (empty or whitespace-only) lines are ignored
 when computing it and have the margin stripped where present.
 Line endings are preserved.

**Parameters:**

- `s` (string) - The string to dedent

**Returns:**

- string - The dedented string

### indent

```teal
function indent(s: string, prefix: string): string
```

 Prefix each non-blank line of a string.
 Blank (empty or whitespace-only) lines are left unchanged.
 Line endings are preserved.

**Parameters:**

- `s` (string) - The string to indent
- `prefix` (string) - The prefix to add to each non-blank line

**Returns:**

- string - The indented string

### truncate

```teal
function truncate(s: string, width: integer, suffix?: string): string
```

 Truncate a string to a maximum width, appending a suffix when cut.
 Widths count bytes, not display characters. Strings at most width
 long are returned unchanged. Otherwise the result is exactly width
 bytes ending in the suffix (default "..."); if width is too small
 to fit the suffix, the string is hard-cut to width without it.

**Parameters:**

- `s` (string) - The string to truncate
- `width` (integer) - Maximum width of the result
- `suffix` (string?) - Marker appended when truncated (default "...")

**Returns:**

- string - The truncated string

### shell_quote

```teal
function shell_quote(s: string): string
```

 Quote a string for use as a single word in a POSIX shell.
 Safe strings (alphanumerics and ._-/=:,+@%) are returned unchanged;
 everything else is wrapped in single quotes with embedded single
 quotes escaped. The empty string quotes to ''.

**Parameters:**

- `s` (string) - The string to quote

**Returns:**

- string - The shell-quoted string

### to_integer

```teal
function to_integer(s: string, base?: integer): integer | nil, string
```

 Parse s as an integer. tonumber's grammar (optional sign,
 whitespace tolerated; base 2-36, default 10), judged on the VALUE
 rather than the spelling: "1e3" is 1000 and "0x1F" is 31, while
 "7.5" is a refusal rather than a truncation. A `0x` prefix is a
 default-base spelling only — tonumber rejects it once a base is
 given.

**Parameters:**

- `s` (string) - The text to parse
- `base` (integer?) - The base, default 10

**Returns:**

- integer - | nil The parsed integer
- string - Error message when s is not an integer in base
