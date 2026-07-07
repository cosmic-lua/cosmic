# envd

 Load environment variables from an embedded env.d directory.

 Files in the env.d directory use dotenv format: each line is either
 a KEY=VALUE assignment or a comment (lines starting with #). Files
 are read in lexical (sorted) order and concatenated — later assignments
 to the same key within env.d win. Existing environment variables are
 NOT overwritten; the real environment always takes precedence.

 This follows the dotenv convention for embedding credentials (API keys,
 tokens) into a cosmic executable:

   mkdir env.d
   echo 'ANTHROPIC_API_KEY=sk-ant-...' > env.d/api
   cosmic --embed env.d

 At startup, call envd.load() to read /zip/embed/env.d/ and set any
 variables not already present in the environment.

 Key names must match [A-Za-z_][A-Za-z0-9_]*. Blank lines and lines
 starting with # are ignored. Values are taken as-is after the first =
 (no trimming, no quote stripping).

 Variable expansion is supported in values using ${VAR} syntax:
   ${VAR}            expands to the value of VAR
   ${VAR:-default}   expands to default if VAR is unset or empty
   ${VAR-default}    expands to default if VAR is unset
 Variables defined earlier in the same file or in earlier files (lexical
 order) are available for expansion, as are existing environment variables.
 Undefined variables with no default expand to empty string.

 Set COSMIC_DEBUG=1 to see which vars are loaded and which are skipped.

## Types

### LoadResult

 Result returned from load operations.

```teal
local record LoadResult
  count: integer
  source: string
  --  Per-entry failures (unreadable files, env.set errors). Loading
  --  continues past them; an empty list means a clean load.
  errors: {string}
end
```

### EnvdModule

```teal
local record EnvdModule
  load: function(): LoadResult
  load_dir: function(dir: string): LoadResult
  parse: function(content: string, ctx?: {string: string}): {string: string}
  expand: function(value: string, ctx: {string: string}): string
end
```

## Functions

### expand

```teal
function expand(value: string, ctx: {string: string}): string
```

 Expand ${VAR}, ${VAR:-default}, and ${VAR-default} references in a
 string. Looks up variables in ctx first, then falls back to the
 process environment. Undefined variables with no default expand to
 empty string.

**Parameters:**

- `value` (string) - The string to expand
- `ctx` ({string:) - string} Context of previously defined variables

**Returns:**

- string - The expanded string

### parse

```teal
function parse(content: string, ctx?: {string: string}): {string: string}
```

 Parse a single dotenv-format string. Returns a map of KEY=VALUE pairs.
 Lines starting with # are comments. Blank lines are skipped.
 Keys must match [A-Za-z_][A-Za-z0-9_]*.
 Values undergo ${VAR} expansion using ctx as the lookup context.

**Parameters:**

- `content` (string) - The dotenv content to parse
- `ctx?` ({string:) - string} Context for variable expansion (default: {})

**Returns:**

- {string: - string} Parsed key-value pairs

### load_dir

```teal
function load_dir(dir: string): LoadResult
```

 Load env vars from a directory of dotenv files. Files are read in
 lexical order and concatenated — later files can override keys from
 earlier files. Existing env vars are never overwritten.
 When COSMIC_DEBUG is set, prints the name (not value) of each variable
 set or skipped to stderr, along with the source file.

**Parameters:**

- `dir` (string) - The directory to read dotenv files from

**Returns:**

- LoadResult - Result with count of variables set and source path

### load

```teal
function load(): LoadResult
```

 Load env vars from the embedded /zip/embed/env.d directory.
 Call this early in startup, before code that depends on the variables.

**Returns:**

- LoadResult - Result with count of variables set and source path
