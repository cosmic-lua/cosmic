# re

Type declarations for the `re` module.

## Types

### Regex

```teal
local record Regex
  --  Executes precompiled regular expression.
  --  On a match, returns the whole matched substring plus a table of the
  --  parenthesized capture groups (an empty table when the pattern has no groups).
  --  A no-match is not an error: it returns a single bare `nil`, so the idiomatic
  --  `if match then` works. Only a genuine regex engine failure (e.g. running out
  --  of memory) returns `nil, err`. Flags may contain `re.NOTBOL` or `re.NOTEOL`
  --  to indicate whether or not text should be considered at the start and/or end
  --  of a line.
  --  - `re.NOTBOL`
  --  - `re.NOTEOL`
  --  This has an O(𝑛) cost.
  search: function(self: Regex, str: string, flags?: SearchFlag): string | nil, {string}, string | nil
end
```

### re Constants

Constants defined in the re module.

```teal
local record re Constants
  --  No match
  NOMATCH: integer
  --  Invalid regex
  BADPAT: integer
  --  Unknown collating element
  ECOLLATE: integer
  --  Unknown character class name
  ECTYPE: integer
  --  Trailing backslash
  EESCAPE: integer
  --  Invalid back reference
  ESUBREG: integer
  --  Missing ]
  EBRACK: integer
  --  Missing )
  EPAREN: integer
  --  Missing }
  EBRACE: integer
  --  Invalid contents of {}
  BADBR: integer
  --  Invalid character range.
  ERANGE: integer
  --  Out of memory
  ESPACE: integer
  --  Repetition not preceded by valid expression
  BADRPT: integer
  --  Use this flag if you prefer the default POSIX regex syntax.
  --  We use extended regex notation by default. For example, an extended regular
  --  expression for matching an IP address might look like
  --  `([0-9]*)\.([0-9]*)\.([0-9]*)\.([0-9]*)` whereas with basic syntax it would
  --  look like `\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)`.
  --  This flag may only be used with `re.compile` and `re.search`.
  BASIC: integer
  --  Use this flag if you prefer the default POSIX regex syntax. We use extended
  --   regex notation by default. For example, an extended regular expression for
  --  matching an IP address might look like `([0-9]*)\.([0-9]*)\.([0-9]*)\.([0-9]*)`
  --  whereas with basic syntax it would look like `\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)\.\([0-9]*\)`.
  --  This flag may only be used with `re.compile` and `re.search`.
  ICASE: integer
  --  Use this flag to change the handling of NEWLINE (\x0a) characters. When this
  --  flag is set, (1) a NEWLINE shall not be matched by a "." or any form of a
  --  non-matching list, (2) a "^" shall match the zero-length string immediately
  --  after a NEWLINE (regardless of `re.NOTBOL`), and (3) a "$" shall match the
  --  zero-length string immediately before a NEWLINE (regardless of `re.NOTEOL`).
  NEWLINE: integer
  --  Causes `re.search` to only report success and failure. This is reported via
  --  the API by returning empty string for success. This flag may only be used
  --  ` with `re.compile` and `re.search`.
  NOSUB: integer
  --  The first character of the string pointed to by string is not the beginning
  --  of the line. This flag may only be used with `re.search` and `regex_t*:search`.
  NOTBOL: integer
  --  The last character of the string pointed to by string is not the end of the
  --  line. This flag may only be used with `re.search` and `regex_t*:search`.
  NOTEOL: integer
end
```

## Functions

### search

```teal
function search(regex: string, text: string, flags?: CompileFlag | SearchFlag): string | nil, {string}, string | nil
```

 Searches for regular expression match in text.
 This is a shorthand notation roughly equivalent to:
     local preg = assert(re.compile(regex))
     local match, captures = preg:search(text)
 On a match, returns the whole matched substring plus a table of the
 parenthesized capture groups. A no-match returns a bare `nil`. A bad pattern
 (compile failure) or a regex engine failure returns `nil, err`.
 - `re.BASIC`
 - `re.ICASE`
 - `re.NEWLINE`
 - `re.NOSUB`
 - `re.NOTBOL`
 - `re.NOTEOL`
 This has exponential complexity. Please use `re.compile()` to compile your regular expressions once from `/.init.lua`. This API exists for convenience. This isn't recommended for prod.
 This uses POSIX extended syntax by default.

**Parameters:**

- `regex` (string)
- `text` (string)
- `flags` (CompileFlag | SearchFlag)

**Returns:**

- string | nil
- {string}
- string | nil

### compile

```teal
function compile(regex: string, flags?: CompileFlag): Regex | nil, string | nil
```

 Compiles regular expression.
 - `re.BASIC`
 - `re.ICASE`
 - `re.NEWLINE`
 - `re.NOSUB`
 This has an O(2^𝑛) cost. Consider compiling regular expressions once
 from your `/.init.lua` file.
 If regex is an untrusted user value, then `unix.setrlimit` should be
 used to impose cpu and memory quotas for security.
 This uses POSIX extended syntax by default.

**Parameters:**

- `regex` (string)
- `flags` (CompileFlag)

**Returns:**

- Regex | nil
- string | nil
