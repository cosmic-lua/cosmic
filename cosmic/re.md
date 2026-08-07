# re

 Regular expression matching using POSIX extended regex syntax.
 Wraps cosmo.re for pattern compilation and matching. Module-level
 functions are SUBJECT-FIRST D20: match(text, pattern), like
 string.match. The compiled Regex keeps the binding's own :search
 method name — a userdata metatable is the C layer's to name.

 For best performance, compile patterns once and reuse them.
 The match() convenience function compiles on each call.

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
  search: function(self: Regex, text: string, flags?: integer): string | nil, {string} | nil, string | nil
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
  match: function(text: string, pattern: string, flags?: integer): string | nil, {string} | nil, string | nil
  test: function(text: string, pattern: string, flags?: integer): boolean, string
  find: function(text: string, pattern: string, flags?: integer): Span | nil, string
  find_all: function(text: string, pattern: string, flags?: integer): {Span} | nil, string
  gmatch: function(text: string, pattern: string, flags?: integer): MatchIterator, string
  split: function(text: string, pattern: string, flags?: integer): {string} | nil, string
  gsub: function(text: string, pattern: string, repl: Repl, flags?: integer): string | nil, string
  BASIC: integer
  ICASE: integer
  NEWLINE: integer
  NOSUB: integer
  NOTBOL: integer
  NOTEOL: integer
end
```

### MatchIterator

 Iterator yielded by gmatch: each call returns the next match and
 its capture table, then nil when exhausted.

alias of `function`

### Repl

 Replacement for gsub: a literal string (no capture references —
 "%1" is two plain characters), or a function receiving the matched
 text and its capture groups; a nil return keeps the match unchanged.

alias of `string`

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

### match

```teal
function match(text: string, pattern: string, flags?: integer): string | nil, {string} | nil, string | nil
```

 Match pattern against text (convenience function; subject first).
 Compiles pattern on each call - use compile() for repeated matching.
 Uses POSIX extended syntax by default.
 On a match, returns the matched substring plus a table of the
 parenthesized capture groups (an empty table when the pattern has no
 groups, "" for groups that did not participate). A no-match returns
 nil with no error; a bad pattern or an engine failure returns
 nil, nil, err.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB

**Returns:**

- string - | nil The matched substring, or nil on no match or error
- {string} - | nil Capture groups on match
- string - | nil Error message if compilation or the engine failed

### test

```teal
function test(text: string, pattern: string, flags?: integer): boolean, string
```

 Check if pattern matches anywhere in text (subject first).
 Convenience predicate returning boolean instead of matched text.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE, NOSUB

**Returns:**

- boolean - True if pattern matches, false otherwise
- string? - Error message if compilation or the engine failed

### find

```teal
function find(text: string, pattern: string, flags?: integer): Span | nil, string
```

 Find the first match of pattern in text, with its position: a Span
 {s, e, m, caps} (absolute 1-based, inclusive). A no-match returns
 bare nil; a bad pattern or engine failure returns nil, err.
 Patterns that can match the empty string are rejected.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE

**Returns:**

- Span - | nil The first match, or nil when none
- string? - Error message on a bad pattern or engine failure

### find_all

```teal
function find_all(text: string, pattern: string, flags?: integer): {Span} | nil, string
```

 Every non-overlapping match of pattern in text, leftmost first, as
 Spans. Patterns that can match the empty string are rejected.
 KNOWN LIMITATION with the NEWLINE flag: `^`/`$` anchors that only
 match via an embedded newline (not the true start/end of text) fail
 to be re-confirmed past the first line (see locate's doc), so
 find_all("foo\nfoo", "^foo", re.NEWLINE) returns nil, "failed to
 locate match position for: foo" instead of two spans -- use
 split plus a per-line match instead when this matters.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE

**Returns:**

- {Span} - | nil The matches (empty when none), or nil on error
- string? - Error message on a bad pattern or engine failure

### gmatch

```teal
function gmatch(text: string, pattern: string, flags?: integer): MatchIterator, string
```

 Iterate every non-overlapping match, like string.gmatch: each step
 yields the matched text and its capture table. Matching is done up
 front (the engine reports no offsets, so lazy stepping buys
 nothing); a bad pattern or engine failure returns nil, err instead
 of an iterator. Shares find_all's NEWLINE limitation.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE

**Returns:**

- function - | nil Iterator yielding (match, caps), or nil on error
- string? - Error message on a bad pattern or engine failure

### split

```teal
function split(text: string, pattern: string, flags?: integer): {string} | nil, string
```

 Split text around every match of pattern. Fields between matches
 are kept verbatim, including empty ones from adjacent or
 leading/trailing matches; text with no match yields one field.
 Patterns that can match the empty string are rejected.
 Shares find_all's KNOWN LIMITATION with a NEWLINE-anchored `^`/`$`
 past the first line (see find_all's doc).

**Parameters:**

- `text` (string) - The text to split
- `pattern` (string) - The regex pattern to split on
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE

**Returns:**

- {string} - | nil The fields, or nil on error
- string? - Error message on a bad pattern or engine failure

### gsub

```teal
function gsub(text: string, pattern: string, repl: Repl, flags?: integer): string | nil, string
```

 Replace every non-overlapping match of pattern in text.
 Patterns that can match the empty string are rejected.
 Shares find_all's KNOWN LIMITATION with a NEWLINE-anchored `^`/`$`
 past the first line (see find_all's doc).

**Parameters:**

- `text` (string) - The text to operate on
- `pattern` (string) - The regex pattern to match
- `repl` (Repl) - A literal replacement string, or function(match, caps)
- `flags` (integer?) - Optional compile flags: BASIC, ICASE, NEWLINE

**Returns:**

- string - | nil The result, or nil on error
- string? - Error message on a bad pattern or engine failure
