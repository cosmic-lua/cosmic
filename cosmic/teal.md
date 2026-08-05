# teal

 Teal compilation and type-checking.
 --compile uses lax mode for permissive compilation (the gradual-typing
 on-ramp for plain-Lua scripts); --compile-strict type-checks strictly
 (warnings fail, matching --check types) and generates from the same
 checked AST — the build uses it for in-tree sources so nothing ships
 that did not typecheck. --check types uses strict mode.

## Types

### Issue

 A compiler or type checker issue.

```teal
local record Issue
  file: string
  line: integer
  column: integer
  message: string
  severity: string
  tag: string
end
```

### CompileOptions

 Options for compiling Teal to Lua.
 strict type-checks strictly before generating (warnings fail too,
 matching check's default) and emits code from that same checked AST.
 werror = false keeps the strict type check and lets warnings pass:
 the runtime in-project searcher wants the checking, not the style
 gate. See `cosmic.searcher`.

```teal
local record CompileOptions
  include_dirs: {string}
  gen_target: string
  gen_compat: string
  strict: boolean
  werror: boolean
end
```

### CheckOptions

 Options for type-checking Teal files.
 Warnings fail the check unless werror is explicitly set to false.

```teal
local record CheckOptions
  include_dirs: {string}
  werror: boolean
end
```

### CompileResult

 Result from compiling a Teal file. `code` is nil when ok is
 false — the type says so instead of forcing a cast at every
 consumer.

```teal
local record CompileResult
  ok: boolean
  code: string | nil
  errors: {Issue}
end
```

### CheckResult

 Result from type-checking a Teal file.

```teal
local record CheckResult
  ok: boolean
  warnings: {Issue}
  errors: {Issue}
end
```

### TlError

 Error from the Teal compiler.

```teal
local record TlError
  msg: string
  filename: string
  y: integer
  x: integer
  tag: string
end
```

### TlResult

 Result from Teal's process_string function.

```teal
local record TlResult
  syntax_errors: {TlError}
  type_errors: {TlError}
  warnings: {TlError}
  ast: any
end
```

### ProcessResult

 Internal result from processing a Teal file.

```teal
local record ProcessResult
  tl_result: TlResult
  shebang: string
  error: Issue
end
```

### TealModule

```teal
local record TealModule
  DEFAULT_GEN_TARGET: string
  DEFAULT_GEN_COMPAT: string
  BUILD_INCLUDE_DIRS: {string}
  compile: function(input_path: string, opts?: CompileOptions): CompileResult
  compile_cached: function(input_path: string, strict?: boolean): string | nil, string
  check: function(input_path: string, opts?: CheckOptions): CheckResult
  search_module: function(module_name: string, include_dirs?: {string}): string | nil
  format_issues: function(issues: {Issue}): string
  format_issues_with_hints: function(issues: {Issue}): string
  hint_for_message: function(msg: string): string | nil
  get_default_include_dirs: function(): {string}
end
```

## Functions

### get_default_include_dirs

```teal
function get_default_include_dirs(): {string}
```

 Get default include directories for cosmic type definitions.
 Returns paths to bundled and local type definition directories.

**Returns:**

- {string} - List of default include directory paths

### search_module

```teal
function search_module(module_name: string, include_dirs?: {string}): string | nil
```

 Find the source file for a module name using the same search path
 the compiler uses (TL_PATH, include dirs, package.path). Used by the
 runtime .tl searcher so require() resolves modules exactly like
 --compile/--check types do.

**Parameters:**

- `module_name` (string) - Module name as passed to require()
- `include_dirs?` ({string}) - Extra include dirs (defaults merged in)

**Returns:**

- string|nil - Path to the found source, or nil

### compile

```teal
function compile(input_path: string, opts: CompileOptions): CompileResult
```

 Compile a Teal file to Lua code.
 Lax mode by default (permissive, for user scripts); opts.strict
 type-checks strictly first — warnings fail too, matching check's
 default — and generates from that same checked AST, so a strict
 compile can never ship code the checker rejected. Preserves shebang.

**Parameters:**

- `input_path` (string) - Path to the Teal file to compile
- `opts` (CompileOptions) - Compilation options (include_dirs, gen_target, gen_compat, strict)

**Returns:**

- CompileResult - Result with ok status, generated Lua code, and any errors

### check

```teal
function check(input_path: string, opts: CheckOptions): CheckResult
```

 Type-check a Teal file.
 Uses strict mode for thorough type checking. Collects errors and warnings.
 Warnings fail the check (ok = false) unless opts.werror is explicitly
 false: an unused local or shadowed variable is a defect the author must
 either fix or deliberately mark (leading underscore), never ignore.

**Parameters:**

- `input_path` (string) - Path to the Teal file to check
- `opts` (CheckOptions) - Type-checking options (include_dirs, werror)

**Returns:**

- CheckResult - Result with ok status, warnings, and errors

### format_issues

```teal
function format_issues(issues: {Issue}): string
```

 Format issues for human-readable output.
 Creates formatted strings like "file.tl:10:5: error: message".

**Parameters:**

- `issues` ({Issue}) - List of issues to format

**Returns:**

- string - Formatted issues, one per line

### hint_for_message

```teal
function hint_for_message(msg: string): string | nil
```

 Return a fix-hint line for a known Teal type-check error pattern, or nil.
 Matches the three most common traps that cost edit-check cycles:
   1. got number, expected integer (string index/length requires integer)
   2. got X | nil, expected X (nil not narrowed before use)
   3. excess return values (multiple returns captured incorrectly)
   4. <any type> operations (ipairs, index, concat on any)

**Parameters:**

- `msg` (string) - The error message to match

**Returns:**

- string|nil - A short hint string, or nil if no hint applies

### format_issues_with_hints

```teal
function format_issues_with_hints(issues: {Issue}): string
```

 Format issues with optional fix-hints for known Teal type-check traps.
 Appends one hint line after each matching error. No duplicate hints per error.

**Parameters:**

- `issues` ({Issue}) - List of issues to format

**Returns:**

- string - Formatted issues with hints, one issue (plus optional hint) per pair of lines

### compile_cached

```teal
function compile_cached(input_path: string,
    strict?: boolean): string | nil, string
```

 Compile a Teal file, reusing cached output when the source has not
 changed. Lax, like `compile`; `check` remains the strict gate.
 The loop itself lives with the cache it drives (`cosmic._script_cache`);
 this is the name its two callers know it by.

**Parameters:**

- `input_path` (string) - Path to the Teal file to compile
- `strict?` (boolean) - Type-check strictly (warnings still pass)

**Returns:**

- string|nil - The generated Lua code, or nil when compilation failed
- string - The formatted issues when compilation failed
