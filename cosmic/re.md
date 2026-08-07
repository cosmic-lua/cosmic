# re

 Regular expression matching using POSIX extended regex syntax.
 Wraps cosmo.re for pattern compilation and matching. Module-level
 functions are SUBJECT-FIRST D20: match(text, pattern), like
 string.match. Compile behavior is a CompileOptions record — a search
 flag in a compile slot cannot type-check, where the old shared
 integer namespace silently ignored it. The compiled Regex keeps the
 binding's own :search/:find method names and integer search flags
 (NOTBOL/NOTEOL) — a userdata metatable is the C layer's to name, so
 renaming them is an upstream change, not a record edit.

 For best performance, compile patterns once and reuse them.
 The convenience functions (match, is_match, find, find_all, gmatch,
 split, gsub) take a pattern string per call; a bounded module cache
 memoizes their compiled patterns, so repeated calls with the same
 pattern skip recompilation. compile() itself is never cached: it is
 the explicit-lifetime API, and each call returns a fresh handle.

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
  --  Like search, but reports WHERE: absolute 1-based inclusive start
  --  and end offsets into text, plus the capture table. init starts
  --  the search at that offset while keeping the returned offsets
  --  absolute, which is what lets iteration advance in O(n) instead of
  --  re-slicing the subject per match. A no-match is a single bare
  --  nil; an engine failure puts the error string in the second
  --  position.
  find: function(self: Regex, text: string, flags?: integer, init?: integer): integer | nil, integer | string | nil, {string}
end
```

### CompileOptions

 Compile behavior. Each field maps to one POSIX cflag; a record
 keeps the compile and search namespaces unmixable (the old integer
 flags shared one namespace, so a search flag passed at compile time
 type-checked and was silently ignored).

```teal
local record CompileOptions
  --  Basic (obsolete) regex syntax instead of extended.
  basic: boolean
  --  Case-insensitive matching.
  ignore_case: boolean
  --  Treat newline as special (affects ^ and $).
  newline: boolean
  --  Report only success/failure, not match position.
  no_sub: boolean
end
```

### CacheEntry

 One memoized compilation of a convenience-surface pattern. rx/err
 record the compile outcome; iter_ok/iter_err record the (lazy)
 empty-match probe compile_for_iter runs on top of it.

```teal
local record CacheEntry
  rx: Regex
  err: string
  iter_ok: boolean
  iter_err: string
end
```

### Match

 One match: the matched text and its parenthesized capture groups
 (an empty table when the pattern has none, "" for groups that did
 not participate).

```teal
local record Match
  text: string
  caps: {string}
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
  compile: function(pattern: string, opts?: CompileOptions): Regex | nil, string
  match: function(text: string, pattern: string, opts?: CompileOptions): Match | nil, string
  is_match: function(text: string, pattern: string, opts?: CompileOptions): boolean | nil, string
  find: function(text: string, pattern: string, opts?: CompileOptions): Span | nil, string
  find_all: function(text: string, pattern: string, opts?: CompileOptions): {Span} | nil, string
  gmatch: function(text: string, pattern: string, opts?: CompileOptions): MatchIterator | nil, string
  split: function(text: string, pattern: string, opts?: CompileOptions): {string} | nil, string
  gsub: function(text: string, pattern: string, repl: Repl, opts?: CompileOptions): string | nil, string
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
function compile(pattern: string, opts?: CompileOptions): Regex | nil, string
```

 Compile a regular expression pattern.
 Compiled patterns can be reused for efficient O(n) matching.
 Uses POSIX extended syntax by default.

**Parameters:**

- `pattern` (string) - The regex pattern to compile
- `opts` (CompileOptions?) - Compile behavior

**Returns:**

- Regex? - The compiled regex, or nil on error
- string? - Error message if compilation failed

### match

```teal
function match(text: string, pattern: string, opts?: CompileOptions): Match | nil, string
```

 Match pattern against text (convenience function; subject first).
 Compiled patterns are cached - compile() gives explicit reuse.
 Uses POSIX extended syntax by default. Two slots, three honest
 outcomes: a Match on success, bare nil on no match (not an error),
 nil + err on a bad pattern or engine failure — the old three-slot
 tuple made every call site hand-decode which nil it was looking at.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `opts` (CompileOptions?) - Compile behavior

**Returns:**

- Match - | nil The match, or nil when none (or on error)
- string - | nil Error message if compilation or the engine failed

### is_match

```teal
function is_match(text: string, pattern: string, opts?: CompileOptions): boolean | nil, string
```

 Whether pattern matches anywhere in text (subject first).
 Three honest outcomes: true, false on a clean no-match, and
 nil + err on a bad pattern — the old boolean shape returned false
 for both, so "no match" and "your pattern is invalid" were the
 same value. Narrow with `~= nil`, which is exact for boolean unions.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `opts` (CompileOptions?) - Compile behavior

**Returns:**

- boolean - | nil The verdict, or nil on error
- string? - Error message if compilation or the engine failed

### find

```teal
function find(text: string, pattern: string, opts?: CompileOptions): Span | nil, string
```

 Find the first match of pattern in text, with its position: a Span
 {s, e, m, caps} (absolute 1-based, inclusive). A no-match returns
 bare nil; a bad pattern or engine failure returns nil, err.
 Patterns that can match the empty string are rejected.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `opts` (CompileOptions?) - Compile behavior

**Returns:**

- Span - | nil The first match, or nil when none
- string? - Error message on a bad pattern or engine failure

### find_all

```teal
function find_all(text: string, pattern: string, opts?: CompileOptions): {Span} | nil, string
```

 Every non-overlapping match of pattern in text, leftmost first, as
 Spans. Patterns that can match the empty string are rejected.
 Under the NEWLINE compile flag, `^`/`$` anchors match at embedded
 newlines as POSIX specifies: find_all("foo\nfoo", "^foo",
 re.NEWLINE) returns both spans. (The engine reports offsets
 directly, which removed the relocation pass whose verification
 window historically could not see those anchors past the first
 line.)

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `opts` (CompileOptions?) - Compile behavior

**Returns:**

- {Span} - | nil The matches (empty when none), or nil on error
- string? - Error message on a bad pattern or engine failure

### gmatch

```teal
function gmatch(text: string, pattern: string, opts?: CompileOptions): MatchIterator | nil, string
```

 Iterate every non-overlapping match, like string.gmatch: each step
 yields the matched text and its capture table. Matching is done up
 front over find_all's spans; a bad pattern or engine failure
 returns nil, err instead of an iterator — and the signature now
 admits that nil, so `for m in re.gmatch(t, p) do` on a bad pattern
 is a check error instead of a runtime crash.

**Parameters:**

- `text` (string) - The text to search in
- `pattern` (string) - The regex pattern to match
- `opts` (CompileOptions?) - Compile behavior

**Returns:**

- function - | nil Iterator yielding (match, caps), or nil on error
- string? - Error message on a bad pattern or engine failure

### split

```teal
function split(text: string, pattern: string, opts?: CompileOptions): {string} | nil, string
```

 Split text around every match of pattern. Fields between matches
 are kept verbatim, including empty ones from adjacent or
 leading/trailing matches; text with no match yields one field.
 Patterns that can match the empty string are rejected.

**Parameters:**

- `text` (string) - The text to split
- `pattern` (string) - The regex pattern to split on
- `opts` (CompileOptions?) - Compile behavior

**Returns:**

- {string} - | nil The fields, or nil on error
- string? - Error message on a bad pattern or engine failure

### gsub

```teal
function gsub(text: string, pattern: string, repl: Repl, opts?: CompileOptions): string | nil, string
```

 Replace every non-overlapping match of pattern in text.
 Patterns that can match the empty string are rejected.

**Parameters:**

- `text` (string) - The text to operate on
- `pattern` (string) - The regex pattern to match
- `repl` (Repl) - A literal replacement string, or function(match, caps)
- `opts` (CompileOptions?) - Compile behavior

**Returns:**

- string - | nil The result, or nil on error
- string? - Error message on a bad pattern or engine failure
