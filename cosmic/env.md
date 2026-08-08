# env

 Environment variables: get/set/unset/list, dotenv, and env.d loading.
 Reading, setting, and listing environment variables — env.get()
 returns nil when the variable is not set, so the caller narrows;
 env.get_or() takes a fallback and cannot fail — plus the dotenv
 half (#994: was cosmic.envd): parse_dotenv/format_dotenv for the
 KEY=VALUE text format, expand for ${VAR} references, and
 load_dotenv/load_embedded_dotenv to apply a directory of dotenv
 files to the process environment.

 Dotenv format: each line is a KEY=VALUE assignment or a comment
 (lines starting with #); blank lines are skipped. Keys must match
 [A-Za-z_][A-Za-z0-9_]*. Values are taken as-is after the first =
 (no trimming, no quote stripping) and support ${VAR} expansion:
   ${VAR}            expands to the value of VAR
   ${VAR:-default}   expands to default if VAR is unset or empty
   ${VAR-default}    expands to default if VAR is unset
 Variables defined earlier in the same file or in earlier files
 (lexical order) are available for expansion, as are existing
 environment variables. Undefined variables with no default expand
 to the empty string.

 The load half follows the dotenv convention for embedding
 credentials (API keys, tokens) into a cosmic executable:

   mkdir env.d
   echo 'ANTHROPIC_API_KEY=sk-ant-...' > env.d/api
   cosmic --embed env.d

 At startup, call env.load_embedded_dotenv() to read
 /zip/embed/env.d/ and set any variables not already present in the
 environment; the real environment always takes precedence. Set
 COSMIC_DEBUG=1 to see which vars are loaded and which are skipped.

## Types

### ListOptions

 Options for list(): edits applied to the current environment.

```teal
local record ListOptions
  --  variable names to remove
  drop: {string}
  --  names to set or override; applied after drop, appended in
  --  sorted-name order so the result is deterministic
  set: {string: string}
end
```

### LoadResult

 Result returned from load_dotenv()/load_embedded_dotenv().

```teal
local record LoadResult
  count: integer
  source: string
  --  Per-entry failures (an unreadable directory or file, env.set
  --  errors). Loading continues past them; an empty list means a
  --  clean load.
  errors: {string}
end
```

### EnvModule

```teal
local record EnvModule
  get: function(name: string): string | nil
  get_or: function(name: string, default: string): string
  set: function(name: string, value: string, overwrite?: boolean): boolean, string
  unset: function(name: string): boolean, string
  all: function(): {string: string}
  list: function(opts?: ListOptions): {string}
  expand: function(value: string, ctx: {string: string}): string
  parse_dotenv: function(content: string, ctx?: {string: string}): {string: string}
  format_dotenv: function(vars: {string: string}): string
  load_dotenv: function(dir: string): LoadResult
  load_embedded_dotenv: function(): LoadResult
end
```

## Functions

### get

```teal
function get(name: string): string | nil
```

 Get the value of an environment variable, or nil when it is not set.
 **The nil is in the type**, which is the whole point of this
 function's shape. An optional default with a bare `string` return
 is a lie the checker cannot see: with no default the body returns
 the parameter, which is `string` inside the function and nil at the
 call site, so `local v: string = env.get("X")` type-checks strictly
 and crashes on the next line. A reading that can fail says so, and
 the caller narrows -- see `get_or` for the half that cannot fail.

**Parameters:**

- `name` (string) - The name of the environment variable

**Returns:**

- string|nil - The value, or nil when the variable is not set

### get_or

```teal
function get_or(name: string, default: string): string
```

 Get the value of an environment variable, or `default` when unset.
 The infallible half, and it is a separate function rather than an
 optional argument because the two have genuinely different types: a
 read with a fallback CANNOT fail, so making its caller narrow would
 be noise, and folding both into one signature is what produced a
 return type that was wrong half the time.

**Parameters:**

- `name` (string) - The name of the environment variable
- `default` (string) - The value to return when it is not set

**Returns:**

- string - The value, or `default`

### set

```teal
function set(name: string, value: string, overwrite?: boolean): boolean, string
```

 Set an environment variable.

**Parameters:**

- `name` (string) - The name of the environment variable
- `value` (string) - The value to set
- `overwrite?` (boolean) - If false, won't overwrite existing variables (defaults to true)

**Returns:**

- boolean - True on success
- string? - Error message if setting failed

### unset

```teal
function unset(name: string): boolean, string
```

 Unset an environment variable.

**Parameters:**

- `name` (string) - The name of the environment variable to remove

**Returns:**

- boolean - True on success
- string? - Error message if unsetting failed

### all

```teal
function all(): {string: string}
```

 Get all environment variables.
 Returns a table mapping variable names to their values.

**Returns:**

- {string:string} - A table of all environment variables

### list

```teal
function list(opts?: ListOptions): {string}
```

 Get the environment as a list of "KEY=VALUE" strings, optionally
 edited — the shape `child.Options.env` and execve take. This is
 the one place to build "the current environment, minus these
 variables, plus those" instead of hand-rolling a filter loop:
   env.list({drop = {"LUA_PATH"}, set = {NO_COLOR = "1"}})

**Parameters:**

- `opts` (ListOptions?) - drop: names to remove; set: names to set/override

**Returns:**

- {string} - A list of "KEY=VALUE" strings

### expand

```teal
function expand(value: string, ctx: {string: string}): string
```

 Expand ${VAR}, ${VAR:-default}, and ${VAR-default} references in a
 string. Looks up variables in ctx first, then falls back to the
 process environment. Undefined variables with no default expand to
 empty string; a malformed ${...} expression is left as-is.

**Parameters:**

- `value` (string) - The string to expand
- `ctx` ({string:) - string} Context of previously defined variables

**Returns:**

- string - The expanded string

### parse_dotenv

```teal
function parse_dotenv(content: string, ctx?: {string: string}): {string: string}
```

 Parse a dotenv-format string. Returns a map of KEY=VALUE pairs.
 Lines starting with # are comments; blank lines are skipped; a
 line whose key does not match the key grammar is ignored. Values
 undergo ${VAR} expansion using ctx as the lookup context.

**Parameters:**

- `content` (string) - The dotenv content to parse
- `ctx?` ({string:) - string} Context for variable expansion (default: {})

**Returns:**

- {string: - string} Parsed key-value pairs

### format_dotenv

```teal
function format_dotenv(vars: {string: string}): string
```

 Format a map of variables as dotenv text: one KEY=VALUE line per
 entry, sorted by key, each newline-terminated (an empty map
 formats to ""). The format half of parse_dotenv (rule 6). The
 result round-trips through parse_dotenv when keys match the dotenv
 key grammar and values contain no newlines or ${...} references —
 format does not escape, because the format has no escape syntax.

**Parameters:**

- `vars` ({string:string}) - The variables to format

**Returns:**

- string - The dotenv text

### load_dotenv

```teal
function load_dotenv(dir: string): LoadResult
```

 Load env vars from a directory of dotenv files. Files are read in
 lexical order and concatenated — later files can override keys from
 earlier files. Existing env vars are never overwritten. A missing
 or unreadable directory is reported in the result's errors (see
 load_embedded_dotenv for the call where an absent directory is an
 ordinary state rather than a defect).
 When COSMIC_DEBUG is set, prints the name (not value) of each
 variable set or skipped to stderr, along with the source file.

**Parameters:**

- `dir` (string) - The directory to read dotenv files from

**Returns:**

- LoadResult - Count of variables set, source path, and errors

### load_embedded_dotenv

```teal
function load_embedded_dotenv(): LoadResult
```

 Load env vars from the embedded /zip/embed/env.d directory.
 Call this early in startup, before code that depends on the
 variables. A binary with no embedded env.d is an ordinary state,
 not a defect: an absent directory returns a clean empty result,
 while an unreadable one is an error like any other.

**Returns:**

- LoadResult - Count of variables set, source path, and errors
