# teal

 Teal compilation and type-checking.
 Both halves of the source/file naming convention: `compile(source)`/
 `check(source)` take Teal SOURCE, `compile_file(path)`/`check_file(path)`
 take a path — the file variant wears the `_file` suffix instead of the
 bare name. --compile uses lax mode for permissive compilation (the
 gradual-typing on-ramp for plain-Lua scripts); --compile-strict
 type-checks strictly (warnings fail, matching --check types) and
 generates from the same checked AST — the build uses it for
 in-tree sources so nothing ships that did not typecheck. --check
 types uses strict mode.

## Types

### FormatOptions

 Options for format_issues.

```teal
local record FormatOptions
  --  Append one fix-hint line after each error matching a known Teal
  --  type-check trap.
  hints: boolean
end
```

### CacheOptions

 Options for compile_cached.

```teal
local record CacheOptions
  --  Type-check strictly (warnings still pass), like CompileOptions.
  strict: boolean
end
```

### TealModule

```teal
local record TealModule
  DEFAULT_GEN_TARGET: string
  DEFAULT_GEN_COMPAT: string
  BUILD_INCLUDE_DIRS: {string}
  compile: function(source: string, opts?: CompileOptions): CompileResult
  compile_file: function(input_path: string, opts?: CompileOptions): CompileResult
  compile_cached: function(input_path: string, opts?: CacheOptions): string | nil, string
  check: function(source: string, opts?: CheckOptions): CheckResult
  check_file: function(input_path: string, opts?: CheckOptions): CheckResult
  search_module: function(module_name: string, include_dirs?: {string}): string | nil
  format_issues: function(issues: {Issue}, opts?: FormatOptions): string
  hint_for_message: function(msg: string): string | nil
  default_include_dirs: function(): {string}
end
```

### Issue

alias of `cosmic._teal_engine.Issue` — field and method table: `cosmic --docs cosmic._teal_engine.Issue`

### CompileOptions

alias of `cosmic._teal_engine.CompileOptions` — field and method table: `cosmic --docs cosmic._teal_engine.CompileOptions`

### CheckOptions

alias of `cosmic._teal_engine.CheckOptions` — field and method table: `cosmic --docs cosmic._teal_engine.CheckOptions`

### CompileResult

alias of `cosmic._teal_engine.CompileResult` — field and method table: `cosmic --docs cosmic._teal_engine.CompileResult`

### CheckResult

alias of `cosmic._teal_engine.CheckResult` — field and method table: `cosmic --docs cosmic._teal_engine.CheckResult`

### ProcessResult

alias of `cosmic._teal_engine.ProcessResult` — field and method table: `cosmic --docs cosmic._teal_engine.ProcessResult`

## Functions

### compile

```teal
function compile(source: string, opts?: CompileOptions): CompileResult
```

 Compile Teal SOURCE to Lua code (the string half — the file
 variant is compile_file). Lax mode by default (permissive, for user
 scripts); opts.strict type-checks strictly first — warnings fail
 too, matching check's default — and generates from that same
 checked AST, so a strict compile can never ship code the checker
 rejected. Preserves a leading shebang. Errors carry opts.chunk_name
 (default "source") as their file.

**Parameters:**

- `source` (string) - The Teal source text
- `opts` (CompileOptions?) - Compilation options (include_dirs, gen_target, gen_compat, strict, chunk_name)

**Returns:**

- CompileResult - Result with ok status, generated Lua code, and any errors

### compile_file

```teal
function compile_file(input_path: string, opts?: CompileOptions): CompileResult
```

 Compile a Teal file to Lua code.
 Same contract as compile; the path names the errors.

**Parameters:**

- `input_path` (string) - Path to the Teal file to compile
- `opts` (CompileOptions?) - Compilation options (include_dirs, gen_target, gen_compat, strict)

**Returns:**

- CompileResult - Result with ok status, generated Lua code, and any errors

### check

```teal
function check(source: string, opts?: CheckOptions): CheckResult
```

 Type-check Teal SOURCE (the string half — the file variant
 is check_file). Uses strict mode. Warnings fail the check
 (ok = false) unless opts.werror is explicitly false: an unused
 local or shadowed variable is a defect the author must either fix
 or deliberately mark (leading underscore), never ignore. Errors
 carry opts.chunk_name (default "source") as their file.

**Parameters:**

- `source` (string) - The Teal source text
- `opts` (CheckOptions?) - Type-checking options (include_dirs, werror, chunk_name)

**Returns:**

- CheckResult - Result with ok status, warnings, and errors

### check_file

```teal
function check_file(input_path: string, opts?: CheckOptions): CheckResult
```

 Type-check a Teal file.
 Same contract as check; the path names the errors.

**Parameters:**

- `input_path` (string) - Path to the Teal file to check
- `opts` (CheckOptions?) - Type-checking options (include_dirs, werror)

**Returns:**

- CheckResult - Result with ok status, warnings, and errors

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

### format_issues

```teal
function format_issues(issues: {Issue}, opts?: FormatOptions): string
```

 Format issues for human-readable output.
 Creates formatted strings like "file.tl:10:5: error: message";
 opts.hints appends a fix-hint line after each recognized error.

**Parameters:**

- `issues` ({Issue}) - List of issues to format
- `opts` (FormatOptions?) - hints: append fix-hints for known traps

**Returns:**

- string - Formatted issues, one per line (plus hint lines)

### compile_cached

```teal
function compile_cached(input_path: string,
    opts?: CacheOptions): string | nil, string
```

 Compile a Teal file, reusing cached output when the source has not
 changed. Lax, like `compile_file`; `check_file` remains the strict
 gate.
 The loop itself lives with the cache it drives (`cosmic._script_cache`);
 this is the name its two callers know it by.

**Parameters:**

- `input_path` (string) - Path to the Teal file to compile
- `opts` (CacheOptions?) - strict: type-check strictly (warnings still pass)

**Returns:**

- string|nil - The generated Lua code, or nil when compilation failed
- string - The formatted issues when compilation failed
