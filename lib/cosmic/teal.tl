--- Teal compilation and type-checking.
--- --compile uses lax mode for permissive compilation.
--- --check uses strict mode for thorough type checking.

local tl = require("tl")

--- A compiler or type checker issue.
local record Issue
  file: string
  line: integer
  column: integer
  message: string
  severity: string -- "error" or "warning"
  tag: string -- warning kind ("unused", "redeclaration", ...) when severity is "warning"
end

--- Options for compiling Teal to Lua.
local record CompileOptions
  include_dirs: {string}
  gen_target: string
  gen_compat: string
end

--- Options for type-checking Teal files.
--- Warnings fail the check unless werror is explicitly set to false.
local record CheckOptions
  include_dirs: {string}
  werror: boolean
end

--- Result from compiling a Teal file.
local record CompileResult
  ok: boolean
  code: string
  errors: {Issue}
end

--- Result from type-checking a Teal file.
local record CheckResult
  ok: boolean
  warnings: {Issue}
  errors: {Issue}
end

--- Get default include directories for cosmic type definitions.
--- Returns paths to bundled and local type definition directories.
--- @return {string} List of default include directory paths
local function get_default_include_dirs(): {string}
  return {
    "lib/types", -- Local cosmic types (development, takes precedence)
    "/zip/.lua/types", -- Bundled cosmic types (in binary)
    "/zip/.lua/teal-types", -- Bundled third-party types (in binary)
    "/zip/.tl", -- Bundled cosmic .tl source (for type checking)
  }
end

--- Error from the Teal compiler.
local record TlError
  msg: string
  filename: string
  y: integer
  x: integer
  tag: string
end

--- Result from Teal's process_string function.
local record TlResult
  syntax_errors: {TlError}
  type_errors: {TlError}
  warnings: {TlError}
  ast: any
end

--- Internal result from processing a Teal file.
local record ProcessResult
  tl_result: TlResult
  shebang: string
  error: Issue
end

--- Process a Teal file: read, setup paths, run tl.process_string.
--- Returns ProcessResult with tl_result on success, or error on failure.
--- @param input_path string Path to the Teal file to process
--- @param include_dirs {string} Directories to search for type definitions
--- @param lax boolean If true, use lax mode; if false, use strict mode
--- @return ProcessResult Processing result with tl_result or error
local function process_file(input_path: string, include_dirs: {string}, lax: boolean): ProcessResult
  local f, open_err = io.open(input_path, "r")
  if not f then
    return {
      error = {
        file = input_path,
        line = 0,
        column = 0,
        message = "cannot open file: " .. (open_err or "unknown error"),
        severity = "error",
      },
    }
  end
  local input = f:read("*a")
  f:close()

  -- Extract shebang if present (to preserve it in output)
  local shebang: string = nil
  if input:sub(1, 2) == "#!" then
    local newline_pos = input:find("\n")
    if newline_pos then
      shebang = input:sub(1, newline_pos)
    end
  end

  include_dirs = include_dirs or get_default_include_dirs()

  -- Assemble tl.path from TL_PATH env var + include_dirs + package.path so
  -- tl.search_module finds all required modules regardless of whether TL_PATH
  -- is set. tl.search_module priority: TL_PATH env > tl.path > package.path.
  -- By setting tl.path (which takes precedence over package.path), we ensure
  -- include_dirs are always consulted — even when TL_PATH is set.
  -- Appending package.path preserves CWD-relative and system search patterns.
  local saved_tl_path = tl.path
  local path_parts: {string} = {}
  local tl_path = os.getenv("TL_PATH")
  if tl_path then
    path_parts[#path_parts + 1] = tl_path
  end
  for _, dir in ipairs(include_dirs) do
    path_parts[#path_parts + 1] = dir .. "/?.d.tl"
    path_parts[#path_parts + 1] = dir .. "/?/init.d.tl"
    path_parts[#path_parts + 1] = dir .. "/?.tl"
    path_parts[#path_parts + 1] = dir .. "/?/init.tl"
  end
  path_parts[#path_parts + 1] = package.path
  tl.path = table.concat(path_parts, ";")

  -- Options-form env construction: feature flags are explicit rather than
  -- inherited from tl's version-dependent defaults. feat_arity stays "on"
  -- (0.24 default) so function-arity mismatches are checked in strict mode.
  local env = tl.new_env({
      defaults = {
        feat_lax = lax and "on" or "off",
        feat_arity = "on",
        gen_target = "5.4",
        gen_compat = "off",
      },
    })
  -- process_string returns exactly one value (a Result); errors land in
  -- its syntax_errors/type_errors fields or arrive here as a throw.
  local ok, result_or_err = pcall(tl.process_string, input, false, env, input_path)

  tl.path = saved_tl_path

  if not ok then
    return {
      error = {
        file = input_path,
        line = 0,
        column = 0,
        message = tostring(result_or_err),
        severity = "error",
      },
    }
  end
  local result = result_or_err as TlResult

  if not result then
    return {
      error = {
        file = input_path,
        line = 0,
        column = 0,
        message = "processing failed",
        severity = "error",
      },
    }
  end

  return {tl_result = result, shebang = shebang}
end

--- Collect errors from tl result (syntax_errors and type_errors).
--- Converts Teal's error format to cosmic's Issue format.
--- @param result TlResult The result from tl.process_string
--- @param input_path string Path to the source file for error reporting
--- @return {Issue} List of issues converted from TlErrors
local function collect_errors(result: TlResult, input_path: string): {Issue}
  local errors: {Issue} = {}

  if result.syntax_errors then
    for _, e in ipairs(result.syntax_errors) do
      if e.msg then
        table.insert(errors, {
            file = e.filename or input_path,
            line = e.y or 0,
            column = e.x or 0,
            message = e.msg,
            severity = "error",
          })
      end
    end
  end

  if result.type_errors then
    for _, e in ipairs(result.type_errors) do
      if e.msg then
        table.insert(errors, {
            file = e.filename or input_path,
            line = e.y or 0,
            column = e.x or 0,
            message = e.msg,
            severity = "error",
          })
      end
    end
  end

  return errors
end

--- Merge caller-provided include directories with defaults.
--- Caller dirs come first (higher priority), followed by default dirs.
--- @param extra {string} Additional include directories from caller
--- @return {string} Merged list of include directories
local function merge_include_dirs(extra: {string}): {string}
  local defaults = get_default_include_dirs()
  if not extra or #extra == 0 then
    return defaults
  end
  local merged: {string} = {}
  for _, d in ipairs(extra) do
    merged[#merged + 1] = d
  end
  for _, d in ipairs(defaults) do
    merged[#merged + 1] = d
  end
  return merged
end

--- Compile a Teal file to Lua code.
--- Uses lax mode for permissive compilation. Preserves shebang if present.
--- @param input_path string Path to the Teal file to compile
--- @param opts CompileOptions Compilation options (include_dirs, gen_target, gen_compat)
--- @return CompileResult Result with ok status, generated Lua code, and any errors
local function compile(input_path: string, opts: CompileOptions): CompileResult
  opts = opts or {} as CompileOptions

  local dirs = merge_include_dirs(opts.include_dirs)
  local proc = process_file(input_path, dirs, true)
  if proc.error then
    return {ok = false, code = nil, errors = {proc.error}}
  end

  local errors = collect_errors(proc.tl_result, input_path)
  if #errors > 0 then
    return {ok = false, code = nil, errors = errors}
  end

  -- tl.generate's second argument is the target STRING; passing an
  -- options table silently fell back to tl's default (non-5.4) target,
  -- which rejects 5.4-only syntax like <close> attributes. gen_compat
  -- is an env-level default (set in make_env), not a generate option.
  local lua_code = tl.generate(proc.tl_result.ast, opts.gen_target or "5.4")

  if proc.shebang then
    lua_code = proc.shebang .. lua_code
  end

  return {ok = true, code = lua_code, errors = {}}
end

--- Type-check a Teal file.
--- Uses strict mode for thorough type checking. Collects errors and warnings.
--- Warnings fail the check (ok = false) unless opts.werror is explicitly
--- false: an unused local or shadowed variable is a defect the author must
--- either fix or deliberately mark (leading underscore), never ignore.
--- @param input_path string Path to the Teal file to check
--- @param opts CheckOptions Type-checking options (include_dirs, werror)
--- @return CheckResult Result with ok status, warnings, and errors
local function check(input_path: string, opts: CheckOptions): CheckResult
  opts = opts or {} as CheckOptions
  local werror = opts.werror ~= false

  local dirs = merge_include_dirs(opts.include_dirs)
  local proc = process_file(input_path, dirs, false)
  if proc.error then
    return {ok = false, warnings = {}, errors = {proc.error}}
  end

  local errors = collect_errors(proc.tl_result, input_path)

  local warnings: {Issue} = {}
  if proc.tl_result.warnings then
    for _, w in ipairs(proc.tl_result.warnings) do
      if w.msg then
        table.insert(warnings, {
            file = w.filename or input_path,
            line = w.y or 0,
            column = w.x or 0,
            message = w.msg,
            severity = "warning",
            tag = w.tag,
          })
      end
    end
  end

  local ok = #errors == 0 and (not werror or #warnings == 0)
  return {ok = ok, warnings = warnings, errors = errors}
end

--- Format issues for human-readable output.
--- Creates formatted strings like "file.tl:10:5: error: message".
--- @param issues {Issue} List of issues to format
--- @return string Formatted issues, one per line
local function format_issues(issues: {Issue}): string
  local lines: {string} = {}
  for _, issue in ipairs(issues) do
    table.insert(lines, string.format("%s:%d:%d: %s: %s",
        issue.file,
        issue.line,
        issue.column,
        issue.severity,
        issue.message))
  end
  return table.concat(lines, "\n")
end

--- Return a fix-hint line for a known Teal type-check error pattern, or nil.
--- Matches the three most common traps that cost edit-check cycles:
---   1. got number, expected integer (string index/length requires integer)
---   2. got X | nil, expected X (nil not narrowed before use)
---   3. excess return values (multiple returns captured incorrectly)
---   4. <any type> operations (ipairs, index, concat on any)
--- @param msg string The error message to match
--- @return string|nil A short hint string, or nil if no hint applies
local function hint_for_message(msg: string): string | nil
  -- Pattern 1: number/integer mismatch
  if msg:find("got number, expected integer") then
    return "  hint: annotate the variable `: number`, or convert with math.tointeger; integer is required for string indices/lengths"
  end
  -- Pattern 2: nil union not narrowed (X | nil where X expected)
  if msg:find("%| nil") and msg:find("expected") then
    return "  hint: narrow first: `if v is Rec then ... end` (plain-table records), or cast after a guard for userdata handles"
  end
  -- Pattern 3: excess return values (wrong number of returns)
  if msg:find("excess return values") then
    return "  hint: capture multiple returns first: `local v, err = f(...)`"
  end
  -- Pattern 4a: ipairs on any
  if msg:find("attempting ipairs on something that's not an array") then
    return "  hint: cast first, e.g. `local items = data as {any}`"
  end
  -- Pattern 4b: concat with any type
  if msg:find("cannot use operator '%.%.'") and msg:find("<any type>") then
    return "  hint: cast first, e.g. `local s = val as string`"
  end
  -- Pattern 4c: index on any type
  if msg:find("cannot index") and msg:find("<any type>") then
    return "  hint: cast first, e.g. `local obj = val as {string: any}`"
  end
  return nil
end

--- Format issues with optional fix-hints for known Teal type-check traps.
--- Appends one hint line after each matching error. No duplicate hints per error.
--- @param issues {Issue} List of issues to format
--- @return string Formatted issues with hints, one issue (plus optional hint) per pair of lines
local function format_issues_with_hints(issues: {Issue}): string
  local lines: {string} = {}
  for _, issue in ipairs(issues) do
    table.insert(lines, string.format("%s:%d:%d: %s: %s",
        issue.file,
        issue.line,
        issue.column,
        issue.severity,
        issue.message))
    local hint = hint_for_message(issue.message)
    if hint then
      table.insert(lines, hint)
    end
  end
  return table.concat(lines, "\n")
end

local record TealModule
  compile: function(input_path: string, opts?: CompileOptions): CompileResult
  check: function(input_path: string, opts?: CheckOptions): CheckResult
  format_issues: function(issues: {Issue}): string
  format_issues_with_hints: function(issues: {Issue}): string
  hint_for_message: function(msg: string): string | nil
  get_default_include_dirs: function(): {string}
end

local M: TealModule = {
  compile = compile,
  check = check,
  format_issues = format_issues,
  format_issues_with_hints = format_issues_with_hints,
  hint_for_message = hint_for_message,
  get_default_include_dirs = get_default_include_dirs,
}

return M
