# re

 Regular expression matching using POSIX extended regex syntax.
 Wraps cosmo.re for pattern compilation and searching.

 For best performance, compile patterns once and reuse them.
 The search() convenience function compiles on each call (O(2^n) complexity).

## Types

### Regex

 A compiled regular expression pattern.
 Use compile() to create, then call :search() for O(n) matching.

```teal
local record Regex
  --  Search for pattern match in text.
  --  On a match, returns the matched substring plus a table of the
  --  parenthesized capture groups (an empty table when the pattern has
  --  no groups, "" for groups that did not participate). A no-match is
  --  not an error: it returns a single bare nil. A genuine engine
  --  failure (e.g. out of memory) returns nil, err — the error string
  --  arrives in the second position, mirroring the cosmo.re binding.
  search: function(self: Regex, text: string, flags?: number): string, {string}, string | nil
end
```

### ReModule

```teal
local record ReModule
  compile: function(pattern: string, flags?: number): Regex | nil, string
  search: function(pattern: string, text: string, flags?: number): string | nil, {string} | nil, string | nil
  match: function(pattern: string, text: string, flags?: number): boolean, string
  BASIC: number
  ICASE: number
  NEWLINE: number
  NOSUB: number
  NOTBOL: number
  NOTEOL: number
end
```

## Functions

### compile

```teal
function compile(pattern: string, flags?: number): Regex | nil, string
```

 Compile a regular expression pattern.
 Compiled patterns can be reused for efficient O(n) matching.
 Uses POSIX extended syntax by default.

**Parameters:**

- `pattern` (string) - The regex pattern to compile
- `flags` (number?) - Optional flags: BASIC, ICASE, NEWLINE, NOSUB

**Returns:**

- Regex? - The compiled regex, or nil on error
- string? - Error message if compilation failed

### search

```teal
function search(pattern: string, text: string, flags?: number): string | nil, {string} | nil, string | nil
```

 Search for pattern match in text (convenience function).
 Compiles pattern on each call - use compile() for repeated searches.
 Uses POSIX extended syntax by default.
 On a match, returns the matched substring plus a table of the
 parenthesized capture groups (an empty table when the pattern has no
 groups, "" for groups that did not participate). A no-match returns
 nil with no error; a bad pattern or an engine failure returns
 nil, nil, err.

**Parameters:**

- `pattern` (string) - The regex pattern to search for
- `text` (string) - The text to search in
- `flags` (number?) - Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB

**Returns:**

- string - | nil The matched substring, or nil on no match or error
- {string} - | nil Capture groups on match
- string - | nil Error message if compilation or the engine failed

### match

```teal
function match(pattern: string, text: string, flags?: number): boolean, string
```

 Check if pattern matches anywhere in text.
 Convenience function that returns boolean instead of matched text.

**Parameters:**

- `pattern` (string) - The regex pattern to match
- `text` (string) - The text to search in
- `flags` (number?) - Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB

**Returns:**

- boolean - True if pattern matches, false otherwise
- string? - Error message if compilation or the engine failed
