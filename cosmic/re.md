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
  search: function(self: Regex, text: string, flags?: integer): string, {string}, string | nil
end
```

### Span

 A located match: absolute 1-based start/stop, the matched text,
 and its capture groups.

```teal
local record Span
  s: integer
  e: integer
  m: string
  caps: {string}
end
```

### ReModule

```teal
local record ReModule
  compile: function(pattern: string, flags?: integer): Regex | nil, string
  search: function(pattern: string, text: string, flags?: integer): string | nil, {string} | nil, string | nil
  test: function(pattern: string, text: string, flags?: integer): boolean, string
  findall: function(pattern: string, text: string, flags?: integer): {string} | nil, string
  split: function(pattern: string, text: string, flags?: integer): {string} | nil, string
  gsub: function(pattern: string, text: string, repl: Repl, flags?: integer): string | nil, string
  BASIC: integer
  ICASE: integer
  NEWLINE: integer
  NOSUB: integer
  NOTBOL: integer
  NOTEOL: integer
end
```

## Functions

### compile

```teal
function compile(pattern: string, flags?: integer): Regex | nil, string
```

 Compile a regular expression pattern.
 Compiled patterns can be reused for efficient O(n) matching.
 Uses POSIX extended syntax by default.

**Parameters:**

- `pattern` (string) - The regex pattern to compile
- `flags` (integer?) - Optional flags: BASIC, ICASE, NEWLINE, NOSUB

**Returns:**

- Regex? - The compiled regex, or nil on error
- string? - Error message if compilation failed

### search

```teal
function search(pattern: string, text: string, flags?: integer): string | nil, {string} | nil, string | nil
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
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB

**Returns:**

- string - | nil The matched substring, or nil on no match or error
- {string} - | nil Capture groups on match
- string - | nil Error message if compilation or the engine failed

### test

```teal
function test(pattern: string, text: string, flags?: integer): boolean, string
```

 Check if pattern matches anywhere in text.
 Convenience function that returns boolean instead of matched text.
 Named test (not match) to avoid confusion with Lua's string.match,
 which returns the matched text.

**Parameters:**

- `pattern` (string) - The regex pattern to match
- `text` (string) - The text to search in
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB

**Returns:**

- boolean - True if pattern matches, false otherwise
- string? - Error message if compilation or the engine failed

### findall

```teal
function findall(pattern: string, text: string, flags?: integer): {string} | nil, string
```

 Find every non-overlapping match of pattern in text, leftmost
 first. Patterns that can match the empty string are rejected.
 KNOWN LIMITATION with the NEWLINE flag: `^`/`$` anchors that only
 match via an embedded newline (not the true start/end of text) fail
 to be re-confirmed past the first line (see locate's doc), so
 findall("^foo", "foo\nfoo", re.NEWLINE) returns nil, "failed to
 locate match position for: foo" instead of {"foo", "foo"} -- use
 split("\n", text) plus a per-line match instead when this matters.

**Parameters:**

- `pattern` (string) - The regex pattern to match
- `text` (string) - The text to search in
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE

**Returns:**

- {string} - | nil The matched substrings (empty when none), or nil on error
- string? - Error message on a bad pattern or engine failure

### split

```teal
function split(pattern: string, text: string, flags?: integer): {string} | nil, string
```

 Split text around every match of pattern. Fields between matches
 are kept verbatim, including empty ones from adjacent or
 leading/trailing matches; text with no match yields one field.
 Patterns that can match the empty string are rejected.
 Shares findall's KNOWN LIMITATION with a NEWLINE-anchored `^`/`$`
 past the first line (see findall's doc).

**Parameters:**

- `pattern` (string) - The regex pattern to split on
- `text` (string) - The text to split
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE

**Returns:**

- {string} - | nil The fields, or nil on error
- string? - Error message on a bad pattern or engine failure

### gsub

```teal
function gsub(pattern: string, text: string, repl: Repl, flags?: integer): string | nil, string
```

 Replace every non-overlapping match of pattern in text.
 Patterns that can match the empty string are rejected.
 Shares findall's KNOWN LIMITATION with a NEWLINE-anchored `^`/`$`
 past the first line (see findall's doc).

**Parameters:**

- `pattern` (string) - The regex pattern to match
- `text` (string) - The text to operate on
- `repl` (Repl) - A literal replacement string, or function(match, caps)
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE

**Returns:**

- string - | nil The result, or nil on error
- string? - Error message on a bad pattern or engine failure
